//
//  HIDInjector.h
//  uibridge -- synthetic touch / keyboard injection through IOHIDEventSystem
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@interface HIDInjector : NSObject

+ (instancetype)shared;

- (BOOL)isReady;
- (NSDictionary *)diagnostics;

/// Single tap at a screen point given in points (not pixels).
- (void)tapAt:(CGPoint)point;
- (void)longPressAt:(CGPoint)point duration:(NSTimeInterval)duration;
- (void)swipeFrom:(CGPoint)from to:(CGPoint)to duration:(NSTimeInterval)duration;
- (void)dragFrom:(CGPoint)from to:(CGPoint)to duration:(NSTimeInterval)duration;

/// Swipe that keeps the finger down at the destination for `hold` seconds before
/// lifting -- this is what makes the iOS "swipe up and pause" app-switcher gesture work.
- (void)swipeFrom:(CGPoint)from
               to:(CGPoint)to
         duration:(NSTimeInterval)duration
       holdAtEnd:(NSTimeInterval)hold;

/// Type an ASCII / latin string through the virtual keyboard.
- (void)typeString:(NSString *)string;

/// Raw HID keyboard usage (page 0x07), e.g. 0x28 = Return, 0x29 = Escape.
- (void)pressKeyUsage:(uint32_t)usage;

/// Raw HID usage on an arbitrary page, e.g. page 0x0C usage 0x30 = power key.
- (void)pressKeyUsage:(uint32_t)usage onPage:(uint32_t)page;

@end
