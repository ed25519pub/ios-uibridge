//
//  UBAgentHub.h
//  daemon-side broker for the per-app agents.
//
//  iOS 17 puts axserver in the user bootstrap domain, so a root launchd daemon cannot
//  reach it. Instead every app process runs UIBridgeAgent (a tweak) which owns its own
//  UIKit tree; the daemon talks to the app that is currently in the foreground over a
//  unix socket.
//

#import <Foundation/Foundation.h>

@interface UBAgentHub : NSObject

+ (instancetype)shared;

/// Binds /var/jb/tmp/uibridge.sock and starts accepting agent connections.
- (BOOL)start;

/// [{bundleId, pid, version}]
- (NSArray<NSDictionary *> *)agents;

- (BOOL)hasAgent:(NSString *)bundleId;

/// Blocking request/response against one app's agent.
- (NSDictionary *)call:(NSString *)cmd
                  args:(NSDictionary *)args
              bundleId:(NSString *)bundleId
               timeout:(NSTimeInterval)timeout;

@end
