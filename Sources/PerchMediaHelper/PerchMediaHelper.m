// Perch's Now Playing bridge.
//
// Since macOS 15.4, MediaRemote only tells Apple-signed processes what is playing. Perch therefore
// loads this library into /usr/bin/perl (via DynaLoader) and talks to it over pipes: one JSON object
// per line on stdout, one command per line on stdin. Closing stdin (Perch quitting) ends the process.

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <errno.h>
#include <unistd.h>

#import "PerchMediaHelper.h"

#if !__has_feature(objc_arc)
#error "PerchMediaHelper must be compiled with ARC (-fobjc-arc)"
#endif

typedef void (*MRGetInfo)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*MRGetIsPlaying)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRGetClient)(dispatch_queue_t, void (^)(id));
typedef void (*MRGetPID)(dispatch_queue_t, void (^)(int));
typedef NSString *(*MRClientString)(id);
typedef void (*MRRegister)(dispatch_queue_t);
typedef Boolean (*MRSendCommand)(int, NSDictionary *);
typedef void (*MRSetElapsedTime)(double);

enum { MRPlay = 0, MRPause = 1, MRTogglePlayPause = 2, MRNextTrack = 4, MRPreviousTrack = 5 };

static MRGetInfo getInfo;
static MRGetIsPlaying getIsPlaying;
static MRGetClient getClient;
static MRGetPID getPID;
static MRClientString clientBundleID;
static MRClientString clientParentBundleID;
static MRSendCommand sendCommand;
static MRSetElapsedTime setElapsedTime;

static NSString *lastState;
static NSString *lastTrackKey;
static NSData *lastArtwork;
static BOOL emitPending;
static dispatch_source_t commandSource;
static NSMutableData *commandBuffer;

static NSString *stringValue(id value) {
    return [value isKindOfClass:NSString.class] ? value : @"";
}

static double numberValue(id value) {
    return [value isKindOfClass:NSNumber.class] ? [value doubleValue] : 0;
}

static void writeLine(NSData *json) {
    NSMutableData *line = [json mutableCopy];
    [line appendBytes:"\n" length:1];
    const uint8_t *bytes = line.bytes;
    size_t left = line.length;
    while (left > 0) {
        ssize_t written = write(STDOUT_FILENO, bytes, left);
        if (written < 0) {
            if (errno == EINTR) continue;
            exit(0);
        }
        bytes += written;
        left -= (size_t)written;
    }
}

static void publish(NSDictionary *info, Boolean playing, NSString *bundleID, int pid) {
    NSMutableDictionary *state = [NSMutableDictionary dictionary];
    NSString *title = stringValue(info[@"kMRMediaRemoteNowPlayingInfoTitle"]);
    NSString *artist = stringValue(info[@"kMRMediaRemoteNowPlayingInfoArtist"]);
    NSString *album = stringValue(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]);
    state[@"playing"] = playing ? @YES : @NO;
    if (title.length == 0 && artist.length == 0) {
        state[@"empty"] = @YES;
    } else {
        NSDate *timestamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
        state[@"title"] = title;
        state[@"artist"] = artist;
        state[@"album"] = album;
        state[@"duration"] = @(numberValue(info[@"kMRMediaRemoteNowPlayingInfoDuration"]));
        state[@"elapsed"] = @(numberValue(info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]));
        state[@"rate"] = @(numberValue(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]));
        state[@"timestamp"] = @([timestamp isKindOfClass:NSDate.class] ? timestamp.timeIntervalSince1970 : NSDate.date.timeIntervalSince1970);
        state[@"bundle"] = bundleID;
        state[@"pid"] = @(pid);
    }

    // Artwork often arrives a moment after the rest of a track's info, so a missing image only
    // clears the old one when the track itself changed.
    NSString *trackKey = [NSString stringWithFormat:@"%@\n%@\n%@", title, artist, album];
    BOOL trackChanged = ![trackKey isEqualToString:lastTrackKey ?: @""];
    lastTrackKey = trackKey;
    NSData *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
    if (![artwork isKindOfClass:NSData.class] || artwork.length == 0) artwork = nil;
    NSString *artworkField = nil;
    if (artwork && ![artwork isEqualToData:lastArtwork]) {
        artworkField = [artwork base64EncodedStringWithOptions:0];
        lastArtwork = artwork;
    } else if (!artwork && lastArtwork && trackChanged) {
        artworkField = @"";
        lastArtwork = nil;
    }

    NSData *json = [NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingSortedKeys error:nil];
    NSString *text = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    if (!artworkField && [text isEqualToString:lastState]) return;
    lastState = text;
    if (artworkField) {
        state[@"artwork"] = artworkField;
        json = [NSJSONSerialization dataWithJSONObject:state options:0 error:nil];
    }
    writeLine(json);
}

static void emitState(void) {
    dispatch_queue_t queue = dispatch_get_main_queue();
    dispatch_group_t group = dispatch_group_create();
    __block NSDictionary *info = nil;
    __block Boolean playing = false;
    __block NSString *bundleID = @"";
    __block int pid = 0;

    dispatch_group_enter(group);
    getInfo(queue, ^(NSDictionary *value) {
        info = value;
        dispatch_group_leave(group);
    });
    dispatch_group_enter(group);
    getIsPlaying(queue, ^(Boolean value) {
        playing = value;
        dispatch_group_leave(group);
    });
    if (getClient && clientBundleID) {
        dispatch_group_enter(group);
        getClient(queue, ^(id client) {
            if (client) {
                // Media playing in a browser tab reports a helper process; the parent is the browser.
                NSString *parent = clientParentBundleID ? clientParentBundleID(client) : nil;
                NSString *own = clientBundleID(client);
                bundleID = parent.length ? parent : (own ?: @"");
            }
            dispatch_group_leave(group);
        });
    }
    if (getPID) {
        dispatch_group_enter(group);
        getPID(queue, ^(int value) {
            pid = value;
            dispatch_group_leave(group);
        });
    }
    dispatch_group_notify(group, queue, ^{
        @autoreleasepool {
            publish(info, playing, bundleID, pid);
        }
    });
}

/// MediaRemote posts bursts of notifications for one change; answer the burst once.
static void scheduleEmit(void) {
    if (emitPending) return;
    emitPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        emitPending = NO;
        @autoreleasepool {
            emitState();
        }
    });
}

static void runCommand(NSString *line) {
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
    NSString *name = parts.firstObject;
    if ([name isEqualToString:@"play"]) {
        sendCommand(MRPlay, nil);
    } else if ([name isEqualToString:@"pause"]) {
        sendCommand(MRPause, nil);
    } else if ([name isEqualToString:@"toggle"]) {
        sendCommand(MRTogglePlayPause, nil);
    } else if ([name isEqualToString:@"next"]) {
        sendCommand(MRNextTrack, nil);
    } else if ([name isEqualToString:@"previous"]) {
        sendCommand(MRPreviousTrack, nil);
    } else if ([name isEqualToString:@"seek"] && parts.count > 1 && setElapsedTime) {
        setElapsedTime(parts[1].doubleValue);
        scheduleEmit();
    } else if ([name isEqualToString:@"state"]) {
        lastState = nil;
        emitState();
    }
}

static void readCommands(void) {
    char chunk[512];
    ssize_t count = read(STDIN_FILENO, chunk, sizeof chunk);
    if (count == 0) exit(0);
    if (count < 0) {
        if (errno == EINTR || errno == EAGAIN) return;
        exit(0);
    }
    [commandBuffer appendBytes:chunk length:(NSUInteger)count];
    NSData *newline = [NSData dataWithBytes:"\n" length:1];
    while (YES) {
        NSRange found = [commandBuffer rangeOfData:newline options:0 range:NSMakeRange(0, commandBuffer.length)];
        if (found.location == NSNotFound) break;
        NSData *lineData = [commandBuffer subdataWithRange:NSMakeRange(0, found.location)];
        [commandBuffer replaceBytesInRange:NSMakeRange(0, found.location + 1) withBytes:NULL length:0];
        NSString *line = [[[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (line.length) runCommand(line);
    }
}

static NSString *notificationName(void *handle, const char *symbol) {
    CFStringRef *constant = (CFStringRef *)dlsym(handle, symbol);
    return constant && *constant ? (__bridge NSString *)*constant : @(symbol);
}

void perch_media_stream(void) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!handle) exit(2);
    getInfo = (MRGetInfo)dlsym(handle, "MRMediaRemoteGetNowPlayingInfo");
    getIsPlaying = (MRGetIsPlaying)dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    getClient = (MRGetClient)dlsym(handle, "MRMediaRemoteGetNowPlayingClient");
    getPID = (MRGetPID)dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID");
    clientBundleID = (MRClientString)dlsym(handle, "MRNowPlayingClientGetBundleIdentifier");
    clientParentBundleID = (MRClientString)dlsym(handle, "MRNowPlayingClientGetParentAppBundleIdentifier");
    sendCommand = (MRSendCommand)dlsym(handle, "MRMediaRemoteSendCommand");
    setElapsedTime = (MRSetElapsedTime)dlsym(handle, "MRMediaRemoteSetElapsedTime");
    MRRegister registerForNotifications = (MRRegister)dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (!getInfo || !getIsPlaying || !sendCommand || !registerForNotifications) exit(3);

    @autoreleasepool {
        registerForNotifications(dispatch_get_main_queue());
        NSArray<NSString *> *names = @[
            notificationName(handle, "kMRMediaRemoteNowPlayingInfoDidChangeNotification"),
            notificationName(handle, "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"),
            notificationName(handle, "kMRMediaRemoteNowPlayingApplicationDidChangeNotification"),
        ];
        for (NSString *name in names) {
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                scheduleEmit();
            }];
        }

        commandBuffer = [NSMutableData data];
        commandSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(commandSource, ^{
            @autoreleasepool {
                readCommands();
            }
        });
        dispatch_resume(commandSource);

        emitState();
    }
    CFRunLoopRun();
    exit(0);
}
