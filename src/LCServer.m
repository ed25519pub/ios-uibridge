//
//  LCServer.m
//  uibridge -- newline delimited JSON over TCP, plus AX-worker forwarding
//
//  Two roles share one listener:
//    * the automation client (outside the device) sends {"cmd":...} and gets results
//    * the AX service app connects from inside the device, sends a
//      {"hello":{"role":"ax",...}} preamble, and then stays attached so we can
//      forward accessibility queries to it.
//
//  Why the app connects *in* rather than listening: iOS local-network privacy
//  silently drops packets to app listeners, while loopback connections the app
//  makes are unaffected. The root daemon is unsandboxed, so loopback works both ways
//  between the two of them.
//

#import "LCServer.h"
#import "LCCommands.h"

#import <arpa/inet.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <sys/select.h>
#import <sys/socket.h>
#import <unistd.h>

#pragma mark - AX worker registry

static NSMutableDictionary<NSString *, NSNumber *> *gWorkers = nil;
static NSMutableDictionary<NSString *, NSDictionary *> *gWorkerInfo = nil;
static NSLock *gWorkerLock = nil;
static NSInteger gWorkerSeq = 0;

static void UBInitWorkers(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gWorkers = [NSMutableDictionary dictionary];
        gWorkerInfo = [NSMutableDictionary dictionary];
        gWorkerLock = [[NSLock alloc] init];
    });
}

/// Read one newline-terminated line with a deadline. Returns nil on timeout/EOF.
static NSString *UBReadLine(int fd, NSTimeInterval timeout) {
    NSMutableData *buffer = [NSMutableData data];
    uint8_t chunk[4096];
    NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + timeout;

    while (1) {
        const uint8_t *bytes = (const uint8_t *)buffer.bytes;
        for (NSUInteger i = 0; i < buffer.length; i++) {
            if (bytes[i] == '\n') {
                return [[NSString alloc] initWithData:[buffer subdataWithRange:NSMakeRange(0, i)]
                                             encoding:NSUTF8StringEncoding];
            }
        }

        NSTimeInterval remaining = deadline - [NSDate timeIntervalSinceReferenceDate];
        if (remaining <= 0) return nil;

        fd_set set;
        FD_ZERO(&set);
        FD_SET(fd, &set);
        struct timeval tv;
        tv.tv_sec = (time_t)remaining;
        tv.tv_usec = (suseconds_t)((remaining - (double)tv.tv_sec) * 1e6);

        int ready = select(fd + 1, &set, NULL, NULL, &tv);
        if (ready <= 0) return nil;

        ssize_t n = read(fd, chunk, sizeof(chunk));
        if (n <= 0) return nil;
        [buffer appendBytes:chunk length:(NSUInteger)n];
    }
}

#pragma mark - LCServer

@interface LCServer ()
@property (nonatomic, assign) int listenFD;
@property (nonatomic, strong) dispatch_queue_t commandQueue;
@end

@implementation LCServer

+ (instancetype)shared {
    static LCServer *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[LCServer alloc] init];
        UBInitWorkers();
    });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _listenFD = -1;
        // All commands run serially: HID event ordering matters, and AX calls are
        // not reentrant across threads.
        _commandQueue = dispatch_queue_create("com.yg.uibridge.commands", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

#pragma mark AX worker API

+ (void)registerWorker:(int)fd bundleId:(NSString *)bundleId info:(NSDictionary *)info {
    UBInitWorkers();
    [gWorkerLock lock];
    NSNumber *previous = gWorkers[bundleId];
    if (previous && previous.intValue != fd) close(previous.intValue);
    gWorkers[bundleId] = @(fd);
    gWorkerInfo[bundleId] = info ?: @{};
    [gWorkerLock unlock];
    NSLog(@"[uibridge] ax worker attached: %@ fd=%d", bundleId, fd);
}

+ (NSArray<NSDictionary *> *)workers {
    UBInitWorkers();
    NSMutableArray *out = [NSMutableArray array];
    [gWorkerLock lock];
    for (NSString *bundleId in gWorkers) {
        NSMutableDictionary *entry = [gWorkerInfo[bundleId] mutableCopy] ?: [NSMutableDictionary dictionary];
        entry[@"bundleId"] = bundleId;
        [out addObject:entry];
    }
    [gWorkerLock unlock];
    return out;
}

+ (BOOL)hasWorker {
    UBInitWorkers();
    [gWorkerLock lock];
    BOOL any = (gWorkers.count > 0);
    [gWorkerLock unlock];
    return any;
}

+ (NSDictionary *)callWorker:(NSString *)cmd
                        args:(NSDictionary *)args
                     timeout:(NSTimeInterval)timeout {
    UBInitWorkers();

    [gWorkerLock lock];
    NSString *bundleId = gWorkers.allKeys.firstObject;
    NSNumber *fdNumber = bundleId ? gWorkers[bundleId] : nil;
    int fd = fdNumber.intValue;
    if (!fdNumber) {
        [gWorkerLock unlock];
        return @{ @"ok": @NO, @"error": @"no AX worker attached" };
    }

    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithDictionary:args ?: @{}];
    gWorkerSeq++;
    payload[@"id"] = @(gWorkerSeq);
    payload[@"cmd"] = cmd;

    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
    NSMutableData *out = [json mutableCopy];
    [out appendBytes:"\n" length:1];

    const uint8_t *bytes = (const uint8_t *)out.bytes;
    NSUInteger remaining = out.length;
    BOOL writeFailed = NO;
    while (remaining > 0) {
        ssize_t written = write(fd, bytes, remaining);
        if (written <= 0) {
            if (errno == EINTR) continue;
            writeFailed = YES;
            break;
        }
        bytes += written;
        remaining -= (NSUInteger)written;
    }

    if (writeFailed) {
        [gWorkers removeObjectForKey:bundleId];
        [gWorkerInfo removeObjectForKey:bundleId];
        [gWorkerLock unlock];
        return @{ @"ok": @NO, @"error": @"AX worker write failed (worker gone?)" };
    }

    NSString *line = UBReadLine(fd, timeout);
    if (!line) {
        [gWorkers removeObjectForKey:bundleId];
        [gWorkerInfo removeObjectForKey:bundleId];
        [gWorkerLock unlock];
        return @{ @"ok": @NO, @"error": @"AX worker timed out or disconnected" };
    }
    [gWorkerLock unlock];

    NSDictionary *reply = nil;
    @try {
        reply = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding]
                                               options:0
                                                 error:NULL];
    } @catch (NSException *e) { reply = nil; }

    if (![reply isKindOfClass:[NSDictionary class]]) {
        return @{ @"ok": @NO, @"error": @"malformed AX worker reply" };
    }
    return reply;
}

#pragma mark server

- (BOOL)startOnPort:(uint16_t)port {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;

    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(port);

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        NSLog(@"[uibridge] bind :%d failed: %s", port, strerror(errno));
        close(fd);
        return NO;
    }
    if (listen(fd, 16) < 0) {
        close(fd);
        return NO;
    }
    self.listenFD = fd;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self acceptLoop];
    });
    return YES;
}

- (void)acceptLoop {
    while (1) {
        int clientFD = accept(self.listenFD, NULL, NULL);
        if (clientFD < 0) {
            if (errno == EINTR) continue;
            NSLog(@"[uibridge] accept failed: %s", strerror(errno));
            break;
        }
        int on = 1;
        setsockopt(clientFD, IPPROTO_TCP, TCP_NODELAY, &on, sizeof(on));
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [self serveClient:clientFD];
        });
    }
}

- (void)serveClient:(int)fd {
    NSMutableData *buffer = [NSMutableData data];
    uint8_t chunk[8192];

    while (1) {
        ssize_t n = read(fd, chunk, sizeof(chunk));
        if (n <= 0) break;
        [buffer appendBytes:chunk length:(NSUInteger)n];

        BOOL drained = NO;
        while (!drained) {
            drained = YES;
            const uint8_t *bytes = (const uint8_t *)buffer.bytes;
            NSUInteger length = buffer.length;
            for (NSUInteger i = 0; i < length; i++) {
                if (bytes[i] != '\n') continue;

                NSData *line = [buffer subdataWithRange:NSMakeRange(0, i)];
                [buffer replaceBytesInRange:NSMakeRange(0, i + 1) withBytes:NULL length:0];

                if (line.length == 0) {
                    drained = NO;
                    break;
                }

                // ---- worker preamble: hand the socket to the forwarder and stop reading
                NSDictionary *probe = nil;
                @try {
                    probe = [NSJSONSerialization JSONObjectWithData:line options:0 error:NULL];
                } @catch (NSException *e) { probe = nil; }

                if ([probe isKindOfClass:[NSDictionary class]] && probe[@"hello"]) {
                    NSDictionary *hello = probe[@"hello"];
                    NSString *bid = hello[@"bundleId"];
                    if (![bid isKindOfClass:[NSString class]] || bid.length == 0) bid = @"ax-worker";
                    [[self class] registerWorker:fd bundleId:bid info:hello];
                    // Do NOT close: the forwarding API owns this fd from here on, and
                    // this thread must never read again or it would eat the replies.
                    return;
                }

                __block NSData *response = nil;
                dispatch_sync(self.commandQueue, ^{
                    response = [LCCommands handleLine:line];
                });

                NSMutableData *out = [response mutableCopy];
                [out appendBytes:"\n" length:1];

                const uint8_t *outBytes = (const uint8_t *)out.bytes;
                NSUInteger remaining = out.length;
                BOOL writeFailed = NO;
                while (remaining > 0) {
                    ssize_t written = write(fd, outBytes, remaining);
                    if (written <= 0) {
                        writeFailed = YES;
                        break;
                    }
                    outBytes += written;
                    remaining -= (NSUInteger)written;
                }
                if (writeFailed) {
                    close(fd);
                    return;
                }
                drained = NO;
                break;
            }
        }
    }

    close(fd);
}

@end
