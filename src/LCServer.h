//
//  LCServer.h
//  uibridge -- newline delimited JSON over TCP
//

#import <Foundation/Foundation.h>

@interface LCServer : NSObject

+ (instancetype)shared;

/// Binds 0.0.0.0:<port> and starts the accept loop. Returns NO if bind fails.
- (BOOL)startOnPort:(uint16_t)port;

@end
