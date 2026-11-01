//
//  UIBridgeAgent.xm
//  Runs inside every app process (injected by ellekit). Owns the UIKit view tree:
//  it can serialise it to JSON and act on individual views without any accessibility
//  entitlement, which is the only viable route on iOS 17 where the cross-process
//  AX server lives in the user bootstrap domain and is unreachable from a root daemon.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <errno.h>

#define UB_SOCKET_PATH "/var/jb/tmp/uibridge.sock"
#define UB_AGENT_VERSION "0.2.0"

#pragma mark - helpers

static NSString *UBBundleId(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (bid.length) return bid;
    // .appex / helper: fall back to the executable's parent bundle
    return [[[NSBundle mainBundle] bundlePath] lastPathComponent] ?: @"unknown";
}

static NSDictionary *UBFrameDict(CGRect r) {
    if (CGRectIsNull(r) || CGRectIsEmpty(r)) return nil;
    return @{
        @"x": @(round(r.origin.x)),
        @"y": @(round(r.origin.y)),
        @"w": @(round(r.size.width)),
        @"h": @(round(r.size.height)),
    };
}

#pragma mark - agent

@interface UBAgent : NSObject
@property (nonatomic, strong) NSMutableArray<UIView *> *views;
@property (nonatomic, assign) int fd;
@property (nonatomic, strong) NSMutableData *buffer;
+ (instancetype)shared;
- (void)start;
@end

@implementation UBAgent

+ (instancetype)shared {
    static UBAgent *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[UBAgent alloc] init]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _views = [NSMutableArray array];
        _fd = -1;
        _buffer = [NSMutableData data];
    }
    return self;
}

- (void)start {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self connectLoop];
    });
}

#pragma mark transport

- (void)connectLoop {
    while (1) {
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) {
            sleep(2);
            continue;
        }

        struct sockaddr_un addr;
        memset(&addr, 0, sizeof(addr));
        addr.sun_family = AF_UNIX;
        strlcpy(addr.sun_path, UB_SOCKET_PATH, sizeof(addr.sun_path));

        if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
            close(fd);
            sleep(2);
            continue;
        }

        self.fd = fd;
        [self.buffer setLength:0];
        [self sendLine:@{
            @"hello": @{
                @"bundleId": UBBundleId(),
                @"pid": @(getpid()),
                @"version": @UB_AGENT_VERSION,
            }
        }];

        [self readLoop];   // blocks until the connection dies
        close(fd);
        self.fd = -1;
        sleep(1);
    }
}

- (void)sendLine:(NSDictionary *)dict {
    if (self.fd < 0) return;
    NSData *json = [NSJSONSerialization dataWithJSONObject:dict options:0 error:NULL];
    if (!json) return;
    NSMutableData *out = [json mutableCopy];
    [out appendBytes:"\n" length:1];
    const uint8_t *bytes = (const uint8_t *)out.bytes;
    NSUInteger remaining = out.length;
    while (remaining > 0) {
        ssize_t n = write(self.fd, bytes, remaining);
        if (n <= 0) {
            if (errno == EINTR) continue;
            return;
        }
        bytes += n;
        remaining -= (NSUInteger)n;
    }
}

- (void)readLoop {
    uint8_t chunk[8192];
    while (1) {
        ssize_t n = read(self.fd, chunk, sizeof(chunk));
        if (n <= 0) return;
        [self.buffer appendBytes:chunk length:(NSUInteger)n];

        while (1) {
            const uint8_t *bytes = (const uint8_t *)self.buffer.bytes;
            NSUInteger len = self.buffer.length;
            NSUInteger cut = NSNotFound;
            for (NSUInteger i = 0; i < len; i++) {
                if (bytes[i] == '\n') {
                    cut = i;
                    break;
                }
            }
            if (cut == NSNotFound) break;

            NSData *line = [self.buffer subdataWithRange:NSMakeRange(0, cut)];
            [self.buffer replaceBytesInRange:NSMakeRange(0, cut + 1) withBytes:NULL length:0];
            if (line.length == 0) continue;

            NSDictionary *req = [NSJSONSerialization JSONObjectWithData:line options:0 error:NULL];
            if (![req isKindOfClass:[NSDictionary class]]) continue;
            [self handleRequest:req];
        }
    }
}

#pragma mark dispatch

- (void)handleRequest:(NSDictionary *)req {
    NSNumber *rid = req[@"id"] ?: @0;
    NSString *cmd = req[@"cmd"];

    __block NSDictionary *response = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        response = [self runCommand:cmd args:req] ?: @{ @"ok": @NO, @"error": @"empty result" };
    });

    NSMutableDictionary *out = [response mutableCopy];
    out[@"id"] = rid;
    [self sendLine:out];
}

- (NSDictionary *)runCommand:(NSString *)cmd args:(NSDictionary *)a {
    @try {
        if ([cmd isEqualToString:@"ping"]) {
            return @{ @"ok": @YES, @"result": @{ @"bundleId": UBBundleId(), @"pid": @(getpid()) } };
        }
        if ([cmd isEqualToString:@"dump"]) {
            return @{ @"ok": @YES, @"result": [self dumpTreeWithDepth:[a[@"depth"] integerValue] ?: 20] };
        }
        if ([cmd isEqualToString:@"tap"]) {
            return [self tapIndex:[a[@"index"] integerValue]];
        }
        if ([cmd isEqualToString:@"setValue"]) {
            return [self setText:a[@"value"] ?: @"" atIndex:[a[@"index"] integerValue]];
        }
        if ([cmd isEqualToString:@"frame"]) {
            return [self frameOfIndex:[a[@"index"] integerValue]];
        }
        if ([cmd isEqualToString:@"screen"]) {
            UIWindow *window = UIApplication.sharedApplication.windows.firstObject;
            return @{ @"ok": @YES, @"result": @{
                @"width": @(window.bounds.size.width),
                @"height": @(window.bounds.size.height),
            } };
        }
        return @{ @"ok": @NO, @"error": [NSString stringWithFormat:@"unknown agent cmd %@", cmd] };
    } @catch (NSException *ex) {
        return @{ @"ok": @NO, @"error": [NSString stringWithFormat:@"%@: %@", ex.name, ex.reason] };
    }
}

#pragma mark tree

- (NSString *)intrinsicLabelOf:(UIView *)v {
    if ([v isKindOfClass:[UILabel class]]) return ((UILabel *)v).text;
    if ([v isKindOfClass:[UIButton class]]) {
        UIButton *b = (UIButton *)v;
        NSString *title = [b titleForState:b.state] ?: b.titleLabel.text;
        if (title.length) return title;
        if (b.currentImage) return b.accessibilityLabel ?: @"button";
        return nil;
    }
    if ([v isKindOfClass:[UITextField class]]) return ((UITextField *)v).placeholder;
    if ([v isKindOfClass:[UISegmentedControl class]]) {
        UISegmentedControl *s = (UISegmentedControl *)v;
        NSInteger idx = s.selectedSegmentIndex;
        if (idx >= 0 && idx < (NSInteger)s.numberOfSegments) return [s titleForSegmentAtIndex:idx];
    }
    if ([v isKindOfClass:[UINavigationBar class]]) {
        return ((UINavigationBar *)v).topItem.title;
    }
    return nil;
}

- (NSString *)intrinsicValueOf:(UIView *)v {
    if ([v isKindOfClass:[UITextField class]]) return ((UITextField *)v).text;
    if ([v isKindOfClass:[UITextView class]]) return ((UITextView *)v).text;
    if ([v isKindOfClass:[UISwitch class]]) return ((UISwitch *)v).isOn ? @"1" : @"0";
    if ([v isKindOfClass:[UISlider class]]) return [NSString stringWithFormat:@"%.2f", ((UISlider *)v).value];
    return nil;
}

- (NSString *)roleOfView:(UIView *)v {
    if ([v isKindOfClass:[UIButton class]]) return @"Button";
    if ([v isKindOfClass:[UILabel class]]) return @"StaticText";
    if ([v isKindOfClass:[UITextField class]]) return @"TextField";
    if ([v isKindOfClass:[UITextView class]]) return @"TextView";
    if ([v isKindOfClass:[UISwitch class]]) return @"Switch";
    if ([v isKindOfClass:[UISlider class]]) return @"Slider";
    if ([v isKindOfClass:[UISegmentedControl class]]) return @"SegmentedControl";
    if ([v isKindOfClass:[UITableView class]]) return @"Table";
    if ([v isKindOfClass:[UICollectionView class]]) return @"Collection";
    if ([v isKindOfClass:[UITableViewCell class]]) return @"Cell";
    if ([v isKindOfClass:[UINavigationBar class]]) return @"NavigationBar";
    if ([v isKindOfClass:[UITabBar class]]) return @"TabBar";
    if ([v isKindOfClass:[UISearchBar class]]) return @"SearchBar";
    if ([v isKindOfClass:[UIScrollView class]]) return @"ScrollView";
    if ([v isKindOfClass:[UIImageView class]]) return @"Image";
    return @"View";
}

- (BOOL)isInteractive:(UIView *)v {
    return [v isKindOfClass:[UIControl class]] || [v isKindOfClass:[UITableViewCell class]] ||
           [v isKindOfClass:[UICollectionViewCell class]] ||
           [v respondsToSelector:@selector(accessibilityActivate)];
}

/// Screen-space frame: windowScene.coordinateSpace is the display, so a tap done with
/// HID at these coordinates lands on the same pixel.
- (CGRect)screenFrameOf:(UIView *)v {
    UIWindow *window = v.window;
    if (window && window.windowScene) {
        return [v convertRect:v.bounds toCoordinateSpace:window.windowScene.coordinateSpace];
    }
    return [v convertRect:v.bounds toView:nil];
}

- (void)collectFrom:(UIView *)v
              depth:(NSInteger)depth
           maxDepth:(NSInteger)maxDepth
                out:(NSMutableArray *)out
               seen:(NSMutableSet *)seen {
    if (v.hidden || v.alpha < 0.01) return;
    if ([seen containsObject:[NSValue valueWithPointer:(__bridge const void *)v]]) return;
    [seen addObject:[NSValue valueWithPointer:(__bridge const void *)v]];

    NSInteger index = (NSInteger)out.count;
    [self.views addObject:v];

    NSMutableDictionary *node = [NSMutableDictionary dictionary];
    node[@"i"] = @(index);
    node[@"cls"] = NSStringFromClass([v class]);
    node[@"role"] = [self roleOfView:v];

    NSString *label = v.accessibilityLabel ?: [self intrinsicLabelOf:v];
    if (label.length) node[@"label"] = label;
    NSString *value = v.accessibilityValue ?: [self intrinsicValueOf:v];
    if (value.length) node[@"value"] = value;
    if (v.accessibilityIdentifier.length) node[@"id"] = v.accessibilityIdentifier;
    node[@"enabled"] = @(v.isUserInteractionEnabled && !v.hidden);
    if (v.accessibilityTraits & UIAccessibilityTraitSelected) node[@"selected"] = @YES;

    NSDictionary *frame = UBFrameDict([self screenFrameOf:v]);
    if (frame) node[@"frame"] = frame;
    if ([self isInteractive:v]) node[@"actions"] = @[ @"AXPress" ];

    [out addObject:node];

    if (depth >= maxDepth) return;

    NSMutableArray *childIndexes = [NSMutableArray array];
    for (UIView *child in v.subviews) {
        NSInteger before = (NSInteger)out.count;
        [self collectFrom:child depth:depth + 1 maxDepth:maxDepth out:out seen:seen];
        if ((NSInteger)out.count > before) [childIndexes addObject:@(before)];
    }
    if (childIndexes.count) node[@"children"] = childIndexes;
}

- (NSDictionary *)dumpTreeWithDepth:(NSInteger)depth {
    [self.views removeAllObjects];
    if (depth <= 0) depth = 20;

    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    UIWindow *keyWindow = nil;

    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window.isKeyWindow) keyWindow = window;
    }
    if (!keyWindow && UIApplication.sharedApplication.windows.count) {
        keyWindow = UIApplication.sharedApplication.windows.firstObject;
    }

    if (keyWindow) {
        [self collectFrom:keyWindow depth:0 maxDepth:depth out:out seen:seen];
    }

    CGSize screen = keyWindow.bounds.size;
    return @{
        @"nodes": out,
        @"root": @0,
        @"nodeCount": @(out.count),
        @"bundleId": UBBundleId(),
        @"pid": @(getpid()),
        @"screen": @{ @"width": @(screen.width), @"height": @(screen.height) },
        @"source": @"uikit-view-tree",
    };
}

#pragma mark actions

- (UIView *)viewAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.views.count) return nil;
    UIView *v = self.views[index];
    return v.window ? v : nil;   // detached views are stale
}

- (NSDictionary *)tapIndex:(NSInteger)index {
    UIView *v = [self viewAtIndex:index];
    if (!v) return @{ @"ok": @NO, @"error": @"stale index, call dump first" };

    if ([v isKindOfClass:[UIControl class]]) {
        UIControl *c = (UIControl *)v;
        [c sendActionsForControlEvents:UIControlEventTouchUpInside];
        return @{ @"ok": @YES, @"result": @{ @"index": @(index), @"via": @"UIControl" } };
    }
    if ([v isKindOfClass:[UITableViewCell class]]) {
        UITableViewCell *cell = (UITableViewCell *)v;
        UITableView *table = (UITableView *)cell.superview;
        while (table && ![table isKindOfClass:[UITableView class]]) table = (UITableView *)table.superview;
        NSIndexPath *ip = [table indexPathForCell:cell];
        if (ip && [table.delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
            [table selectRowAtIndexPath:ip animated:NO scrollPosition:UITableViewScrollPositionNone];
            [table.delegate tableView:table didSelectRowAtIndexPath:ip];
            return @{ @"ok": @YES, @"result": @{ @"index": @(index), @"via": @"didSelectRow" } };
        }
    }
    if ([v respondsToSelector:@selector(accessibilityActivate)] && [v accessibilityActivate]) {
        return @{ @"ok": @YES, @"result": @{ @"index": @(index), @"via": @"accessibilityActivate" } };
    }

    // Last resort: report the frame so the caller can synthesise a touch instead.
    NSDictionary *frame = UBFrameDict([self screenFrameOf:v]);
    if (frame) {
        return @{ @"ok": @NO, @"error": @"not directly activatable", @"frame": frame };
    }
    return @{ @"ok": @NO, @"error": @"element not activatable" };
}

- (NSDictionary *)setText:(NSString *)text atIndex:(NSInteger)index {
    UIView *v = [self viewAtIndex:index];
    if (!v) return @{ @"ok": @NO, @"error": @"stale index, call dump first" };

    if ([v isKindOfClass:[UITextField class]]) {
        UITextField *tf = (UITextField *)v;
        tf.text = text;
        [tf sendActionsForControlEvents:UIControlEventEditingChanged];
        return @{ @"ok": @YES, @"result": @{ @"via": @"UITextField" } };
    }
    if ([v isKindOfClass:[UITextView class]]) {
        UITextView *tv = (UITextView *)v;
        tv.text = text;
        [[NSNotificationCenter defaultCenter] postNotificationName:UITextViewTextDidChangeNotification object:tv];
        return @{ @"ok": @YES, @"result": @{ @"via": @"UITextView" } };
    }
    if ([v isKindOfClass:[UISwitch class]]) {
        [(UISwitch *)v setOn:text.boolValue animated:YES];
        [(UISwitch *)v sendActionsForControlEvents:UIControlEventValueChanged];
        return @{ @"ok": @YES, @"result": @{ @"via": @"UISwitch" } };
    }

    NSDictionary *frame = UBFrameDict([self screenFrameOf:v]);
    if (frame) return @{ @"ok": @NO, @"error": @"not a text input", @"frame": frame };
    return @{ @"ok": @NO, @"error": @"element cannot take text" };
}

- (NSDictionary *)frameOfIndex:(NSInteger)index {
    UIView *v = [self viewAtIndex:index];
    if (!v) return @{ @"ok": @NO, @"error": @"stale index" };
    return @{ @"ok": @YES, @"result": UBFrameDict([self screenFrameOf:v]) ?: @{} };
}

@end

#pragma mark - injection

static void UBLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"[uibridge-agent %d] %@\n", getpid(), message];
    NSArray *paths = @[ @"/var/jb/var/log/uibridge-agent.log", @"/tmp/uibridge-agent.log" ];
    for (NSString *path in paths) {
        FILE *fp = fopen(path.UTF8String, "a");
        if (!fp) continue;
        fputs(line.UTF8String, fp);
        fclose(fp);
        break;
    }
}

%ctor {
    UBLog(@"ctor fired bundle=%@", UBBundleId());
    // Wait for UIKit to come up; every UIApplication-bearing process gets this tweak.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (int i = 0; i < 120; i++) {
            __block BOOL ready = NO;
            dispatch_sync(dispatch_get_main_queue(), ^{
                ready = (UIApplication.sharedApplication != nil);
            });
            if (ready) break;
            usleep(250000);
        }
        [[UBAgent shared] start];
    });
}
