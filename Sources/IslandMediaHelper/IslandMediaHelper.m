// Now Playing bridge.
//
// Why this exists: since macOS 15.4 the private MediaRemote framework only
// returns Now Playing info to Apple-signed processes. /usr/bin/perl is one of
// them, and perl can load this small library with DynaLoader. The app runs
//   /usr/bin/perl -e '<loader>' /path/to/libIslandMediaHelper.dylib
// and talks to it over pipes:
//   stdout: one JSON object per line describing the current media
//   stdin:  commands, one per line: toggle | play | pause | next | prev | seek <seconds>
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
typedef void (*MRSendCommandToAppFn)(int, CFDictionaryRef, id origin, CFStringRef bundleID,
                                     unsigned int options, dispatch_queue_t, void *completion);

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
static MRSendCommandToAppFn gSendCommandToApp;

/// Bundle id of a playing app shown instead of the system's "now playing"
/// app (which can be a paused browser tab while Spotify plays). Commands go
/// to this app when set.
static NSString *gTargetBundleID = nil;
static const unsigned int kMRPlaybackStatePlaying = 1;

static NSString *gLastArtworkKey = nil;
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

static void emit(NSDictionary *info, BOOL isPlaying, NSString *bundleID, BOOL canSeek) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSString *title = jsonSafe(info[@"kMRMediaRemoteNowPlayingInfoTitle"]);
    if (title.length == 0) {
        gLastArtworkKey = nil;
        writeLine(@{ @"empty": @YES });
        return;
    }
    out[@"title"] = title;
    out[@"artist"] = jsonSafe(info[@"kMRMediaRemoteNowPlayingInfoArtist"]) ?: @"";
    out[@"album"] = jsonSafe(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]) ?: @"";
    out[@"duration"] = jsonSafe(info[@"kMRMediaRemoteNowPlayingInfoDuration"]) ?: @0;
    out[@"elapsed"] = jsonSafe(info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]) ?: @0;
    out[@"rate"] = jsonSafe(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]) ?: @0;
    out[@"timestamp"] = jsonSafe(info[@"kMRMediaRemoteNowPlayingInfoTimestamp"]) ?: @([[NSDate date] timeIntervalSince1970]);
    out[@"playing"] = @(isPlaying);
    out[@"canSeek"] = @(canSeek);
    if (bundleID.length) out[@"bundleID"] = bundleID;

    NSData *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
    if ([artwork isKindOfClass:[NSData class]] && artwork.length > 0) {
        NSString *identifier = jsonSafe(info[@"kMRMediaRemoteNowPlayingInfoArtworkIdentifier"]);
        NSString *key = [NSString stringWithFormat:@"%@|%@|%@|%lu", identifier ?: @"", title,
                         out[@"album"], (unsigned long)artwork.length];
        out[@"artworkID"] = key;
        // Only send the (large) image when it changes; the app caches it.
        if (![key isEqualToString:gLastArtworkKey]) {
            out[@"artwork"] = [artwork base64EncodedStringWithOptions:0];
            gLastArtworkKey = key;
        }
    } else {
        gLastArtworkKey = nil;
    }
    writeLine(out);
}

static void scheduleRefresh(double delay);

static NSString *bundleIDForClient(id client) {
    if (!client || !gClientBundleID) return nil;
    NSString *bundleID = nil;
    if (gClientParentBundleID) bundleID = (__bridge NSString *)gClientParentBundleID(client);
    if (bundleID.length == 0) bundleID = (__bridge NSString *)gClientBundleID(client);
    return bundleID;
}

static BOOL perPlayerAvailable(void) {
    return gGetClients && gGetLocalOrigin && gPlayerPathCreate && gGetStateForPlayer
        && gGetInfoForPlayer && gSendCommandToApp && gClientBundleID;
}

/// The system's "now playing" app is paused: look through every app with a
/// media session and show the first one that is actually playing.
/// `fallback` emits the (paused) system app when nothing else plays.
static void findOtherPlayingClient(NSString *systemBundleID, void (^fallback)(void)) {
    dispatch_queue_t q = dispatch_get_main_queue();
    gGetClients(q, ^(CFArrayRef cfClients) {
        NSArray *clients = [(__bridge NSArray *)cfClients copy] ?: @[];
        id origin = gGetLocalOrigin();
        __block NSUInteger index = 0;
        __block void (^next)(void);
        __block __weak void (^weakNext)(void);
        next = ^{
            if (index >= clients.count) { gTargetBundleID = nil; next = nil; fallback(); return; }
            id client = clients[index++];
            NSString *bundleID = bundleIDForClient(client);
            if (bundleID.length == 0 || [bundleID isEqualToString:systemBundleID]) { weakNext(); return; }
            id path = gPlayerPathCreate(origin, client, nil);
            if (!path) { weakNext(); return; }
            gGetStateForPlayer(path, q, ^(unsigned int state) {
                if (state != kMRPlaybackStatePlaying) { weakNext(); return; }
                gGetInfoForPlayer(path, true, q, ^(CFDictionaryRef cfInfo, void *unused) {
                    NSDictionary *info = [(__bridge NSDictionary *)cfInfo copy] ?: @{};
                    if (![info[@"kMRMediaRemoteNowPlayingInfoTitle"] isKindOfClass:[NSString class]]) { weakNext(); return; }
                    gTargetBundleID = bundleID;
                    emit(info, YES, bundleID, NO);
                    next = nil; // break the retain cycle
                    // The system only posts change notifications for its own
                    // now-playing app, so check this one again shortly
                    // (catches track changes and pauses). Cheap: one query.
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), q, ^{
                        if (gTargetBundleID) scheduleRefresh(0);
                    });
                });
            });
        };
        weakNext = next;
        next();
    });
}

static void refreshNow(void) {
    dispatch_queue_t q = dispatch_get_main_queue();
    gGetIsPlaying(q, ^(Boolean playing) {
        gGetInfo(q, ^(CFDictionaryRef cfInfo) {
            NSDictionary *info = [(__bridge NSDictionary *)cfInfo copy] ?: @{};
            void (^finish)(NSString *) = ^(NSString *bundleID) {
                if (playing || !perPlayerAvailable()) {
                    gTargetBundleID = nil;
                    emit(info, playing, bundleID, YES);
                } else {
                    findOtherPlayingClient(bundleID, ^{ emit(info, playing, bundleID, YES); });
                }
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

/// Sends to the app being shown: a specific playing app if we picked one,
/// otherwise the system's now-playing app.
static void send(int command) {
    if (gTargetBundleID && gSendCommandToApp) {
        gSendCommandToApp(command, NULL, NULL, (__bridge CFStringRef)gTargetBundleID, 0, NULL, NULL);
    } else {
        gSendCommand(command, NULL);
    }
}

static void handleCommand(NSString *line) {
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
    NSString *cmd = parts.firstObject;
    if ([cmd isEqualToString:@"toggle"]) send(kMRTogglePlayPause);
    else if ([cmd isEqualToString:@"play"]) send(kMRPlay);
    else if ([cmd isEqualToString:@"pause"]) send(kMRPause);
    else if ([cmd isEqualToString:@"next"]) send(kMRNextTrack);
    else if ([cmd isEqualToString:@"prev"]) send(kMRPreviousTrack);
    else if ([cmd isEqualToString:@"seek"] && parts.count > 1 && gSetElapsed && !gTargetBundleID) gSetElapsed(parts[1].doubleValue);
    else if ([cmd isEqualToString:@"refresh"]) { /* just refresh below */ }
    else return;
    scheduleRefresh(0.25);
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
    gSendCommandToApp = (MRSendCommandToAppFn)dlsym(mr, "MRMediaRemoteSendCommandToApp");
    MRRegisterFn registerFn = (MRRegisterFn)dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (!gGetInfo || !gGetIsPlaying || !gSendCommand || !registerFn) {
        writeLine(@{ @"error": @"MediaRemote symbols missing" });
        exit(1);
    }

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

    // Slow safety net in case a notification is missed. Cheap: one query per 20s.
    static dispatch_source_t timer;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), 20 * NSEC_PER_SEC, 5 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{ scheduleRefresh(0); });
    dispatch_resume(timer);

    CFRunLoopRun();
    exit(0);
}
