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

static MRGetNowPlayingInfoFn gGetInfo;
static MRGetIsPlayingFn gGetIsPlaying;
static MRGetClientFn gGetClient;
static MRClientStringFn gClientBundleID;
static MRClientStringFn gClientParentBundleID;
static MRSendCommandFn gSendCommand;
static MRSetElapsedFn gSetElapsed;

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

static void emit(NSDictionary *info, BOOL isPlaying, NSString *bundleID) {
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

static void refreshNow(void) {
    dispatch_queue_t q = dispatch_get_main_queue();
    gGetIsPlaying(q, ^(Boolean playing) {
        gGetInfo(q, ^(CFDictionaryRef cfInfo) {
            NSDictionary *info = [(__bridge NSDictionary *)cfInfo copy] ?: @{};
            if (gGetClient && gClientBundleID) {
                gGetClient(q, ^(id client) {
                    NSString *bundleID = nil;
                    if (client) {
                        if (gClientParentBundleID) bundleID = (__bridge NSString *)gClientParentBundleID(client);
                        if (bundleID.length == 0) bundleID = (__bridge NSString *)gClientBundleID(client);
                    }
                    emit(info, playing, bundleID);
                });
            } else {
                emit(info, playing, nil);
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

static void handleCommand(NSString *line) {
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
    NSString *cmd = parts.firstObject;
    if ([cmd isEqualToString:@"toggle"]) gSendCommand(kMRTogglePlayPause, NULL);
    else if ([cmd isEqualToString:@"play"]) gSendCommand(kMRPlay, NULL);
    else if ([cmd isEqualToString:@"pause"]) gSendCommand(kMRPause, NULL);
    else if ([cmd isEqualToString:@"next"]) gSendCommand(kMRNextTrack, NULL);
    else if ([cmd isEqualToString:@"prev"]) gSendCommand(kMRPreviousTrack, NULL);
    else if ([cmd isEqualToString:@"seek"] && parts.count > 1 && gSetElapsed) gSetElapsed(parts[1].doubleValue);
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
