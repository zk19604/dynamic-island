// Now Playing bridge.
//
// Why this exists: since macOS 15.4 the private MediaRemote framework only
// returns Now Playing info to Apple-signed processes. /usr/bin/perl is one of
// them, and perl can load this small library with DynaLoader. The app runs
//   /usr/bin/perl -e '<loader>' /path/to/libIslandMediaHelper.dylib
// and talks to it over pipes:
//   stdout: one JSON object per line: {"players": [...]}, every app with media
//   stdin:  commands, one per line: toggle|play|pause|next|prev [bundleID], seek <seconds> [bundleID]
// No network, no permissions. Only local system media state is read.

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <signal.h>
#include <unistd.h>
#include "IslandMediaHelper.h"

#if !__has_feature(objc_arc)
#error "IslandMediaHelper must be compiled with ARC"
#endif

typedef void (^MRInfoBlock)(CFDictionaryRef info);
typedef void (^MRBoolBlock)(Boolean value);
typedef void (^MRClientBlock)(id client);

typedef void (*MRGetNowPlayingInfoFn)(dispatch_queue_t, MRInfoBlock);
typedef void (*MRGetIsPlayingFn)(dispatch_queue_t, MRBoolBlock);
typedef void (*MRGetClientFn)(dispatch_queue_t, MRClientBlock);
typedef CFStringRef (*MRClientStringFn)(id);
typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef Boolean (*MRSendCommandFn)(int, CFDictionaryRef);
typedef void (*MRSetElapsedFn)(double);
typedef void (^MRArrayBlock)(CFArrayRef items);
typedef void (^MRStateBlock)(unsigned int state);
typedef void (*MRGetClientsFn)(dispatch_queue_t, MRArrayBlock);
typedef id (*MRGetLocalOriginFn)(void);
typedef id (*MRPlayerPathCreateFn)(id origin, id client, id player);
typedef void (*MRGetStateForPlayerFn)(id path, dispatch_queue_t, MRStateBlock);
typedef void (^MRPlayerInfoBlock)(CFDictionaryRef info, void *unused);
/// Verified from the macOS 26 binary: (playerPath, includeArtwork, queue, completion).
typedef void (*MRGetInfoForPlayerFn)(id path, Boolean includeArtwork, dispatch_queue_t, MRPlayerInfoBlock);

static MRGetNowPlayingInfoFn gGetInfo;
static MRGetIsPlayingFn gGetIsPlaying;
static MRGetClientFn gGetClient;
static MRClientStringFn gClientBundleID;
static MRClientStringFn gClientParentBundleID;
static MRSendCommandFn gSendCommand;
static MRSetElapsedFn gSetElapsed;
static MRGetClientsFn gGetClients;
static MRGetLocalOriginFn gGetLocalOrigin;
static MRPlayerPathCreateFn gPlayerPathCreate;
static MRGetStateForPlayerFn gGetStateForPlayer;
static MRGetInfoForPlayerFn gGetInfoForPlayer;

/// Bundle id of the system's "now playing" app (from the last refresh).
static NSString *gSystemBundleID = nil;
/// How many apps besides the system one have a media session. The system
/// only posts change notifications for its own app, so these are polled.
static NSUInteger gOtherPlayerCount = 0;
static const unsigned int kMRPlaybackStatePlaying = 1;

/// Artwork keys already sent to the app (it caches images by key).
static NSMutableSet<NSString *> *gSentArtwork = nil;
/// Per app: "title|album" -> artwork key, so polls can skip artwork data.
static NSMutableDictionary<NSString *, NSArray<NSString *> *> *gArtworkKeyByApp = nil;
static NSString *gLastPayload = nil;
static NSUInteger gGeneration = 0;
static BOOL gRefreshPending = NO;

enum { kMRPlay = 0, kMRPause = 1, kMRTogglePlayPause = 2, kMRNextTrack = 4, kMRPreviousTrack = 5 };

static void writeLine(NSDictionary *payload) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!json) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    if (fflush(stdout) != 0 || ferror(stdout)) exit(0); // app went away
}

static id jsonSafe(id value) {
    if ([value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSNumber class]]) return value;
    if ([value isKindOfClass:[NSDate class]]) return @([(NSDate *)value timeIntervalSince1970]);
    return nil;
}

static NSString *artworkSignature(NSDictionary *info) {
    return [NSString stringWithFormat:@"%@|%@", jsonSafe(info[@"kMRMediaRemoteNowPlayingInfoTitle"]) ?: @"",
            jsonSafe(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]) ?: @""];
}

/// One player as JSON-ready values, or nil if it has no title.
/// Artwork bytes (if any) go in `artworkOut` keyed by artwork id.
static NSMutableDictionary *playerEntry(NSDictionary *info, BOOL isPlaying, NSString *bundleID, BOOL isSystem,
                                        NSMutableDictionary<NSString *, NSData *> *artworkOut) {
    NSString *title = jsonSafe(info[@"kMRMediaRemoteNowPlayingInfoTitle"]);
    if (![title isKindOfClass:[NSString class]] || title.length == 0) return nil;
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"title"] = title;
    out[@"artist"] = jsonSafe(info[@"kMRMediaRemoteNowPlayingInfoArtist"]) ?: @"";
    out[@"album"] = jsonSafe(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]) ?: @"";
    out[@"duration"] = jsonSafe(info[@"kMRMediaRemoteNowPlayingInfoDuration"]) ?: @0;
    out[@"elapsed"] = jsonSafe(info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]) ?: @0;
    out[@"rate"] = jsonSafe(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]) ?: @0;
    id timestamp = jsonSafe(info[@"kMRMediaRemoteNowPlayingInfoTimestamp"]);
    if (timestamp) out[@"timestamp"] = timestamp;
    out[@"playing"] = @(isPlaying);
    out[@"system"] = @(isSystem);
    // Seeking only works reliably for the system's now-playing app.
    out[@"canSeek"] = @(isSystem);
    if (bundleID.length) out[@"bundleID"] = bundleID;

    NSString *appKey = bundleID ?: @"";
    NSData *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
    if ([artwork isKindOfClass:[NSData class]] && artwork.length > 0) {
        NSString *identifier = jsonSafe(info[@"kMRMediaRemoteNowPlayingInfoArtworkIdentifier"]);
        NSString *key = [NSString stringWithFormat:@"%@|%@|%@|%lu", identifier ?: @"", title,
                         out[@"album"], (unsigned long)artwork.length];
        out[@"artworkID"] = key;
        artworkOut[key] = artwork;
        gArtworkKeyByApp[appKey] = @[ artworkSignature(info), key ];
    } else {
        // Polled without artwork: reuse the key from the last full fetch.
        NSArray<NSString *> *cached = gArtworkKeyByApp[appKey];
        if (cached && [cached[0] isEqualToString:artworkSignature(info)] && cached[1].length) {
            out[@"artworkID"] = cached[1];
        } else if (!cached || ![cached[0] isEqualToString:artworkSignature(info)]) {
            gArtworkKeyByApp[appKey] = @[ artworkSignature(info), @"" ];
        }
    }
    return out;
}

/// Sends the full player list, skipping it if nothing changed.
static void emitPlayers(NSArray<NSMutableDictionary *> *players, NSDictionary<NSString *, NSData *> *artwork) {
    NSData *plain = [NSJSONSerialization dataWithJSONObject:@{ @"players": players } options:0 error:nil];
    NSString *payload = plain ? [[NSString alloc] initWithData:plain encoding:NSUTF8StringEncoding] : @"";
    BOOL newArtwork = NO;
    for (NSDictionary *p in players) {
        NSString *key = p[@"artworkID"];
        if (key && artwork[key] && ![gSentArtwork containsObject:key]) { newArtwork = YES; break; }
    }
    if (!newArtwork && [payload isEqualToString:gLastPayload]) return;
    gLastPayload = payload;

    if (gSentArtwork.count > 40) [gSentArtwork removeAllObjects];
    for (NSMutableDictionary *p in players) {
        NSString *key = p[@"artworkID"];
        if (key && artwork[key] && ![gSentArtwork containsObject:key]) {
            p[@"artwork"] = [artwork[key] base64EncodedStringWithOptions:0];
            [gSentArtwork addObject:key];
        }
    }
    writeLine(@{ @"players": players });
}

static NSString *bundleIDForClient(id client) {
    if (!client || !gClientBundleID) return nil;
    NSString *bundleID = nil;
    if (gClientParentBundleID) bundleID = (__bridge NSString *)gClientParentBundleID(client);
    if (bundleID.length == 0) bundleID = (__bridge NSString *)gClientBundleID(client);
    return bundleID;
}

static BOOL perPlayerAvailable(void) {
    return gGetClients && gGetLocalOrigin && gPlayerPathCreate && gGetStateForPlayer
        && gGetInfoForPlayer && gClientBundleID;
}

/// Adds every other app with a media session (playing or paused) to
/// `players`, one app per entry, then calls `done`.
static void collectOtherPlayers(NSString *systemBundleID, NSString *systemTitle,
                                NSMutableArray *players, NSMutableDictionary *artwork, void (^done)(void)) {
    dispatch_queue_t q = dispatch_get_main_queue();
    gGetClients(q, ^(CFArrayRef cfClients) {
        NSArray *clients = [(__bridge NSArray *)cfClients copy] ?: @[];
        id origin = gGetLocalOrigin();
        NSMutableSet<NSString *> *seen = [NSMutableSet set];
        if (systemBundleID.length) [seen addObject:systemBundleID];
        __block NSUInteger index = 0;
        __block NSUInteger others = 0;
        __block void (^next)(void);
        __block __weak void (^weakNext)(void);
        next = ^{
            if (index >= clients.count) {
                gOtherPlayerCount = others;
                next = nil; // break the retain cycle
                done();
                return;
            }
            id client = clients[index++];
            NSString *bundleID = bundleIDForClient(client);
            if (bundleID.length == 0 || [seen containsObject:bundleID]) { weakNext(); return; }
            id path = gPlayerPathCreate(origin, client, nil);
            if (!path) { weakNext(); return; }
            gGetStateForPlayer(path, q, ^(unsigned int state) {
                BOOL playing = state == kMRPlaybackStatePlaying;
                gGetInfoForPlayer(path, false, q, ^(CFDictionaryRef cfInfo, void *unused) {
                    NSDictionary *info = [(__bridge NSDictionary *)cfInfo copy] ?: @{};
                    NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
                    if (![title isKindOfClass:[NSString class]] || title.length == 0
                        || (systemBundleID.length == 0 && [title isEqualToString:systemTitle])) {
                        weakNext(); return;
                    }
                    void (^add)(NSDictionary *) = ^(NSDictionary *full) {
                        NSMutableDictionary *entry = playerEntry(full, playing, bundleID, NO, artwork);
                        if (entry) { [players addObject:entry]; [seen addObject:bundleID]; others++; }
                        weakNext();
                    };
                    NSArray<NSString *> *cached = gArtworkKeyByApp[bundleID];
                    if (cached && [cached[0] isEqualToString:artworkSignature(info)]) {
                        add(info); // same track: artwork already known
                    } else {
                        gGetInfoForPlayer(path, true, q, ^(CFDictionaryRef cfFull, void *unused2) {
                            add([(__bridge NSDictionary *)cfFull copy] ?: info);
                        });
                    }
                });
            });
        };
        weakNext = next;
        next();
    });
}

static void refreshNow(void) {
    dispatch_queue_t q = dispatch_get_main_queue();
    NSUInteger generation = ++gGeneration;
    gGetIsPlaying(q, ^(Boolean playing) {
        gGetInfo(q, ^(CFDictionaryRef cfInfo) {
            NSDictionary *info = [(__bridge NSDictionary *)cfInfo copy] ?: @{};
            void (^finish)(NSString *) = ^(NSString *systemID) {
                gSystemBundleID = systemID;
                NSMutableArray *players = [NSMutableArray array];
                NSMutableDictionary *artwork = [NSMutableDictionary dictionary];
                NSMutableDictionary *system = playerEntry(info, playing, systemID, YES, artwork);
                if (system) [players addObject:system];
                void (^send)(void) = ^{
                    if (generation != gGeneration) return; // a newer refresh is running
                    emitPlayers(players, artwork);
                };
                if (!perPlayerAvailable()) { gOtherPlayerCount = 0; send(); return; }
                collectOtherPlayers(systemID, system[@"title"], players, artwork, send);
            };
            if (gGetClient && gClientBundleID) {
                gGetClient(q, ^(id client) { finish(bundleIDForClient(client)); });
            } else {
                finish(nil);
            }
        });
    });
}

/// Coalesces bursts of notifications into one refresh.
static void scheduleRefresh(double delay) {
    if (gRefreshPending) return;
    gRefreshPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gRefreshPending = NO;
        refreshNow();
    });
}

/// Sends to the system's now-playing app. A command aimed at any other app
/// is dropped: macOS routes it to the now-playing app anyway (verified on
/// macOS 26 with SendCommandToApp/ToClient/ToPlayer), which would control
/// the wrong player. The app controls those players another way.
static void send(int command, NSString *bundleID) {
    BOOL isSystem = bundleID.length == 0 || [bundleID isEqualToString:gSystemBundleID];
    if (isSystem) gSendCommand(command, NULL);
}

/// Commands: toggle|play|pause|next|prev [bundleID]   or   seek <seconds> [bundleID]
static void handleCommand(NSString *line) {
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
    NSString *cmd = parts.firstObject;
    NSString *target = nil;
    if ([cmd isEqualToString:@"seek"]) {
        if (parts.count > 2) target = parts[2];
    } else if (parts.count > 1) {
        target = parts[1];
    }
    if ([cmd isEqualToString:@"toggle"]) send(kMRTogglePlayPause, target);
    else if ([cmd isEqualToString:@"play"]) send(kMRPlay, target);
    else if ([cmd isEqualToString:@"pause"]) send(kMRPause, target);
    else if ([cmd isEqualToString:@"next"]) send(kMRNextTrack, target);
    else if ([cmd isEqualToString:@"prev"]) send(kMRPreviousTrack, target);
    else if ([cmd isEqualToString:@"seek"] && parts.count > 1 && gSetElapsed
             && (target.length == 0 || [target isEqualToString:gSystemBundleID])) gSetElapsed(parts[1].doubleValue);
    else if ([cmd isEqualToString:@"refresh"]) { /* just refresh below */ }
    else if ([cmd isEqualToString:@"forget-artwork"]) { [gSentArtwork removeAllObjects]; [gArtworkKeyByApp removeAllObjects]; return; }
    else return;
    scheduleRefresh(0.25);
    // Some apps take a moment to report the new state.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        scheduleRefresh(0);
    });
}

static void startReadingCommands(void) {
    static NSMutableData *buffer;
    buffer = [NSMutableData data];
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(source, ^{
        char chunk[1024];
        ssize_t n = read(STDIN_FILENO, chunk, sizeof chunk);
        if (n <= 0) exit(0); // stdin closed: the app quit
        [buffer appendBytes:chunk length:(NSUInteger)n];
        while (true) {
            NSRange nl = [buffer rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0 range:NSMakeRange(0, buffer.length)];
            if (nl.location == NSNotFound) break;
            NSData *lineData = [buffer subdataWithRange:NSMakeRange(0, nl.location)];
            [buffer replaceBytesInRange:NSMakeRange(0, nl.location + 1) withBytes:NULL length:0];
            NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
            line = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (line.length) handleCommand(line);
        }
    });
    dispatch_resume(source);
    static dispatch_source_t keepAlive;
    keepAlive = source;
}

void islandmedia_run(void *unused1, void *unused2) {
    (void)unused1; (void)unused2;
    signal(SIGPIPE, SIG_IGN);

    void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!mr) { writeLine(@{ @"error": @"MediaRemote unavailable" }); exit(1); }
    gGetInfo = (MRGetNowPlayingInfoFn)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
    gGetIsPlaying = (MRGetIsPlayingFn)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    gGetClient = (MRGetClientFn)dlsym(mr, "MRMediaRemoteGetNowPlayingClient");
    gClientBundleID = (MRClientStringFn)dlsym(mr, "MRNowPlayingClientGetBundleIdentifier");
    gClientParentBundleID = (MRClientStringFn)dlsym(mr, "MRNowPlayingClientGetParentAppBundleIdentifier");
    gSendCommand = (MRSendCommandFn)dlsym(mr, "MRMediaRemoteSendCommand");
    gSetElapsed = (MRSetElapsedFn)dlsym(mr, "MRMediaRemoteSetElapsedTime");
    gGetClients = (MRGetClientsFn)dlsym(mr, "MRMediaRemoteGetNowPlayingClients");
    gGetLocalOrigin = (MRGetLocalOriginFn)dlsym(mr, "MRMediaRemoteGetLocalOrigin");
    gPlayerPathCreate = (MRPlayerPathCreateFn)dlsym(mr, "MRNowPlayingPlayerPathCreate");
    gGetStateForPlayer = (MRGetStateForPlayerFn)dlsym(mr, "MRMediaRemoteGetPlaybackStateForPlayer");
    gGetInfoForPlayer = (MRGetInfoForPlayerFn)dlsym(mr, "MRMediaRemoteGetNowPlayingInfoForPlayer");
    MRRegisterFn registerFn = (MRRegisterFn)dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (!gGetInfo || !gGetIsPlaying || !gSendCommand || !registerFn) {
        writeLine(@{ @"error": @"MediaRemote symbols missing" });
        exit(1);
    }

    gSentArtwork = [NSMutableSet set];
    gArtworkKeyByApp = [NSMutableDictionary dictionary];
    registerFn(dispatch_get_main_queue());
    NSArray *names = @[ @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                        @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                        @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                        @"kMRMediaRemoteNowPlayingApplicationClientStateDidChange" ];
    for (NSString *name in names) {
        [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:nil
                                                      usingBlock:^(NSNotification *note) { scheduleRefresh(0.08); }];
    }

    startReadingCommands();
    refreshNow();

    // Other apps send no notifications, so poll every 2s while any exist.
    // Otherwise a slow safety net (every 20s) in case a notification is missed.
    static dispatch_source_t timer;
    static unsigned int ticks = 0;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
    dispatch_source_set_event_handler(timer, ^{
        ticks++;
        if (gOtherPlayerCount > 0 || ticks % 10 == 0) scheduleRefresh(0);
    });
    dispatch_resume(timer);

    CFRunLoopRun();
    exit(0);
}
