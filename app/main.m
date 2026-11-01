//
//  main.m (UIBridgeSvc app)
//  Accessibility worker hosted by a GUI process.
//
//  Why: on iOS 17 `com.apple.iphone.axserver` is registered in the graphical user
//  session bootstrap. A root launchd daemon gets BOOTSTRAP_UNKNOWN_SERVICE (1102)
//  and every AXUIElement call fails with -25216. A LaunchServices-launched app
//  inherits that session, so the AX half of the bridge runs here.
//
//  Why it connects *out* instead of listening: iOS local-network privacy drops
//  packets aimed at an app's listening port (measured: host -> app:9701 timeout,
//  while host -> daemon:9700 fine). Loopback connections the app initiates are
//  unaffected, so this app dials 127.0.0.1:9700 and the root daemon forwards
//  accessibility queries down that socket.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

#import "AXBridge.h"

#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <errno.h>

#define UB_DAEMON_PORT 9700
#define UB_WORKER_VERSION "0.3.0"

#pragma mark - logging

static void UBAppLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[uibridge-svc] %@", message);
}

#pragma mark - worker transport

static int UBConnectDaemon(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(UB_DAEMON_PORT);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static BOOL UBWriteAll(int fd, NSData *data) {
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger remaining = data.length;
    while (remaining > 0) {
        ssize_t n = write(fd, bytes, remaining);
        if (n <= 0) {
            if (errno == EINTR) continue;
            return NO;
        }
        bytes += n;
        remaining -= (NSUInteger)n;
    }
    return YES;
}

static BOOL UBSendJSON(int fd, NSDictionary *dict) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:dict options:0 error:NULL];
    if (!json) return NO;
    NSMutableData *out = [json mutableCopy];
    [out appendBytes:"\n" length:1];
    return UBWriteAll(fd, out);
}

#pragma mark - command handling

/// AXBridge keeps per-dump state, so every query is serialised through one queue.
static dispatch_queue_t gAXQueue = NULL;

static NSDictionary *UBHandleCommand(NSDictionary *request) {
    NSString *cmd = request[@"cmd"];
    if (![cmd isKindOfClass:[NSString class]]) {
        return @{ @"ok": @NO, @"error": @"missing cmd" };
    }

    __block NSDictionary *result = nil;
    dispatch_sync(gAXQueue, ^{
        AXBridge *ax = [AXBridge shared];
        @try {
            if ([cmd isEqualToString:@"ping"]) {
                result = @{ @"ok": @YES, @"result": @{
                    @"pong": @YES, @"ax": @([ax isReady]), @"pid": @(getpid()), @"role": @"ax-worker",
                } };
            } else if ([cmd isEqualToString:@"dump"]) {
                NSInteger depth = [request[@"depth"] integerValue];
                if (depth <= 0) depth = 20;
                NSString *bid = [request[@"bundleId"] isKindOfClass:[NSString class]] ? request[@"bundleId"] : nil;
                NSDictionary *dump = [ax dumpWithDepth:depth maxNodes:2500 includeSystemAlerts:YES bundleId:bid];
                result = dump[@"error"] ? @{ @"ok": @NO, @"error": dump[@"error"] }
                                        : @{ @"ok": @YES, @"result": dump };
            } else if ([cmd isEqualToString:@"screen"]) {
                result = @{ @"ok": @YES, @"result": [ax screenMetrics] };
            } else if ([cmd isEqualToString:@"frontmost"]) {
                result = @{ @"ok": @YES, @"result": [ax frontmostApp] };
            } else if ([cmd isEqualToString:@"diag"]) {
                result = @{ @"ok": @YES, @"result": [ax diagnostics] };
            } else {
                result = @{ @"ok": @NO,
                            @"error": [NSString stringWithFormat:@"ax worker does not handle %@", cmd] };
            }
        } @catch (NSException *ex) {
            result = @{ @"ok": @NO, @"error": [NSString stringWithFormat:@"%@: %@", ex.name, ex.reason] };
        }
    });
    return result;
}

/// Persistent connection to the daemon; reconnects forever.
static void UBWorkerLoop(void) {
    while (1) {
        int fd = UBConnectDaemon();
        if (fd < 0) {
            usleep(2000000);
            continue;
        }

        NSDictionary *hello = @{ @"hello": @{
            @"bundleId": [[NSBundle mainBundle] bundleIdentifier] ?: @"com.yg.uibridgesvc",
            @"pid": @(getpid()),
            @"role": @"ax",
            @"version": @UB_WORKER_VERSION,
            @"axReady": @([[AXBridge shared] isReady]),
        } };
        if (!UBSendJSON(fd, hello)) {
            close(fd);
            usleep(1000000);
            continue;
        }
        UBAppLog(@"attached to daemon on %d", UB_DAEMON_PORT);

        NSMutableData *buffer = [NSMutableData data];
        uint8_t chunk[8192];
        BOOL alive = YES;
        while (alive) {
            ssize_t n = read(fd, chunk, sizeof(chunk));
            if (n <= 0) break;
            [buffer appendBytes:chunk length:(NSUInteger)n];

            BOOL again = YES;
            while (again) {
                again = NO;
                const uint8_t *bytes = (const uint8_t *)buffer.bytes;
                for (NSUInteger i = 0; i < buffer.length; i++) {
                    if (bytes[i] != '\n') continue;

                    NSData *line = [buffer subdataWithRange:NSMakeRange(0, i)];
                    [buffer replaceBytesInRange:NSMakeRange(0, i + 1) withBytes:NULL length:0];

                    if (line.length > 0) {
                        NSDictionary *request = [NSJSONSerialization JSONObjectWithData:line options:0 error:NULL];
                        if ([request isKindOfClass:[NSDictionary class]]) {
                            NSMutableDictionary *reply = [UBHandleCommand(request) mutableCopy];
                            reply[@"id"] = request[@"id"] ?: @0;
                            if (!UBSendJSON(fd, reply)) { alive = NO; }
                        }
                    }
                    again = YES;
                    break;
                }
            }
        }

        close(fd);
        UBAppLog(@"daemon connection lost, retrying");
        usleep(2000000);
    }
}

#pragma mark - silent-audio keep alive

static AVAudioPlayer *gKeepAlivePlayer = nil;

static NSData *UBSilenceWAV(NSUInteger seconds) {
    NSUInteger sampleRate = 8000;
    NSUInteger dataBytes = sampleRate * seconds * 2;   // 16-bit mono
    NSMutableData *wav = [NSMutableData dataWithCapacity:44 + dataBytes];

    uint32_t u32;
    uint16_t u16;

    [wav appendBytes:"RIFF" length:4];
    u32 = (uint32_t)(36 + dataBytes); [wav appendBytes:&u32 length:4];
    [wav appendBytes:"WAVEfmt " length:8];
    u32 = 16; [wav appendBytes:&u32 length:4];
    u16 = 1;  [wav appendBytes:&u16 length:2];
    u16 = 1;  [wav appendBytes:&u16 length:2];
    u32 = (uint32_t)sampleRate; [wav appendBytes:&u32 length:4];
    u32 = (uint32_t)(sampleRate * 2); [wav appendBytes:&u32 length:4];
    u16 = 2;  [wav appendBytes:&u16 length:2];
    u16 = 16; [wav appendBytes:&u16 length:2];
    [wav appendBytes:"data" length:4];
    u32 = (uint32_t)dataBytes; [wav appendBytes:&u32 length:4];
    [wav appendData:[NSMutableData dataWithLength:dataBytes]];

    return wav;
}

static void UBStartKeepAlive(void) {
    NSError *error = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback
             withOptions:AVAudioSessionCategoryOptionMixWithOthers
                   error:&error];
    [session setActive:YES error:&error];

    gKeepAlivePlayer = [[AVAudioPlayer alloc] initWithData:UBSilenceWAV(5) error:&error];
    gKeepAlivePlayer.numberOfLoops = -1;
    gKeepAlivePlayer.volume = 0.0;
    [gKeepAlivePlayer play];
}

#pragma mark - delegate

@interface UBServiceDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation UBServiceDelegate

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    gAXQueue = dispatch_queue_create("com.yg.uibridge.ax", DISPATCH_QUEUE_SERIAL);

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    UIViewController *controller = [[UIViewController alloc] init];
    controller.view.backgroundColor = [UIColor blackColor];
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];

    UBStartKeepAlive();

    AXBridge *ax = [AXBridge shared];
    UBAppLog(@"launched pid=%d ax ready=%d", getpid(), [ax isReady]);
    UBAppLog(@"bootstrap=%@", [ax diagnostics][@"bootstrapLookup"]);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        UBWorkerLoop();
    });
    return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    UBAppLog(@"backgrounded, staying resident");
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([UBServiceDelegate class]));
    }
}
