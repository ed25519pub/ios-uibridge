//
//  AXBridge.m
//  uibridge -- accessibility-tree access layer
//
//  Everything here goes through the private libAccessibility C API which is fully
//  present on iOS but not in the public SDK. We resolve it with dlopen/dlsym so that
//  the package builds against a stock iPhoneOS SDK without private .tbd files.
//

#import "AXBridge.h"

#import <CoreGraphics/CoreGraphics.h>

#import <dlfcn.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <unistd.h>
#import <sys/sysctl.h>

// libproc is not in the public iPhoneOS SDK; the symbol is still exported by libsystem.
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

#pragma mark - libAccessibility symbol table

static AXUIElementRef (*gCreateSystemWide)(void);
static AXUIElementRef (*gCreateApplication)(pid_t);
static AXError (*gCopyAttributeValue)(AXUIElementRef, CFStringRef, CFTypeRef *);
static AXError (*gSetAttributeValue)(AXUIElementRef, CFStringRef, CFTypeRef);
static AXError (*gPerformAction)(AXUIElementRef, CFStringRef);
static AXError (*gCopyAttributeNames)(AXUIElementRef, CFArrayRef *);
static AXError (*gCopyActionNames)(AXUIElementRef, CFArrayRef *);
static AXError (*gCopyElementAtPosition)(AXUIElementRef, float, float, AXUIElementRef *);
static AXError (*gSetMessagingTimeout)(AXUIElementRef, float);
static pid_t (*gGetPid)(AXUIElementRef);
static CFTypeID (*gAXUIElementGetTypeID)(void);
static Boolean (*gAXValueGetValue)(AXValueRef, int, void *);
static CFTypeID (*gAXValueGetTypeID)(void);

static void *gAXLibHandle = NULL;
static NSString *gAXLibPath = nil;
static NSArray<NSString *> *gMissingSymbols = nil;
static NSMutableDictionary<NSString *, NSString *> *gSymbolOrigin = nil;

/// Places the AX C API has lived across iOS versions. iOS 17 no longer exports the
/// AXUIElement* symbols from libAccessibility.dylib, so we probe every candidate and
/// take the first image that actually resolves the symbol.
static NSArray<NSString *> *AXCandidates(void) {
    static NSArray<NSString *> *candidates;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        candidates = @[
            @"/usr/lib/libAccessibility.dylib",
            @"/System/Library/PrivateFrameworks/Accessibility.framework/Accessibility",
            @"/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime",
            @"/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities",
            @"/System/Library/PrivateFrameworks/AccessibilityUIUtilities.framework/AccessibilityUIUtilities",
            @"/System/Library/PrivateFrameworks/AccessibilitySharedSupport.framework/AccessibilitySharedSupport",
            @"/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation",
            @"/System/Library/PrivateFrameworks/AccessibilityUI.framework/AccessibilityUI",
            @"/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore",
        ];
    });
    return candidates;
}

/// Resolve one symbol: global scope first (covers images the process already
/// loaded), then each candidate image.
static void *AXResolve(const char *name) {
    void *sym = dlsym(RTLD_DEFAULT, name);
    if (sym) {
        gSymbolOrigin[@(name)] = @"<loaded image>";
        return sym;
    }
    for (NSString *path in AXCandidates()) {
        void *h = dlopen(path.UTF8String, RTLD_LAZY | RTLD_GLOBAL);
        if (!h) continue;
        sym = dlsym(h, name);
        if (sym) {
            gSymbolOrigin[@(name)] = path;
            if (!gAXLibHandle) {
                gAXLibHandle = h;
                gAXLibPath = path;
            }
            return sym;
        }
    }
    return NULL;
}

/// Reads this process's own effective entitlements. A missing key here means the
/// signature was stripped or amfi refused to grant it.
static NSDictionary *SelfEntitlementProbe(void) {
    void *sec = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY);
    typedef struct __SecTask *SecTaskRef;
    SecTaskRef (*createFromSelf)(CFAllocatorRef) =
        sec ? (SecTaskRef (*)(CFAllocatorRef))dlsym(sec, "SecTaskCreateFromSelf") : NULL;
    CFTypeRef (*copyEnt)(SecTaskRef, CFStringRef) =
        sec ? (CFTypeRef (*)(SecTaskRef, CFStringRef))dlsym(sec, "SecTaskCopyValueForEntitlement") : NULL;
    if (!createFromSelf || !copyEnt) return @{ @"probe": @"unavailable" };

    SecTaskRef task = createFromSelf(kCFAllocatorDefault);
    if (!task) return @{ @"probe": @"no task" };

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSArray *keys = @[
        @"com.apple.private.accessibility",
        @"com.apple.accessibility.api",
        @"platform-application",
        @"com.apple.private.security.no-container",
        @"com.apple.private.hid.client.event-dispatch",
    ];
    for (NSString *key in keys) {
        CFTypeRef v = copyEnt(task, (__bridge CFStringRef)key);
        out[key] = v ? (__bridge_transfer id)v : @"<not granted>";
    }
    CFRelease(task);
    return out;
}

/// Checks whether our bootstrap namespace can even see the AX service. A launchd
/// daemon lives in the system domain; axserver lives in the user domain, and a
/// failed lookup is exactly what produces an AXError from every query.
static NSDictionary *BootstrapProbe(void) {
    // bootstrap.h is macOS-only in the SDK; the symbol lives in liblaunch on iOS.
    typedef kern_return_t (*BootstrapLookUpFn)(mach_port_t, const char *, mach_port_t *);
    static BootstrapLookUpFn lookUp = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *liblaunch = dlopen("/usr/lib/liblaunch.dylib", RTLD_LAZY);
        if (liblaunch) *(void **)(&lookUp) = dlsym(liblaunch, "bootstrap_look_up");
        if (!lookUp) *(void **)(&lookUp) = dlsym(RTLD_DEFAULT, "bootstrap_look_up");
    });

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    if (!lookUp) return @{ @"probe": @"bootstrap_look_up unresolved" };

    mach_port_t bp = MACH_PORT_NULL;
    task_get_bootstrap_port(mach_task_self(), &bp);

    NSArray *services = @[
        @"com.apple.iphone.axserver",
        @"com.apple.accessibility.axserver",
        @"com.apple.accessibility.axAuditDaemon",
        @"com.apple.springboard.services",
        @"com.apple.backboardd",
    ];
    for (NSString *name in services) {
        mach_port_t port = MACH_PORT_NULL;
        kern_return_t kr = lookUp(bp, name.UTF8String, &port);
        out[name] = [NSString stringWithFormat:@"kr=%d%s", kr, (kr == KERN_SUCCESS ? " (found)" : "")];
        if (kr == KERN_SUCCESS && port != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), port);
    }
    return out;
}

static NSArray<NSString *> *LoadedAXImages(void) {    NSMutableArray *out = [NSMutableArray array];
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        NSString *s = @(name);
        if ([s rangeOfString:@"Accessib"].location != NSNotFound ||
            [s rangeOfString:@"AXRuntime"].location != NSNotFound) {
            [out addObject:s];
        }
    }
    return out;
}

static void AXLoadOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gSymbolOrigin = [NSMutableDictionary dictionary];

        // Warm the candidate images into the process so RTLD_DEFAULT can see them.
        for (NSString *path in AXCandidates()) {
            dlopen(path.UTF8String, RTLD_LAZY | RTLD_GLOBAL);
        }

        NSMutableArray *missing = [NSMutableArray array];
#define RESOLVE(var, name)                                            \
    do {                                                              \
        *(void **)(&var) = AXResolve(name);                           \
        if (!var) [missing addObject:@#name];                         \
    } while (0)

        RESOLVE(gCreateSystemWide, "AXUIElementCreateSystemWide");

        // iOS 17 dropped this exact spelling from some images; try the variants that
        // shipped alongside it.
        gCreateApplication = (AXUIElementRef (*)(pid_t))AXResolve("AXUIElementCreateApplication");
        if (!gCreateApplication) {
            for (NSString *alias in @[ @"AXUIElementCreateApplicationWithPid",
                                       @"AXUIElementCreateApplicationForPid",
                                       @"AXUIElementCreateForPid",
                                       @"AXUIElementCreateWithPid" ]) {
                gCreateApplication = (AXUIElementRef (*)(pid_t))AXResolve(alias.UTF8String);
                if (gCreateApplication) {
                    gSymbolOrigin[@"AXUIElementCreateApplication"] = alias;
                    break;
                }
            }
        }
        if (!gCreateApplication) [missing addObject:@"AXUIElementCreateApplication"];

        RESOLVE(gCopyAttributeValue, "AXUIElementCopyAttributeValue");
        RESOLVE(gSetAttributeValue, "AXUIElementSetAttributeValue");
        RESOLVE(gPerformAction, "AXUIElementPerformAction");
        RESOLVE(gCopyAttributeNames, "AXUIElementCopyAttributeNames");
        RESOLVE(gCopyActionNames, "AXUIElementCopyActionNames");
        RESOLVE(gCopyElementAtPosition, "AXUIElementCopyElementAtPosition");
        RESOLVE(gSetMessagingTimeout, "AXUIElementSetMessagingTimeout");
        RESOLVE(gGetPid, "AXUIElementGetPid");
        RESOLVE(gAXUIElementGetTypeID, "AXUIElementGetTypeID");
        RESOLVE(gAXValueGetValue, "AXValueGetValue");
        RESOLVE(gAXValueGetTypeID, "AXValueGetTypeID");
#undef RESOLVE

        gMissingSymbols = missing.count ? [missing copy] : @[];
        if (!gAXLibPath) gAXLibPath = @"<unresolved>";
    });
}

// Private SpringBoardServices helper: cheapest way to map frontmost pid -> bundle id.
static void *gSBHandle = NULL;
static CFStringRef (*gSBCopyFrontmostBundleId)(void);

static void SBLoadOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gSBHandle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
                           RTLD_LAZY);
        if (gSBHandle) {
            *(void **)(&gSBCopyFrontmostBundleId) = dlsym(gSBHandle, "SBSCopyFrontmostApplicationDisplayIdentifier");
            if (!gSBCopyFrontmostBundleId) {
                *(void **)(&gSBCopyFrontmostBundleId) = dlsym(gSBHandle, "SBSCopyFrontmostApplicationBundleIdentifier");
            }
        }
    });
}

#pragma mark - small CF helpers

static inline NSString *AXStr(AXUIElementRef el, CFStringRef attr) {
    if (!gCopyAttributeValue || !el) return nil;
    CFTypeRef v = NULL;
    if (gCopyAttributeValue(el, attr, &v) != kAXErrorSuccess || !v) return nil;
    NSString *out = nil;
    CFTypeID tid = CFGetTypeID(v);
    if (tid == CFStringGetTypeID()) {
        out = (__bridge_transfer NSString *)v;
    } else if (tid == CFNumberGetTypeID()) {
        out = [(__bridge NSNumber *)v stringValue];
        CFRelease(v);
    } else if (tid == CFBooleanGetTypeID()) {
        out = CFBooleanGetValue((CFBooleanRef)v) ? @"1" : @"0";
        CFRelease(v);
    } else {
        CFRelease(v);
    }
    return out;
}

static inline CFTypeRef AXCopy(AXUIElementRef el, CFStringRef attr) {
    if (!gCopyAttributeValue || !el) return NULL;
    CFTypeRef v = NULL;
    if (gCopyAttributeValue(el, attr, &v) != kAXErrorSuccess) return NULL;
    return v;
}

static inline BOOL AXBool(AXUIElementRef el, CFStringRef attr) {
    CFTypeRef v = AXCopy(el, attr);
    if (!v) return NO;
    BOOL b = NO;
    if (CFGetTypeID(v) == CFBooleanGetTypeID()) b = CFBooleanGetValue((CFBooleanRef)v);
    CFRelease(v);
    return b ? YES : NO;
}

static CGRect AXRect(AXUIElementRef el) {
    CGRect rect = CGRectNull;
    if (!el) return rect;

    CFTypeRef v = AXCopy(el, CFSTR("AXFrame"));
    if (v) {
        if (gAXValueGetValue && CFGetTypeID(v) == gAXValueGetTypeID()) {
            gAXValueGetValue((AXValueRef)v, kAXValueTypeCGRect, &rect);
        }
        CFRelease(v);
    }
    if (!CGRectIsNull(rect)) return rect;

    CGPoint origin = CGPointZero;
    CGSize size = CGSizeZero;
    BOOL hasOrigin = NO, hasSize = NO;

    v = AXCopy(el, CFSTR("AXPosition"));
    if (v) {
        if (gAXValueGetValue && CFGetTypeID(v) == gAXValueGetTypeID()) {
            hasOrigin = gAXValueGetValue((AXValueRef)v, kAXValueTypeCGPoint, &origin) ? YES : NO;
        }
        CFRelease(v);
    }
    v = AXCopy(el, CFSTR("AXSize"));
    if (v) {
        if (gAXValueGetValue && CFGetTypeID(v) == gAXValueGetTypeID()) {
            hasSize = gAXValueGetValue((AXValueRef)v, kAXValueTypeCGSize, &size) ? YES : NO;
        }
        CFRelease(v);
    }
    if (hasOrigin || hasSize) return CGRectMake(origin.x, origin.y, size.width, size.height);
    return CGRectNull;
}

#pragma mark - AXBridge

@interface AXBridge () {
    NSMutableArray<NSValue *> *_elements;    // retained AXUIElementRef per dump index
    NSMutableArray<NSDictionary *> *_nodes; // last dump, flat
    NSInteger _nodeCount;
    NSUInteger _dumpGeneration;
}
@end

@implementation AXBridge

+ (NSArray<NSString *> *)scanSymbolsContaining:(NSString *)needle {
    if (needle.length == 0) return @[];
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *dedup = [NSMutableSet set];

    uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount; i++) {
        const struct mach_header_64 *header =
            (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (!header || header->magic != MH_MAGIC_64) continue;

        uintptr_t linkeditBase = 0;
        const struct load_command *cursor = (const struct load_command *)(header + 1);
        for (uint32_t c = 0; c < header->ncmds; c++) {
            if (cursor->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *seg = (const struct segment_command_64 *)cursor;
                if (strcmp(seg->segname, "__LINKEDIT") == 0) {
                    linkeditBase = (uintptr_t)seg->vmaddr;
                }
            }
            cursor = (const struct load_command *)((const uint8_t *)cursor + cursor->cmdsize);
        }
        if (!linkeditBase) continue;

        // In a dyld shared cache the __LINKEDIT vmaddr is image-relative, so rebase it
        // onto the actual loaded header address.
        uintptr_t textVmaddr = 0;
        cursor = (const struct load_command *)(header + 1);
        for (uint32_t c = 0; c < header->ncmds; c++) {
            if (cursor->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *seg = (const struct segment_command_64 *)cursor;
                if (strcmp(seg->segname, "__TEXT") == 0) textVmaddr = (uintptr_t)seg->vmaddr;
            }
            cursor = (const struct load_command *)((const uint8_t *)cursor + cursor->cmdsize);
        }
        intptr_t slide = (intptr_t)((uintptr_t)header - textVmaddr);
        uintptr_t linkedit = linkeditBase + slide;

        cursor = (const struct load_command *)(header + 1);
        for (uint32_t c = 0; c < header->ncmds; c++) {
            if (cursor->cmd == LC_SYMTAB) {
                const struct symtab_command *st = (const struct symtab_command *)cursor;
                const struct nlist_64 *symbols = (const struct nlist_64 *)(linkedit + st->symoff);
                const char *strings = (const char *)(linkedit + st->stroff);
                for (uint32_t s = 0; s < st->nsyms; s++) {
                    uint32_t strx = symbols[s].n_un.n_strx;
                    if (strx == 0) continue;
                    const char *name = strings + strx;
                    if (!strstr(name, needle.UTF8String)) continue;
                    NSString *sym = @(name);
                    if ([dedup containsObject:sym]) continue;
                    [dedup addObject:sym];
                    [out addObject:sym];
                }
            }
            cursor = (const struct load_command *)((const uint8_t *)cursor + cursor->cmdsize);
        }
    }

    [out sortUsingSelector:@selector(compare:)];
    return out;
}

+ (instancetype)shared {
    static AXBridge *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[AXBridge alloc] init]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _elements = [NSMutableArray array];
        _nodes = [NSMutableArray array];
        AXLoadOnce();
        SBLoadOnce();
    }
    return self;
}

- (BOOL)isReady {
    AXLoadOnce();
    return gCreateSystemWide && gCreateApplication && gCopyAttributeValue && gPerformAction &&
           gAXUIElementGetTypeID && gAXValueGetValue;
}

- (NSDictionary *)diagnostics {
    AXLoadOnce();
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"library"] = gAXLibPath ?: @"";
    d[@"missingSymbols"] = gMissingSymbols ?: @[];
    d[@"symbolOrigin"] = gSymbolOrigin ?: @{};
    d[@"loadedAXImages"] = LoadedAXImages();
    d[@"springboardServices"] = @(gSBHandle != NULL);
    d[@"frontmostBundleIdSymbol"] = @(gSBCopyFrontmostBundleId != NULL);
    d[@"elementCount"] = @(_elements.count);
    d[@"dumpGeneration"] = @(_dumpGeneration);
    d[@"selfEntitlements"] = SelfEntitlementProbe();
    d[@"bootstrapLookup"] = BootstrapProbe();

    // Probe whether the entitlement actually took effect.
    if (gCreateSystemWide) {
        AXUIElementRef sys = gCreateSystemWide();
        if (sys) {
            CFTypeRef v = NULL;
            AXError e = gCopyAttributeValue(sys, CFSTR("AXFocusedApplication"), &v);
            d[@"probeFocusedApplication"] = @(e);
            if (v) CFRelease(v);
            CFRelease(sys);
        }
    }
    return d;
}

#pragma mark frontmost

- (pid_t)frontmostPid {
    if (!gCreateSystemWide) return 0;
    AXUIElementRef sys = gCreateSystemWide();
    if (!sys) return 0;
    pid_t pid = 0;
    CFTypeRef v = NULL;
    if (gCopyAttributeValue(sys, CFSTR("AXFocusedApplication"), &v) == kAXErrorSuccess && v) {
        if (CFGetTypeID(v) == gAXUIElementGetTypeID()) pid = gGetPid((AXUIElementRef)v);
        CFRelease(v);
    }
    CFRelease(sys);
    return pid;
}

- (AXUIElementRef)frontmostAppElement CF_RETURNS_RETAINED {
    if (!gCreateSystemWide) return NULL;
    AXUIElementRef sys = gCreateSystemWide();
    if (!sys) return NULL;
    AXUIElementRef app = NULL;
    CFTypeRef v = NULL;
    if (gCopyAttributeValue(sys, CFSTR("AXFocusedApplication"), &v) == kAXErrorSuccess && v) {
        if (CFGetTypeID(v) == gAXUIElementGetTypeID()) app = (AXUIElementRef)v;
        else CFRelease(v);
    }
    CFRelease(sys);
    return app;
}

- (NSString *)bundleIdForPid:(pid_t)pid {
    if (pid <= 0) return nil;

    if (gSBCopyFrontmostBundleId) {
        CFStringRef s = NULL;
        @try { s = gSBCopyFrontmostBundleId(); } @catch (NSException *e) { s = NULL; }
        if (s) return (__bridge_transfer NSString *)s;
    }

    dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
    Class LS = NSClassFromString(@"LSApplicationWorkspace");
    if (LS) {
        @try {
            id ws = [LS performSelector:@selector(defaultWorkspace)];
            NSArray *apps = [ws performSelector:@selector(runningApplications)];
            for (id proxy in apps) {
                NSNumber *p = [proxy valueForKey:@"processIdentifier"];
                if (p && p.intValue == pid) return [proxy valueForKey:@"bundleIdentifier"];
            }
        } @catch (NSException *e) { /* ignore */ }
    }

    // last resort: executable path of the pid
    char path[4096] = {0};
    if (proc_pidpath(pid, path, sizeof(path)) > 0) return @(path);
    return nil;
}

- (NSDictionary *)frontmostApp {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];

    // SpringBoardServices works from the system bootstrap domain (verified on iOS 17),
    // while the AX route below only works up to iOS 16.
    NSString *bid = nil;
    if (gSBCopyFrontmostBundleId) {
        CFStringRef s = NULL;
        @try { s = gSBCopyFrontmostBundleId(); } @catch (NSException *e) { s = NULL; }
        if (s) bid = (__bridge_transfer NSString *)s;
    }

    pid_t pid = [self frontmostPid];
    if (!bid.length && pid > 0) bid = [self bundleIdForPid:pid];

    if (bid.length) d[@"bundleId"] = bid;
    if (pid > 0) d[@"pid"] = @(pid);
    return d;
}

- (NSDictionary *)screenMetrics {
    AXUIElementRef app = [self frontmostAppElement];
    if (app) {
        CGRect r = AXRect(app);
        CFRelease(app);
        if (!CGRectIsNull(r) && r.size.width > 1 && r.size.height > 1) {
            return @{
                @"width": @(r.size.width),
                @"height": @(r.size.height),
                @"orientation": r.size.width > r.size.height ? @"landscape" : @"portrait",
            };
        }
    }
    // iPhone 11 fallback (414x896 pt)
    return @{ @"width": @414, @"height": @896, @"orientation": @"portrait", @"fallback": @YES };
}

- (NSDictionary *)deviceInfo {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"daemonPid"] = @(getpid());
    d[@"ready"] = @([self isReady]);

    char buf[256] = {0};
    size_t len = sizeof(buf);
    if (sysctlbyname("hw.machine", buf, &len, NULL, 0) == 0) d[@"model"] = @(buf);
    len = sizeof(buf);
    if (sysctlbyname("kern.osversion", buf, &len, NULL, 0) == 0) d[@"iosVersion"] = @(buf);
    len = sizeof(buf);
    if (sysctlbyname("hw.model", buf, &len, NULL, 0) == 0) d[@"hwModel"] = @(buf);

    d[@"screen"] = [self screenMetrics];
    NSDictionary *front = [self frontmostApp];
    if (front.count) d[@"frontmost"] = front;
    d[@"dumpGeneration"] = @(_dumpGeneration);
    return d;
}

#pragma mark tree

- (NSArray *)childrenOf:(AXUIElementRef)el {
    CFTypeRef v = AXCopy(el, CFSTR("AXChildren"));
    if (!v) return @[];
    if (CFGetTypeID(v) != CFArrayGetTypeID()) {
        CFRelease(v);
        return @[];
    }
    NSArray *raw = (__bridge_transfer NSArray *)v;
    NSMutableArray *out = [NSMutableArray array];
    for (id item in raw) {
        if (CFGetTypeID((__bridge CFTypeRef)item) == gAXUIElementGetTypeID()) [out addObject:item];
    }
    return out;
}

- (NSArray<NSString *> *)actionsOf:(AXUIElementRef)el {
    if (!gCopyActionNames) return @[];
    CFArrayRef arr = NULL;
    if (gCopyActionNames(el, &arr) != kAXErrorSuccess || !arr) return @[];
    NSArray *raw = (__bridge_transfer NSArray *)arr;
    NSMutableArray *out = [NSMutableArray array];
    for (id a in raw) {
        if ([a isKindOfClass:[NSString class]]) [out addObject:a];
    }
    return out;
}

- (void)resetCache {
    for (NSValue *v in _elements) {
        AXUIElementRef el = (AXUIElementRef)v.pointerValue;
        if (el) CFRelease(el);
    }
    [_elements removeAllObjects];
    [_nodes removeAllObjects];
    _nodeCount = 0;
    _dumpGeneration++;
}

- (NSInteger)reserveIndex:(AXUIElementRef)el {
    NSInteger idx = _nodeCount++;
    CFRetain(el);
    [_elements addObject:[NSValue valueWithPointer:(void *)el]];
    return idx;
}

- (NSDictionary *)attributesFor:(AXUIElementRef)el index:(NSInteger)idx {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"i"] = @(idx);

    pid_t pid = gGetPid ? gGetPid(el) : 0;
    if (pid > 0) d[@"pid"] = @(pid);

    NSString *role = AXStr(el, CFSTR("AXRole"));
    if (role) d[@"role"] = role;
    NSString *subrole = AXStr(el, CFSTR("AXSubrole"));
    if (subrole.length) d[@"subrole"] = subrole;
    NSString *label = AXStr(el, CFSTR("AXLabel"));
    if (label.length) d[@"label"] = label;
    NSString *title = AXStr(el, CFSTR("AXTitle"));
    if (title.length) d[@"title"] = title;
    NSString *value = AXStr(el, CFSTR("AXValue"));
    if (value.length) d[@"value"] = value;
    NSString *ident = AXStr(el, CFSTR("AXIdentifier"));
    if (ident.length) d[@"id"] = ident;
    NSString *placeholder = AXStr(el, CFSTR("AXPlaceholderValue"));
    if (placeholder.length) d[@"placeholder"] = placeholder;
    NSString *help = AXStr(el, CFSTR("AXHelp"));
    if (help.length) d[@"help"] = help;

    d[@"enabled"] = @(AXBool(el, CFSTR("AXEnabled")));
    if (AXBool(el, CFSTR("AXSelected"))) d[@"selected"] = @YES;
    if (AXBool(el, CFSTR("AXFocused"))) d[@"focused"] = @YES;

    CGRect r = AXRect(el);
    if (!CGRectIsNull(r)) {
        d[@"frame"] = @{
            @"x": @(round(r.origin.x)),
            @"y": @(round(r.origin.y)),
            @"w": @(round(r.size.width)),
            @"h": @(round(r.size.height)),
        };
    }

    NSArray *actions = [self actionsOf:el];
    if (actions.count) d[@"actions"] = actions;

    return d;
}

- (NSInteger)serializeElement:(AXUIElementRef)el
                        depth:(NSInteger)depth
                     maxDepth:(NSInteger)maxDepth
                     maxNodes:(NSInteger)maxNodes
                       output:(NSMutableArray *)output
                         seen:(NSMutableSet *)seen {
    if (_nodeCount >= maxNodes) return -1;
    NSString *key = [NSString stringWithFormat:@"%p", (void *)el];
    if ([seen containsObject:key]) return -1;
    [seen addObject:key];

    NSInteger idx = [self reserveIndex:el];
    NSDictionary *node = [self attributesFor:el index:idx];
    [output addObject:node];

    if (depth >= maxDepth) return idx;

    NSArray *kids = [self childrenOf:el];
    if (!kids.count) return idx;

    NSMutableArray *childIndexes = [NSMutableArray array];
    for (id child in kids) {
        if (_nodeCount >= maxNodes) break;
        NSInteger ci = [self serializeElement:(AXUIElementRef)(__bridge CFTypeRef)child
                                        depth:depth + 1
                                     maxDepth:maxDepth
                                     maxNodes:maxNodes
                                       output:output
                                         seen:seen];
        if (ci >= 0) [childIndexes addObject:@(ci)];
    }
    if (childIndexes.count) {
        NSMutableDictionary *mutableNode = (NSMutableDictionary *)node;
        mutableNode[@"children"] = childIndexes;
    }
    return idx;
}

/// Recursively answers "does this subtree contain something that looks like a system alert?"
static BOOL SubtreeHasAlert(AXUIElementRef el, int depth) {
    if (!el || depth > 6) return NO;
    NSString *role = AXStr(el, CFSTR("AXRole"));
    NSString *subrole = AXStr(el, CFSTR("AXSubrole"));
    if ([role isEqualToString:@"AXAlert"] || [role isEqualToString:@"AXSheet"] ||
        [role isEqualToString:@"AXDialog"] || [subrole isEqualToString:@"AXSystemDialog"] ||
        [subrole isEqualToString:@"AXDialog"]) {
        return YES;
    }
    CFTypeRef v = AXCopy(el, CFSTR("AXChildren"));
    if (!v) return NO;
    if (CFGetTypeID(v) != CFArrayGetTypeID()) {
        CFRelease(v);
        return NO;
    }
    NSArray *kids = (__bridge_transfer NSArray *)v;
    for (id k in kids) {
        if (CFGetTypeID((__bridge CFTypeRef)k) == gAXUIElementGetTypeID()) {
            if (SubtreeHasAlert((AXUIElementRef)(__bridge CFTypeRef)k, depth + 1)) return YES;
        }
    }
    return NO;
}

- (void)appendSpringBoardAlertsTo:(NSMutableArray *)output
                            depth:(NSInteger)depth
                         maxNodes:(NSInteger)maxNodes
                             seen:(NSMutableSet *)seen {
    // SpringBoard owns system alerts (permission prompts, low battery, call banners...).
    // Those live in its own AX tree, not in the foreground app's.
    pid_t sbPid = 0;
    dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
    Class LS = NSClassFromString(@"LSApplicationWorkspace");
    if (LS) {
        @try {
            id ws = [LS performSelector:@selector(defaultWorkspace)];
            NSArray *apps = [ws performSelector:@selector(runningApplications)];
            for (id proxy in apps) {
                NSString *bid = [proxy valueForKey:@"bundleIdentifier"];
                if ([bid isEqualToString:@"com.apple.springboard"]) {
                    sbPid = [[proxy valueForKey:@"processIdentifier"] intValue];
                    break;
                }
            }
        } @catch (NSException *e) { }
    }
    if (sbPid <= 0) return;

    AXUIElementRef sb = gCreateApplication(sbPid);
    if (!sb) return;
    if (gSetMessagingTimeout) gSetMessagingTimeout(sb, 2.0f);

    CFTypeRef wins = AXCopy(sb, CFSTR("AXWindows"));
    if (wins && CFGetTypeID(wins) == CFArrayGetTypeID()) {
        NSArray *windows = (__bridge_transfer NSArray *)wins;
        for (id w in windows) {
            if (CFGetTypeID((__bridge CFTypeRef)w) != gAXUIElementGetTypeID()) continue;
            if (!SubtreeHasAlert((AXUIElementRef)(__bridge CFTypeRef)w, 0)) continue;
            [self serializeElement:(AXUIElementRef)(__bridge CFTypeRef)w
                             depth:depth
                          maxDepth:depth + 6
                          maxNodes:maxNodes
                            output:output
                              seen:seen];
        }
    } else if (wins) {
        CFRelease(wins);
    }
    CFRelease(sb);
}

- (NSDictionary *)dumpWithDepth:(NSInteger)depth
                       maxNodes:(NSInteger)maxNodes
            includeSystemAlerts:(BOOL)includeAlerts
                       bundleId:(NSString *)bundleId {
    if (![self isReady]) {
        return @{ @"error": @"libAccessibility unavailable", @"diagnostics": [self diagnostics] };
    }

    [self resetCache];

    if (depth <= 0) depth = 14;
    if (maxNodes <= 0) maxNodes = 2000;

    NSMutableArray *output = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];

    AXUIElementRef appEl = NULL;
    if (bundleId.length) {
        // Resolve a non-frontmost app by bundle id.
        dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
        Class LS = NSClassFromString(@"LSApplicationWorkspace");
        if (LS) {
            @try {
                id ws = [LS performSelector:@selector(defaultWorkspace)];
                NSArray *apps = [ws performSelector:@selector(runningApplications)];
                for (id proxy in apps) {
                    NSString *bid = [proxy valueForKey:@"bundleIdentifier"];
                    if ([bid isEqualToString:bundleId]) {
                        pid_t p = [[proxy valueForKey:@"processIdentifier"] intValue];
                        if (p > 0) appEl = gCreateApplication(p);
                        break;
                    }
                }
            } @catch (NSException *e) { }
        }
        if (!appEl) return @{ @"error": [NSString stringWithFormat:@"app not running: %@", bundleId] };
    } else {
        appEl = [self frontmostAppElement];
    }

    if (!appEl) return @{ @"error": @"no focused application" };
    if (gSetMessagingTimeout) gSetMessagingTimeout(appEl, 3.0f);

    NSInteger rootIndex = [self serializeElement:appEl
                                          depth:0
                                       maxDepth:depth
                                       maxNodes:maxNodes
                                         output:output
                                           seen:seen];

    pid_t appPid = gGetPid ? gGetPid(appEl) : 0;
    CFRelease(appEl);

    NSInteger alertBase = (NSInteger)output.count;
    if (includeAlerts) {
        [self appendSpringBoardAlertsTo:output depth:0 maxNodes:maxNodes seen:seen];
    }

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"screen"] = [self screenMetrics];
    result[@"nodes"] = output;
    result[@"root"] = @(rootIndex);
    result[@"nodeCount"] = @(output.count);
    result[@"generation"] = @(_dumpGeneration);
    // Keep a reference so `find` / `nodeAtIndex:` can answer without a re-dump.
    _nodes = output;
    if (alertBase < (NSInteger)output.count) {
        result[@"systemAlertFrom"] = @(alertBase);
    }
    NSMutableDictionary *app = [NSMutableDictionary dictionary];
    if (appPid > 0) {
        app[@"pid"] = @(appPid);
        NSString *bid = bundleId.length ? bundleId : [self bundleIdForPid:appPid];
        if (bid.length) app[@"bundleId"] = bid;
    }
    result[@"app"] = app;
    return result;
}

#pragma mark element access

- (AXUIElementRef)elementAtIndex:(NSInteger)idx {
    if (idx < 0 || idx >= (NSInteger)_elements.count) return NULL;
    return (AXUIElementRef)_elements[idx].pointerValue;
}

- (NSInteger)elementCount {
    return (NSInteger)_elements.count;
}

- (NSUInteger)dumpGeneration {
    return _dumpGeneration;
}

- (NSArray<NSDictionary *> *)queryNodesWithText:(NSString *)text
                                           role:(NSString *)role
                                          limit:(NSInteger)limit {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *n in _nodes) {
        if (role.length && ![n[@"role"] isEqualToString:role]) continue;
        if (text.length) {
            BOOL hit = NO;
            for (NSString *k in @[ @"label", @"title", @"value", @"id", @"placeholder", @"help" ]) {
                NSString *v = n[k];
                if ([v isKindOfClass:[NSString class]] && [v rangeOfString:text options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    hit = YES;
                    break;
                }
            }
            if (!hit) continue;
        }
        [out addObject:n];
        if (limit > 0 && (NSInteger)out.count >= limit) break;
    }
    return out;
}

- (NSDictionary *)nodeAtIndex:(NSInteger)idx {
    if (idx < 0 || idx >= (NSInteger)_nodes.count) return nil;
    NSDictionary *n = _nodes[idx];
    return [n[@"i"] integerValue] == idx ? n : nil;
}

#pragma mark actions

- (BOOL)performAction:(NSString *)action atIndex:(NSInteger)idx error:(NSString **)error {
    AXUIElementRef el = [self elementAtIndex:idx];
    if (!el) {
        if (error) *error = @"stale or invalid index, call dump first";
        return NO;
    }
    AXError e = gPerformAction(el, (__bridge CFStringRef)action);
    if (e != kAXErrorSuccess) {
        if (error) *error = [NSString stringWithFormat:@"AXPerformAction(%@) -> %d", action, e];
        return NO;
    }
    return YES;
}

- (BOOL)setValue:(NSString *)value atIndex:(NSInteger)idx error:(NSString **)error {
    AXUIElementRef el = [self elementAtIndex:idx];
    if (!el) {
        if (error) *error = @"stale or invalid index, call dump first";
        return NO;
    }
    AXError e = gSetAttributeValue(el, CFSTR("AXValue"), (__bridge CFStringRef)value);
    if (e != kAXErrorSuccess) {
        if (error) *error = [NSString stringWithFormat:@"AXSetValue -> %d", e];
        return NO;
    }
    return YES;
}

- (BOOL)focusAtIndex:(NSInteger)idx error:(NSString **)error {
    AXUIElementRef el = [self elementAtIndex:idx];
    if (!el) {
        if (error) *error = @"stale or invalid index, call dump first";
        return NO;
    }
    AXError e = gSetAttributeValue(el, CFSTR("AXFocused"), kCFBooleanTrue);
    if (e != kAXErrorSuccess) {
        if (error) *error = [NSString stringWithFormat:@"AXSetFocused -> %d", e];
        return NO;
    }
    return YES;
}

- (NSInteger)indexForPoint:(CGPoint)point {
    if (!gCopyElementAtPosition) return -1;
    AXUIElementRef app = [self frontmostAppElement];
    if (!app) return -1;
    AXUIElementRef hit = NULL;
    AXError e = gCopyElementAtPosition(app, (float)point.x, (float)point.y, &hit);
    CFRelease(app);
    if (e != kAXErrorSuccess || !hit) return -1;

    // Map the hit element back to an index from the last dump if we already hold it.
    NSInteger found = -1;
    for (NSUInteger i = 0; i < _elements.count; i++) {
        if (CFEqual((AXUIElementRef)_elements[i].pointerValue, hit)) {
            found = (NSInteger)i;
            break;
        }
    }
    CFRelease(hit);
    return found;
}

@end
