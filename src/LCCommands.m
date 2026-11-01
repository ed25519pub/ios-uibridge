//
//  LCCommands.m
//  uibridge -- command router
//
//  Wire protocol: one UTF-8 JSON object per line.
//    request : {"id":1,"cmd":"dump","depth":16}
//    response: {"id":1,"ok":true,"result":{...}}  |  {"id":1,"ok":false,"error":"..."}
//
//  Element tree source, in order of preference:
//    1. the injected per-app agent (UIBridgeAgent) -- works on iOS 15..17+
//    2. the cross-process AXUIElement API     -- iOS <= 16 only, axserver is in the
//                                                user bootstrap domain on iOS 17
//

#import "LCCommands.h"
#import "AXBridge.h"
#import "HIDInjector.h"
#import "UBAgentHub.h"

#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <unistd.h>

#pragma mark - helpers

static NSMutableDictionary *Fail(NSString *msg) {
    return [@{ @"ok": @NO, @"error": msg ?: @"unknown error" } mutableCopy];
}

static NSMutableDictionary *Ok(NSDictionary *result) {
    return [@{ @"ok": @YES, @"result": result ?: @{} } mutableCopy];
}

static double Num(NSDictionary *d, NSString *key, double fallback) {
    id v = d[key];
    return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : fallback;
}

static NSInteger Int(NSDictionary *d, NSString *key, NSInteger fallback) {
    id v = d[key];
    return [v respondsToSelector:@selector(integerValue)] ? [v integerValue] : fallback;
}

static CGPoint PointFrom(NSDictionary *d, NSString *xk, NSString *yk) {
    return CGPointMake(Num(d, xk, 0), Num(d, yk, 0));
}

static CGPoint CenterOfFrame(NSDictionary *frame) {
    return CGPointMake([frame[@"x"] doubleValue] + [frame[@"w"] doubleValue] / 2.0,
                       [frame[@"y"] doubleValue] + [frame[@"h"] doubleValue] / 2.0);
}

/// Fails fast with diagnostics instead of silently doing nothing.
#define HID_REQUIRE(hid)                                                                          \
    do {                                                                                          \
        if (![(hid) isReady])                                                                     \
            return Fail([NSString stringWithFormat:@"HID injection unavailable: %@",              \
                                                   [(hid) diagnostics]]);                         \
    } while (0)

#pragma mark - router

static NSString *gToken = nil;

@implementation LCCommands

+ (void)setToken:(NSString *)token {
    gToken = [token copy];
}

+ (NSData *)handleLine:(NSData *)line {
    NSNumber *requestId = @0;
    NSMutableDictionary *response = nil;

    @autoreleasepool {
        NSError *jsonError = nil;
        id parsed = [NSJSONSerialization JSONObjectWithData:line options:0 error:&jsonError];

        if (![parsed isKindOfClass:[NSDictionary class]]) {
            response = Fail(jsonError.localizedDescription ?: @"request is not a JSON object");
        } else {
            NSDictionary *req = parsed;
            if ([req[@"id"] respondsToSelector:@selector(integerValue)]) requestId = req[@"id"];

            NSString *cmd = req[@"cmd"];
            if (gToken.length) {
                NSString *supplied = req[@"token"];
                if (![supplied isKindOfClass:[NSString class]] || ![supplied isEqualToString:gToken]) {
                    cmd = nil;
                    response = Fail(@"unauthorized: bad or missing token");
                }
            }

            if (!response && (![cmd isKindOfClass:[NSString class]] || cmd.length == 0)) {
                response = Fail(@"missing \"cmd\"");
            } else if (!response) {
                @try {
                    response = [self runCommand:cmd args:req];
                } @catch (NSException *ex) {
                    response = Fail([NSString stringWithFormat:@"%@: %@", ex.name, ex.reason]);
                }
            }
        }

        response[@"id"] = requestId;
    }

    NSData *out = [NSJSONSerialization dataWithJSONObject:response options:0 error:NULL];
    return out ?: [@"{\"id\":0,\"ok\":false,\"error\":\"serialization failed\"}\n" dataUsingEncoding:NSUTF8StringEncoding];
}

#pragma mark - tree helpers

+ (NSString *)frontmostBundleId {
    NSDictionary *front = [[AXBridge shared] frontmostApp];
    NSString *bid = front[@"bundleId"];
    return [bid isKindOfClass:[NSString class]] ? bid : nil;
}

/// Dumps through the agent when the target app has one, otherwise falls back to AX.
+ (NSMutableDictionary *)treeForBundleId:(NSString *)requested depth:(NSInteger)depth {
    UBAgentHub *hub = [UBAgentHub shared];
    NSString *target = requested.length ? requested : [self frontmostBundleId];

    if (target.length && [hub hasAgent:target]) {
        NSDictionary *resp = [hub call:@"dump" args:@{ @"depth": @(depth) } bundleId:target timeout:12.0];
        if (![resp[@"ok"] boolValue]) return Fail(resp[@"error"] ?: @"agent dump failed");
        NSMutableDictionary *result = [resp[@"result"] mutableCopy];
        result[@"source"] = @"agent";
        result[@"bundleId"] = target;
        return Ok(result);
    }

    AXBridge *ax = [AXBridge shared];
    if (![ax isReady]) {
        return Fail([NSString stringWithFormat:
                     @"no connected agent for %@ and the AX fallback is unavailable on this iOS. "
                     @"Make sure the app is in the foreground and UIBridgeAgent is injected.",
                     target ?: @"<unknown>"]);
    }

    NSDictionary *dump = [ax dumpWithDepth:depth maxNodes:2500 includeSystemAlerts:YES bundleId:requested];
    if (dump[@"error"]) return Fail(dump[@"error"]);
    NSMutableDictionary *result = [dump mutableCopy];
    result[@"source"] = @"ax";
    return Ok(result);
}

+ (NSMutableDictionary *)runCommand:(NSString *)cmd args:(NSDictionary *)a {
    AXBridge *ax = [AXBridge shared];
    HIDInjector *hid = [HIDInjector shared];
    UBAgentHub *hub = [UBAgentHub shared];

    // ---------------------------------------------------------------- meta
    if ([cmd isEqualToString:@"ping"]) {
        return Ok(@{ @"pong": @YES, @"ax": @([ax isReady]), @"hid": @([hid isReady]),
                     @"agents": @([hub agents].count) });
    }

    if ([cmd isEqualToString:@"agents"]) {
        return Ok(@{ @"agents": [hub agents] ?: @[] });
    }

    if ([cmd isEqualToString:@"info"]) {
        NSMutableDictionary *info = [[ax deviceInfo] mutableCopy];
        info[@"axDiagnostics"] = [ax diagnostics];
        info[@"hidDiagnostics"] = [hid diagnostics];
        info[@"agents"] = [hub agents] ?: @[];
        return Ok(info);
    }

    if ([cmd isEqualToString:@"diag"]) {
        return Ok(@{ @"ax": [ax diagnostics], @"hid": [hid diagnostics], @"agents": [hub agents] ?: @[] });
    }

    if ([cmd isEqualToString:@"symbols"]) {
        NSString *needle = [a[@"needle"] isKindOfClass:[NSString class]] ? a[@"needle"] : @"AXUIElement";
        NSArray *found = [AXBridge scanSymbolsContaining:needle];
        return Ok(@{ @"needle": needle, @"count": @(found.count), @"symbols": found });
    }

    if ([cmd isEqualToString:@"screen"]) {
        NSString *target = [self frontmostBundleId];
        if (target.length && [hub hasAgent:target]) {
            NSDictionary *resp = [hub call:@"screen" args:@{} bundleId:target timeout:5.0];
            if ([resp[@"ok"] boolValue]) return Ok(resp[@"result"]);
        }
        return Ok([[ax deviceInfo] objectForKey:@"screen"] ?: @{});
    }

    if ([cmd isEqualToString:@"frontmost"]) {
        NSMutableDictionary *front = [[ax frontmostApp] mutableCopy];
        NSString *bid = front[@"bundleId"];
        if (bid.length) front[@"hasAgent"] = @([hub hasAgent:bid]);
        return Ok(front);
    }

    // ---------------------------------------------------------------- tree
    if ([cmd isEqualToString:@"dump"]) {
        NSInteger depth = Int(a, @"depth", 20);
        NSString *bundleId = [a[@"bundleId"] isKindOfClass:[NSString class]] ? a[@"bundleId"] : nil;
        return [self treeForBundleId:bundleId depth:depth];
    }

    if ([cmd isEqualToString:@"find"]) {
        NSString *text = [a[@"text"] isKindOfClass:[NSString class]] ? a[@"text"] : nil;
        NSString *role = [a[@"role"] isKindOfClass:[NSString class]] ? a[@"role"] : nil;
        NSInteger limit = Int(a, @"limit", 20);
        NSString *bundleId = [a[@"bundleId"] isKindOfClass:[NSString class]] ? a[@"bundleId"] : nil;

        NSMutableDictionary *dump = [self treeForBundleId:bundleId depth:20];
        if (![dump[@"ok"] boolValue]) return dump;

        NSMutableArray *hits = [NSMutableArray array];
        for (NSDictionary *n in dump[@"result"][@"nodes"]) {
            if (role.length && ![n[@"role"] isEqualToString:role]) continue;
            if (text.length) {
                BOOL matched = NO;
                for (NSString *k in @[ @"label", @"title", @"value", @"id", @"placeholder" ]) {
                    NSString *v = n[k];
                    if ([v isKindOfClass:[NSString class]] &&
                        [v rangeOfString:text options:NSCaseInsensitiveSearch].location != NSNotFound) {
                        matched = YES;
                        break;
                    }
                }
                if (!matched) continue;
            }
            [hits addObject:n];
            if (limit > 0 && (NSInteger)hits.count >= limit) break;
        }
        return Ok(@{ @"nodes": hits, @"count": @(hits.count) });
    }

    if ([cmd isEqualToString:@"hit"]) {
        CGPoint p = PointFrom(a, @"x", @"y");
        NSInteger idx = [ax indexForPoint:p];
        return Ok(@{ @"index": @(idx), @"found": @(idx >= 0) });
    }

    // ---------------------------------------------------------------- gestures
    if ([cmd isEqualToString:@"tap"]) {
        HID_REQUIRE(hid);
        CGPoint p = PointFrom(a, @"x", @"y");
        [hid tapAt:p];
        return Ok(@{ @"tapped": @[ @(p.x), @(p.y) ] });
    }

    if ([cmd isEqualToString:@"tapElement"]) {
        NSInteger idx = Int(a, @"index", -1);
        NSString *target = [self frontmostBundleId];

        if (target.length && [hub hasAgent:target]) {
            NSDictionary *resp = [hub call:@"tap" args:@{ @"index": @(idx) } bundleId:target timeout:8.0];
            if ([resp[@"ok"] boolValue]) {
                NSMutableDictionary *result = [resp[@"result"] mutableCopy];
                result[@"index"] = @(idx);
                return Ok(result);
            }
            NSDictionary *frame = resp[@"frame"];
            if (frame) {
                HID_REQUIRE(hid);
                CGPoint c = CenterOfFrame(frame);
                [hid tapAt:c];
                return Ok(@{ @"action": @"tap", @"index": @(idx), @"point": @[ @(c.x), @(c.y) ],
                             @"note": resp[@"error"] ?: @"" });
            }
            return Fail(resp[@"error"] ?: @"agent could not activate element");
        }

        // ---- AX fallback (iOS <= 16)
        AXUIElementRef el = [ax elementAtIndex:idx];
        if (!el) return Fail(@"stale index and no agent connected, call dump first");
        NSString *axError = nil;
        if (!a[@"forceTap"] && [ax performAction:@"AXPress" atIndex:idx error:&axError]) {
            return Ok(@{ @"action": @"AXPress", @"index": @(idx) });
        }
        NSDictionary *meta = [ax nodeAtIndex:idx];
        NSDictionary *f = meta[@"frame"];
        if (!f) return Fail(@"element has no frame and no AXPress action");
        HID_REQUIRE(hid);
        CGPoint c = CenterOfFrame(f);
        [hid tapAt:c];
        return Ok(@{ @"action": @"tap", @"index": @(idx), @"point": @[ @(c.x), @(c.y) ] });
    }

    if ([cmd isEqualToString:@"longPress"]) {
        HID_REQUIRE(hid);
        CGPoint p = PointFrom(a, @"x", @"y");
        double duration = Num(a, @"duration", 0.8);
        [hid longPressAt:p duration:duration];
        return Ok(@{ @"longPressed": @[ @(p.x), @(p.y) ], @"duration": @(duration) });
    }

    if ([cmd isEqualToString:@"swipe"]) {
        HID_REQUIRE(hid);
        CGPoint from = PointFrom(a, @"x1", @"y1");
        CGPoint to = PointFrom(a, @"x2", @"y2");
        double duration = Num(a, @"duration", 0.3);
        [hid swipeFrom:from to:to duration:duration];
        return Ok(@{ @"swiped": @[ @(from.x), @(from.y), @(to.x), @(to.y) ], @"duration": @(duration) });
    }

    if ([cmd isEqualToString:@"drag"]) {
        HID_REQUIRE(hid);
        CGPoint from = PointFrom(a, @"x1", @"y1");
        CGPoint to = PointFrom(a, @"x2", @"y2");
        double duration = Num(a, @"duration", 1.0);
        [hid dragFrom:from to:to duration:duration];
        return Ok(@{ @"dragged": @[ @(from.x), @(from.y), @(to.x), @(to.y) ] });
    }

    if ([cmd isEqualToString:@"scroll"]) {
        HID_REQUIRE(hid);
        CGSize screen = [self screenSize];
        CGPoint center = a[@"x"] ? PointFrom(a, @"x", @"y")
                                 : CGPointMake(screen.width / 2.0, screen.height / 2.0);
        double dy = Num(a, @"dy", -300);
        NSInteger steps = MAX(1, (NSInteger)fabs(dy) / 300 + 1);
        double chunk = dy / steps;
        for (NSInteger i = 0; i < steps; i++) {
            CGPoint to = CGPointMake(center.x, center.y + chunk);
            [hid swipeFrom:center to:to duration:0.28];
            usleep(80000);
        }
        return Ok(@{ @"scrolled": @(dy), @"steps": @(steps) });
    }

    if ([cmd isEqualToString:@"pressKey"]) {
        NSInteger usage = Int(a, @"usage", 0);
        if (usage <= 0) return Fail(@"missing \"usage\" (HID keyboard usage, e.g. 0x28 = Return)");
        HID_REQUIRE(hid);
        [hid pressKeyUsage:(uint32_t)usage];
        return Ok(@{ @"usage": @(usage) });
    }

    // ---------------------------------------------------------------- text
    if ([cmd isEqualToString:@"type"] || [cmd isEqualToString:@"sendKeys"]) {
        NSString *text = a[@"text"];
        if (![text isKindOfClass:[NSString class]]) return Fail(@"missing \"text\"");
        NSInteger idx = Int(a, @"index", -1);

        if (idx >= 0 && ![a[@"forceHID"] boolValue]) {
            NSString *target = [self frontmostBundleId];
            if (target.length && [hub hasAgent:target]) {
                NSDictionary *resp = [hub call:@"setValue" args:@{ @"index": @(idx), @"value": text }
                                     bundleId:target timeout:8.0];
                if ([resp[@"ok"] boolValue]) {
                    return Ok(@{ @"text": text, @"via": @"agent-setValue", @"index": @(idx) });
                }
                NSDictionary *frame = resp[@"frame"];
                if (frame) {
                    HID_REQUIRE(hid);
                    [hid tapAt:CenterOfFrame(frame)];
                    usleep(300000);
                }
            }
        }

        HID_REQUIRE(hid);
        [hid typeString:text];
        return Ok(@{ @"text": text, @"via": @"HID", @"index": @(idx) });
    }

    if ([cmd isEqualToString:@"setValue"]) {
        NSInteger idx = Int(a, @"index", -1);
        NSString *value = [a[@"value"] isKindOfClass:[NSString class]] ? a[@"value"] : @"";
        NSString *target = [self frontmostBundleId];

        if (target.length && [hub hasAgent:target]) {
            NSDictionary *resp = [hub call:@"setValue" args:@{ @"index": @(idx), @"value": value }
                                 bundleId:target timeout:8.0];
            if ([resp[@"ok"] boolValue]) return Ok(@{ @"index": @(idx), @"value": value, @"via": @"agent" });
            return Fail(resp[@"error"] ?: @"agent setValue failed");
        }

        NSString *error = nil;
        if (![ax setValue:value atIndex:idx error:&error]) return Fail(error);
        return Ok(@{ @"index": @(idx), @"value": value, @"via": @"ax" });
    }

    if ([cmd isEqualToString:@"press"]) {
        NSInteger idx = Int(a, @"index", -1);
        NSString *action = [a[@"action"] isKindOfClass:[NSString class]] ? a[@"action"] : @"AXPress";
        NSString *error = nil;
        if (![ax performAction:action atIndex:idx error:&error]) {
            // With no AX available an "AXPress" degenerates into an agent tap.
            return [self runCommand:@"tapElement" args:@{ @"index": @(idx) }];
        }
        return Ok(@{ @"index": @(idx), @"action": action });
    }

    if ([cmd isEqualToString:@"focus"]) {
        NSInteger idx = Int(a, @"index", -1);
        NSString *error = nil;
        if (![ax focusAtIndex:idx error:&error]) return Fail(error);
        return Ok(@{ @"index": @(idx) });
    }

    // ---------------------------------------------------------------- system
    if ([cmd isEqualToString:@"home"]) {
        [self performHomeGesture];
        return Ok(@{ @"via": @"swipe-up-from-bottom-edge" });
    }

    if ([cmd isEqualToString:@"appSwitcher"]) {
        [self performAppSwitcherGesture];
        return Ok(@{ @"via": @"swipe-up-and-hold" });
    }

    if ([cmd isEqualToString:@"lock"]) {
        HID_REQUIRE(hid);
        [hid pressKeyUsage:0x30 onPage:0x0C];
        return Ok(@{ @"via": @"hid-consumer-power" });
    }

    if ([cmd isEqualToString:@"openApp"]) {
        NSString *bundleId = a[@"bundleId"];
        if (![bundleId isKindOfClass:[NSString class]]) return Fail(@"missing \"bundleId\"");

        dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
        Class LS = NSClassFromString(@"LSApplicationWorkspace");
        if (!LS) return Fail(@"LSApplicationWorkspace unavailable");

        // -openApplicationWithBundleID: returns BOOL, so it must go through a typed
        // objc_msgSend; performSelector would hand back a garbage pointer.
        BOOL launched = NO;
        @try {
            id ws = [LS performSelector:@selector(defaultWorkspace)];
            BOOL (*openFn)(id, SEL, NSString *) = (BOOL (*)(id, SEL, NSString *))objc_msgSend;
            launched = openFn(ws, @selector(openApplicationWithBundleID:), bundleId);
        } @catch (NSException *ex) {
            return Fail(ex.reason ?: @"open failed");
        }
        if (!launched) return Fail([NSString stringWithFormat:@"cannot launch %@", bundleId]);
        usleep(600000);
        return Ok(@{ @"bundleId": bundleId });
    }

    if ([cmd isEqualToString:@"launchUrl"]) {
        NSString *urlString = a[@"url"];
        if (![urlString isKindOfClass:[NSString class]]) return Fail(@"missing \"url\"");

        NSURL *url = [NSURL URLWithString:urlString];
        if (!url) return Fail(@"malformed url");

        dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
        Class LS = NSClassFromString(@"LSApplicationWorkspace");
        if (!LS) return Fail(@"LSApplicationWorkspace unavailable");

        BOOL opened = NO;
        @try {
            id ws = [LS performSelector:@selector(defaultWorkspace)];
            BOOL (*openFn)(id, SEL, NSURL *, NSDictionary *) = (BOOL (*)(id, SEL, NSURL *, NSDictionary *))objc_msgSend;
            if ([ws respondsToSelector:@selector(openSensitiveURL:withOptions:)]) {
                opened = openFn(ws, @selector(openSensitiveURL:withOptions:), url, @{});
            }
            if (!opened && [ws respondsToSelector:@selector(openURL:withOptions:)]) {
                opened = openFn(ws, @selector(openURL:withOptions:), url, @{});
            }
        } @catch (NSException *ex) {
            return Fail(ex.reason ?: @"open url failed");
        }
        if (!opened) return Fail([NSString stringWithFormat:@"cannot open %@", urlString]);
        usleep(600000);
        return Ok(@{ @"url": urlString });
    }

    // ---------------------------------------------------------------- wait
    if ([cmd isEqualToString:@"wait"]) {
        NSString *text = [a[@"text"] isKindOfClass:[NSString class]] ? a[@"text"] : nil;
        NSString *role = [a[@"role"] isKindOfClass:[NSString class]] ? a[@"role"] : nil;
        NSString *bundleId = [a[@"bundleId"] isKindOfClass:[NSString class]] ? a[@"bundleId"] : nil;
        double timeout = Num(a, @"timeout", 10.0);
        if (!text.length && !role.length) return Fail(@"wait needs \"text\" or \"role\"");

        NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + timeout;
        while ([NSDate timeIntervalSinceReferenceDate] < deadline) {
            NSMutableDictionary *dump = [self treeForBundleId:bundleId depth:20];
            if ([dump[@"ok"] boolValue]) {
                for (NSDictionary *n in dump[@"result"][@"nodes"]) {
                    if (role.length && ![n[@"role"] isEqualToString:role]) continue;
                    if (text.length) {
                        NSString *hay = [NSString stringWithFormat:@"%@ %@ %@ %@",
                                         n[@"label"] ?: @"", n[@"value"] ?: @"",
                                         n[@"id"] ?: @"", n[@"title"] ?: @""];
                        if ([hay rangeOfString:text options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
                    }
                    return Ok(@{ @"found": @YES, @"nodes": @[ n ] });
                }
            }
            usleep(300000);
        }
        return Fail([NSString stringWithFormat:@"timeout waiting for %@%@",
                                               text ?: @"", role ? [NSString stringWithFormat:@" role=%@", role] : @""]);
    }

    return Fail([NSString stringWithFormat:@"unknown cmd \"%@\"", cmd]);
}

#pragma mark - system gestures

+ (CGSize)screenSize {
    NSDictionary *screen = [[AXBridge shared] screenMetrics];
    double w = [screen[@"width"] doubleValue];
    double h = [screen[@"height"] doubleValue];
    if (w < 1 || h < 1) return CGSizeMake(414, 896);
    return CGSizeMake(w, h);
}

/// Face ID devices: swiping up from the bottom edge *is* the home button.
+ (void)performHomeGesture {
    CGSize s = [self screenSize];
    CGPoint from = CGPointMake(s.width / 2.0, s.height - 6.0);
    CGPoint to = CGPointMake(s.width / 2.0, s.height * 0.42);
    [[HIDInjector shared] swipeFrom:from to:to duration:0.22];
    usleep(350000);
}

/// Swipe up and pause in the middle: SpringBoard turns that into the app switcher.
+ (void)performAppSwitcherGesture {
    CGSize s = [self screenSize];
    CGPoint from = CGPointMake(s.width / 2.0, s.height - 6.0);
    CGPoint to = CGPointMake(s.width / 2.0, s.height * 0.55);
    [[HIDInjector shared] swipeFrom:from to:to duration:0.35 holdAtEnd:0.55];
    usleep(350000);
}

@end
