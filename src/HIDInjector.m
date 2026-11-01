//
//  HIDInjector.m
//  uibridge -- synthetic touch / keyboard events through IOHIDEventSystem
//
//  All IOKit SPI is resolved with dlopen/dlsym: the public SDK ships no
//  IOHIDEvent headers, but the symbols exist on device inside IOKit.framework.
//
//  Coordinate space: everything below is expressed in *points* in the
//  springboard-wide coordinate system (0,0 = top-left of the display).
//

#import "HIDInjector.h"

#import <dlfcn.h>
#import <mach/mach_time.h>
#import <unistd.h>

typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef uint32_t IOHIDEventField;

#pragma mark - IOHIDEventTypes constants (from xnu IOHIDEventTypes.h)

// IOHIDEventFieldBase(kIOHIDEventTypeDigitizer) == (11 << 16)
#define kIOHIDEventFieldDigitizerBase 0x000B0000u

// In IOHIDEventTypes.h these are the digitizer field ordinals. If a future iOS
// reorders them, `resolveDisplayIntegratedField` re-probes at runtime.
enum {
    kDigitizerFieldX = kIOHIDEventFieldDigitizerBase + 0,   // 0x000B0000
    kDigitizerFieldY = kIOHIDEventFieldDigitizerBase + 1,   // 0x000B0001
    kDigitizerFieldZ = kIOHIDEventFieldDigitizerBase + 2,
    kDigitizerFieldType = kIOHIDEventFieldDigitizerBase + 5,
    kDigitizerFieldIndex = kIOHIDEventFieldDigitizerBase + 6,
    kDigitizerFieldIdentity = kIOHIDEventFieldDigitizerBase + 7,
    kDigitizerFieldRange = kIOHIDEventFieldDigitizerBase + 9,
    kDigitizerFieldTouch = kIOHIDEventFieldDigitizerBase + 10,
    kDigitizerFieldPressure = kIOHIDEventFieldDigitizerBase + 11,
    kDigitizerFieldIsDisplayIntegrated = kIOHIDEventFieldDigitizerBase + 24, // 0x000B0018
};

// IOHIDDigitizerTransducerType
enum {
    kTransducerStylus = 0,
    kTransducerPuck = 1,
    kTransducerFinger = 2,
    kTransducerHand = 3,
};

// kIOHIDDigitizerEventMask
enum {
    kDigitizerEventRange = 0x01,
    kDigitizerEventTouch = 0x02,
};

// HID keyboard usage page 0x07
enum {
    kUsagePageKeyboard = 0x07,
    kKeyReturn = 0x28,
    kKeyEscape = 0x29,
    kKeyBackspace = 0x2A,
    kKeyTab = 0x2B,
    kKeySpace = 0x2C,
    kKeyLeftShift = 0xE1,
};

#pragma mark - symbol table

static IOHIDEventSystemClientRef (*sClientCreate)(CFAllocatorRef);
static IOHIDEventSystemClientRef (*sClientCreateWithType)(CFAllocatorRef, int, void *);
static void (*sClientDispatchEvent)(IOHIDEventSystemClientRef, IOHIDEventRef);
static IOHIDEventRef (*sCreateDigitizerEvent)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                                             uint32_t, uint32_t, double, double, double, double,
                                             double, double, int, int, uint32_t);
static IOHIDEventRef (*sCreateDigitizerFingerEvent)(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
                                                    uint32_t, double, double, double, double,
                                                    double, int, int, uint32_t);
static IOHIDEventRef (*sCreateKeyboardEvent)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, int, uint32_t);
static void (*sAppendEvent)(IOHIDEventRef, IOHIDEventRef, uint32_t);
static void (*sSetIntegerValue)(IOHIDEventRef, IOHIDEventField, CFIndex);
static CFIndex (*sGetIntegerValue)(IOHIDEventRef, IOHIDEventField);

static void *sIOKit = NULL;
static NSString *sIOKitPath = nil;
static NSArray<NSString *> *sMissing = nil;
static IOHIDEventSystemClientRef sClient = NULL;
static IOHIDEventField sDisplayIntegratedField = kDigitizerFieldIsDisplayIntegrated;

static void IOKitLoadOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sIOKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_GLOBAL);
        if (sIOKit) sIOKitPath = @"/System/Library/Frameworks/IOKit.framework/IOKit";

        NSMutableArray *missing = [NSMutableArray array];
#define R(var, name)                                              \
    do {                                                          \
        *(void **)(&var) = dlsym(sIOKit, name);                   \
        if (!var) [missing addObject:@#name];                     \
    } while (0)

        if (sIOKit) {
            R(sClientCreate, "IOHIDEventSystemClientCreate");
            R(sClientCreateWithType, "IOHIDEventSystemClientCreateWithType");
            R(sClientDispatchEvent, "IOHIDEventSystemClientDispatchEvent");
            R(sCreateDigitizerEvent, "IOHIDEventCreateDigitizerEvent");
            R(sCreateDigitizerFingerEvent, "IOHIDEventCreateDigitizerFingerEvent");
            R(sCreateKeyboardEvent, "IOHIDEventCreateKeyboardEvent");
            R(sAppendEvent, "IOHIDEventAppendEvent");
            R(sSetIntegerValue, "IOHIDEventSetIntegerValue");
            R(sGetIntegerValue, "IOHIDEventGetIntegerValue");
        }
#undef R
        sMissing = missing.count ? [missing copy] : @[];

        if (sClientCreate) sClient = sClientCreate(kCFAllocatorDefault);
        if (!sClient && sClientCreateWithType) {
            // kIOHIDEventSystemClientTypeMonitor == 0, kIOHIDEventSystemClientTypeSimple == 1
            sClient = sClientCreateWithType(kCFAllocatorDefault, 0, NULL);
        }

        // Probe the IsDisplayIntegrated field: a bogus field number is a silent no-op,
        // so a set/get round-trip tells us whether the constant is still right.
        if (sClient && sCreateDigitizerEvent && sSetIntegerValue && sGetIntegerValue) {
            IOHIDEventRef probe = sCreateDigitizerEvent(kCFAllocatorDefault, mach_absolute_time(),
                                                        kTransducerHand, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
            if (probe) {
                NSArray<NSNumber *> *candidates = @[
                    @(kDigitizerFieldIsDisplayIntegrated),
                    @(0x00030008),     // seen in older third-party implementations
                    @(kDigitizerFieldRange),
                    @(kDigitizerFieldTouch),
                ];
                for (NSNumber *cand in candidates) {
                    IOHIDEventField f = cand.unsignedIntValue;
                    sSetIntegerValue(probe, f, 1);
                    if (sGetIntegerValue(probe, f) == 1) {
                        sDisplayIntegratedField = f;
                        break;
                    }
                }
                CFRelease(probe);
            }
        }
    });
}

#pragma mark - low level event construction

static void DispatchHandEvent(IOHIDEventRef hand) {
    if (!sClient || !sClientDispatchEvent || !hand) return;
    sClientDispatchEvent(sClient, hand);
}

static void SendFinger(double x, double y, double pressure, BOOL down, uint32_t fingerIndex) {
    if (!sCreateDigitizerEvent || !sCreateDigitizerFingerEvent || !sAppendEvent) return;

    uint64_t now = mach_absolute_time();
    uint32_t mask = down ? (kDigitizerEventRange | kDigitizerEventTouch) : 0;
    int range = down ? 1 : 0;
    int touch = down ? 1 : 0;

    IOHIDEventRef hand = sCreateDigitizerEvent(kCFAllocatorDefault, now,
                                               kTransducerHand, 0, 1,
                                               0,                       // eventMask
                                               0,                       // buttonMask
                                               x, y, 0,
                                               pressure, 0, 0,
                                               range, touch,
                                               0);
    if (!hand) return;

    if (sSetIntegerValue) sSetIntegerValue(hand, sDisplayIntegratedField, 1);

    IOHIDEventRef finger = sCreateDigitizerFingerEvent(kCFAllocatorDefault, now,
                                                       kTransducerFinger,
                                                       fingerIndex,
                                                       mask,
                                                       x, y, 0,
                                                       pressure,
                                                       0,           // twist
                                                       range, touch,
                                                       0);
    if (!finger) {
        CFRelease(hand);
        return;
    }

    sAppendEvent(hand, finger, 0);
    DispatchHandEvent(hand);

    CFRelease(finger);
    CFRelease(hand);
}

static void SendKeyOnPage(uint32_t usage, uint32_t page, BOOL down) {
    if (!sCreateKeyboardEvent) return;
    IOHIDEventRef ev = sCreateKeyboardEvent(kCFAllocatorDefault, mach_absolute_time(),
                                            page, usage, down ? 1 : 0, 0);
    if (!ev) return;
    DispatchHandEvent(ev);
    CFRelease(ev);
}

static void SendKey(uint32_t usage, BOOL down) {
    SendKeyOnPage(usage, kUsagePageKeyboard, down);
}

#pragma mark - ASCII -> HID usage table

typedef struct {
    char ch;
    uint8_t usage;
    uint8_t shift;   // 1 when the character needs Left Shift
} UBKeyEntry;

static const UBKeyEntry kKeyTable[] = {
    {'a', 0x04, 0}, {'b', 0x05, 0}, {'c', 0x06, 0}, {'d', 0x07, 0}, {'e', 0x08, 0},
    {'f', 0x09, 0}, {'g', 0x0A, 0}, {'h', 0x0B, 0}, {'i', 0x0C, 0}, {'j', 0x0D, 0},
    {'k', 0x0E, 0}, {'l', 0x0F, 0}, {'m', 0x10, 0}, {'n', 0x11, 0}, {'o', 0x12, 0},
    {'p', 0x13, 0}, {'q', 0x14, 0}, {'r', 0x15, 0}, {'s', 0x16, 0}, {'t', 0x17, 0},
    {'u', 0x18, 0}, {'v', 0x19, 0}, {'w', 0x1A, 0}, {'x', 0x1B, 0}, {'y', 0x1C, 0},
    {'z', 0x1D, 0},
    {'1', 0x1E, 0}, {'2', 0x1F, 0}, {'3', 0x20, 0}, {'4', 0x21, 0}, {'5', 0x22, 0},
    {'6', 0x23, 0}, {'7', 0x24, 0}, {'8', 0x25, 0}, {'9', 0x26, 0}, {'0', 0x27, 0},
    {' ', 0x2C, 0}, {'\n', 0x28, 0}, {'\t', 0x2B, 0},
    {'-', 0x2D, 0}, {'=', 0x2E, 0}, {'[', 0x2F, 0}, {']', 0x30, 0}, {'\\', 0x31, 0},
    {';', 0x33, 0}, {'\'', 0x34, 0}, {'`', 0x35, 0}, {',', 0x36, 0}, {'.', 0x37, 0},
    {'/', 0x38, 0},
    {'!', 0x1E, 1}, {'@', 0x1F, 1}, {'#', 0x20, 1}, {'$', 0x21, 1}, {'%', 0x22, 1},
    {'^', 0x23, 1}, {'&', 0x24, 1}, {'*', 0x25, 1}, {'(', 0x26, 1}, {')', 0x27, 1},
    {'_', 0x2D, 1}, {'+', 0x2E, 1}, {'{', 0x2F, 1}, {'}', 0x30, 1}, {'|', 0x31, 1},
    {':', 0x33, 1}, {'"', 0x34, 1}, {'~', 0x35, 1}, {'<', 0x36, 1}, {'>', 0x37, 1},
    {'?', 0x38, 1},
};

#pragma mark - HIDInjector

@implementation HIDInjector

+ (instancetype)shared {
    static HIDInjector *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[HIDInjector alloc] init]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) IOKitLoadOnce();
    return self;
}

- (BOOL)isReady {
    IOKitLoadOnce();
    return sClient != NULL && sClientDispatchEvent && sCreateDigitizerEvent && sCreateDigitizerFingerEvent;
}

- (NSDictionary *)diagnostics {
    IOKitLoadOnce();
    return @{
        @"iokit": sIOKitPath ?: @"",
        @"missingSymbols": sMissing ?: @[],
        @"client": @(sClient != NULL),
        @"displayIntegratedField": [NSString stringWithFormat:@"0x%08X", sDisplayIntegratedField],
    };
}

- (void)tapAt:(CGPoint)point {
    SendFinger(point.x, point.y, 1.0, YES, 1);
    usleep(45000);
    SendFinger(point.x, point.y, 0.0, NO, 1);
    usleep(15000);
}

- (void)longPressAt:(CGPoint)point duration:(NSTimeInterval)duration {
    if (duration <= 0) duration = 0.8;
    SendFinger(point.x, point.y, 1.0, YES, 1);
    usleep((useconds_t)(duration * 1000000.0));
    SendFinger(point.x, point.y, 0.0, NO, 1);
    usleep(15000);
}

- (void)swipeFrom:(CGPoint)from to:(CGPoint)to duration:(NSTimeInterval)duration {
    [self swipeFrom:from to:to duration:duration holdAtEnd:0];
}

- (void)swipeFrom:(CGPoint)from
               to:(CGPoint)to
         duration:(NSTimeInterval)duration
        holdAtEnd:(NSTimeInterval)hold {
    if (duration <= 0) duration = 0.3;
    // ~60 steps/second, clamped so that very short swipes still emit a move stream
    NSInteger steps = MAX(6, (NSInteger)(duration * 60.0));
    useconds_t stepDelay = (useconds_t)(duration * 1000000.0 / steps);

    SendFinger(from.x, from.y, 1.0, YES, 1);
    usleep(20000);   // let the touch-down register before we start moving

    for (NSInteger i = 1; i <= steps; i++) {
        double t = (double)i / (double)steps;
        double x = from.x + (to.x - from.x) * t;
        double y = from.y + (to.y - from.y) * t;
        SendFinger(x, y, 1.0, YES, 1);
        usleep(stepDelay);
    }

    if (hold > 0) {
        // Keep the finger parked at the destination; iOS decides between
        // "go home" and "app switcher" based on how long the touch stays there.
        SendFinger(to.x, to.y, 1.0, YES, 1);
        usleep((useconds_t)(hold * 1000000.0));
    }

    SendFinger(to.x, to.y, 0.0, NO, 1);
    usleep(15000);
}

- (void)dragFrom:(CGPoint)from to:(CGPoint)to duration:(NSTimeInterval)duration {
    // Slower, with a hold at the end so iOS treats it as a drag & drop instead of a flick.
    [self swipeFrom:from to:to duration:MAX(duration, 0.9)];
    usleep(200000);
}

- (void)typeString:(NSString *)string {
    for (NSUInteger i = 0; i < string.length; i++) {
        unichar c = [string characterAtIndex:i];
        char lower = (char)tolower((unsigned char)c);
        BOOL needShift = (c >= 'A' && c <= 'Z');

        const UBKeyEntry *entry = NULL;
        for (size_t k = 0; k < sizeof(kKeyTable) / sizeof(kKeyTable[0]); k++) {
            if (kKeyTable[k].ch == lower) {
                entry = &kKeyTable[k];
                break;
            }
        }
        if (!entry) {
            // unknown glyph (emoji / CJK): skip rather than emitting garbage
            continue;
        }

        BOOL shift = needShift || entry->shift;
        if (shift) SendKey(kKeyLeftShift, YES);
        SendKey(entry->usage, YES);
        usleep(8000);
        SendKey(entry->usage, NO);
        if (shift) SendKey(kKeyLeftShift, NO);
        usleep(12000);
    }
}

- (void)pressKeyUsage:(uint32_t)usage {
    SendKey(usage, YES);
    usleep(10000);
    SendKey(usage, NO);
}

- (void)pressKeyUsage:(uint32_t)usage onPage:(uint32_t)page {
    SendKeyOnPage(usage, page, YES);
    usleep(15000);
    SendKeyOnPage(usage, page, NO);
}

@end
