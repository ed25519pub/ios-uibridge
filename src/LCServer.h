//
//  LCServer.h
//  uibridge -- newline delimited JSON over TCP + AX worker forwarding
//

#import <Foundation/Foundation.h>

@interface LCServer : NSObject

+ (instancetype)shared;

/// Binds 0.0.0.0:<port> and starts the accept loop. Returns NO if bind fails.
- (BOOL)startOnPort:(uint16_t)port;

/// AX service apps attach in and register here (called internally on the hello frame).
+ (void)registerWorker:(int)fd bundleId:(NSString *)bundleId info:(NSDictionary *)info;
+ (NSArray<NSDictionary *> *)workers;
+ (BOOL)hasWorker;

/// Blocking request to the attached AX worker, serialised so replies stay correlated.
+ (NSDictionary *)callWorker:(NSString *)cmd
                        args:(NSDictionary *)args
                     timeout:(NSTimeInterval)timeout;

@end
