//
//  main.m (UIBridgeSvc app)
//  A GUI process whose only purpose is to hold the accessibility connection.
//
//  Why this exists: on iOS 17 `com.apple.iphone.axserver` is registered in the
//  graphical user session bootstrap, so a root launchd daemon gets
//  BOOTSTRAP_UNKNOWN_SERVICE (1102) and every AXUIElement call fails with -25216.
//  A process launched by LaunchServices -- i.e. an app -- inherits that session,
//  can reach axserver, and with `com.apple.private.accessibility` can read the
//  accessibility tree of whatever app is in front.
//
//  Everything else (HID injection, unix socket broker) still lives in the root
//  daemon; this app is only the AX half.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

#import "AXBridge.h"
#import "HIDInjector.h"
#import "LCCommands.h"
#import "LCServer.h"

#define UB_SVC_PORT 9701

#pragma mark - silent-audio keep alive
//
// iOS suspends a backgrounded app within seconds. A playback audio session with an
// endless silent stream is the standard way to stay resident, and on a jailbroken
// device it is the difference between "works while on screen" and "actually usable".

static AVAudioPlayer *gKeepAlivePlayer = nil;

static NSData *UBSilenceWAV(NSUInteger seconds) {
    NSUInteger sampleRate = 8000;
    NSUInteger frames = sampleRate * seconds;
    NSUInteger dataBytes = frames * 2;                 // 16-bit mono
    NSMutableData *wav = [NSMutableData dataWithCapacity:44 + dataBytes];

    uint32_t u32;
    uint16_t u16;

    [wav appendBytes:"RIFF" length:4];
    u32 = (uint32_t)(36 + dataBytes); [wav appendBytes:&u32 length:4];
    [wav appendBytes:"WAVEfmt " length:8];
    u32 = 16; [wav appendBytes:&u32 length:4];
    u16 = 1;  [wav appendBytes:&u16 length:2];         // PCM
    u16 = 1;  [wav appendBytes:&u16 length:2];         // mono
    u32 = (uint32_t)sampleRate; [wav appendBytes:&u32 length:4];
    u32 = (uint32_t)(sampleRate * 2); [wav appendBytes:&u32 length:4];
    u16 = 2;  [wav appendBytes:&u16 length:2];         // block align
    u16 = 16; [wav appendBytes:&u16 length:2];         // bits per sample
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
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    UIViewController *controller = [[UIViewController alloc] init];
    controller.view.backgroundColor = [UIColor blackColor];
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];

    UBStartKeepAlive();

    AXBridge *ax = [AXBridge shared];
    HIDInjector *hid = [HIDInjector shared];

    NSLog(@"[uibridge-svc] launched pid=%d ax ready=%d hid ready=%d", getpid(), [ax isReady], [hid isReady]);
    NSLog(@"[uibridge-svc] ax diag=%@", [ax diagnostics]);

    if ([[LCServer shared] startOnPort:UB_SVC_PORT]) {
        NSLog(@"[uibridge-svc] listening on %d", UB_SVC_PORT);
    } else {
        NSLog(@"[uibridge-svc] failed to bind %d", UB_SVC_PORT);
    }
    return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    // Keep the socket alive; the audio session already prevents suspension.
    NSLog(@"[uibridge-svc] backgrounded, staying resident");
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([UBServiceDelegate class]));
    }
}
