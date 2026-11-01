//
//  main.m
//  uibridge -- launchd daemon entry point
//

#import <Foundation/Foundation.h>

#import "AXBridge.h"
#import "HIDInjector.h"
#import "LCCommands.h"
#import "LCServer.h"
#import "UBAgentHub.h"

#import <signal.h>
#import <unistd.h>

int main(int argc, char *argv[]) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        setvbuf(stdout, NULL, _IOLBF, 0);

        uint16_t port = 9700;
        if (argc > 1) {
            int requested = atoi(argv[1]);
            if (requested > 0 && requested < 65536) port = (uint16_t)requested;
        }

        // Optional shared secret. Empty means "accept any local client", which is fine
        // on a trusted LAN but worth setting on anything shared.
        NSString *token = [[[NSProcessInfo processInfo] environment] objectForKey:@"UIBRIDGE_TOKEN"];
        if (argc > 2) token = @(argv[2]);
        if (token.length) {
            [LCCommands setToken:token];
            NSLog(@"[uibridge] token authentication enabled");
        }

        NSLog(@"[uibridge] pid=%d starting on 0.0.0.0:%u", getpid(), port);
        NSLog(@"[uibridge] ax ready=%d hid ready=%d",
              [[AXBridge shared] isReady], [[HIDInjector shared] isReady]);
        NSLog(@"[uibridge] ax diag=%@", [[AXBridge shared] diagnostics]);
        NSLog(@"[uibridge] hid diag=%@", [[HIDInjector shared] diagnostics]);

        if (![[UBAgentHub shared] start]) {
            NSLog(@"[uibridge] warning: agent socket unavailable, per-app agents cannot attach");
        }

        if (![[LCServer shared] startOnPort:port]) {
            NSLog(@"[uibridge] fatal: cannot bind port %u", port);
            return 1;
        }

        NSLog(@"[uibridge] listening");
        dispatch_main();
    }
    return 0;
}
