//
//  AXBridge.h
//  uibridge -- accessibility-tree access layer (the iOS analogue of uiautomator2's UiAutomation)
//

#import <Foundation/Foundation.h>
#include <sys/types.h>

typedef const struct __AXUIElement *AXUIElementRef;
typedef const struct __AXValue *AXValueRef;

typedef int32_t AXError;
enum {
    kAXErrorSuccess = 0,
    kAXErrorFailure = -25200,
    kAXErrorIllegalArgument = -25201,
    kAXErrorInvalidUIElement = -25202,
    kAXErrorInvalidUIElementObserver = -25203,
    kAXErrorCannotComplete = -25204,
    kAXErrorAPIDisabled = -25211,
};

// AXValueType
enum {
    kAXValueTypeCGPoint = 1,
    kAXValueTypeCGSize = 2,
    kAXValueTypeCGRect = 3,
};

@interface AXBridge : NSObject

+ (instancetype)shared;

/// YES once libAccessibility symbols resolved.
- (BOOL)isReady;
/// Human readable diagnostics (which dlopen path worked, which symbols are missing).
- (NSDictionary *)diagnostics;

/// device model / iOS version / screen size / frontmost app.
- (NSDictionary *)deviceInfo;

/// {bundleId, pid} of the app in front. Uses SpringBoardServices (works from the
/// system bootstrap domain) with an AX fallback for iOS <= 16.
- (NSDictionary *)frontmostApp;

/// {width, height, orientation} in points.
- (NSDictionary *)screenMetrics;

/// Walk the frontmost application (plus any SpringBoard-owned system alert) and return a
/// flat node list. Every node gets a stable `i` index valid until the next dump.
- (NSDictionary *)dumpWithDepth:(NSInteger)depth
                       maxNodes:(NSInteger)maxNodes
            includeSystemAlerts:(BOOL)includeAlerts
                      bundleId:(NSString *)bundleId;

/// Borrowed element for an index produced by the most recent dump. NULL when stale.
- (AXUIElementRef)elementAtIndex:(NSInteger)idx;
- (NSInteger)elementCount;
- (NSUInteger)dumpGeneration;

/// Search the last dump for nodes matching text (label/title/value/id, substring) and/or role.
/// Pass limit <= 0 for "no limit".
- (NSArray<NSDictionary *> *)queryNodesWithText:(NSString *)text
                                           role:(NSString *)role
                                          limit:(NSInteger)limit;

/// Serialized node dict for an index from the most recent dump (nil when stale).
- (NSDictionary *)nodeAtIndex:(NSInteger)idx;

- (BOOL)performAction:(NSString *)action atIndex:(NSInteger)idx error:(NSString **)error;
- (BOOL)setValue:(NSString *)value atIndex:(NSInteger)idx error:(NSString **)error;
- (BOOL)focusAtIndex:(NSInteger)idx error:(NSString **)error;

/// Point -> deepest element hit test (uses AXUIElementCopyElementAtPosition on the front app).
- (NSInteger)indexForPoint:(CGPoint)point;

/// Scan every loaded image's symbol table for exported names containing `needle`.
/// Diagnostic helper: iOS 17 renamed parts of the AX C API and the only reliable way
/// to find the new spelling is to look at what the image actually exports.
+ (NSArray<NSString *> *)scanSymbolsContaining:(NSString *)needle;

@end
