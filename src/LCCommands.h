//
//  LCCommands.h
//  uibridge -- JSON command router (the protocol an AI client speaks)
//

#import <Foundation/Foundation.h>

@interface LCCommands : NSObject

/// When non-empty, every request must carry "token" with this exact value.
+ (void)setToken:(NSString *)token;

/// `line` is one UTF-8 JSON object without the trailing newline.
/// Returns one UTF-8 JSON object (without trailing newline).
+ (NSData *)handleLine:(NSData *)line;

@end
