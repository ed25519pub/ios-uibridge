//
//  UBAgentHub.m
//  unix-socket broker between the daemon and the injected per-app agents.
//

#import "UBAgentHub.h"

#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <sys/select.h>
#import <unistd.h>
#import <errno.h>

#define UB_SOCKET_PATH "/var/jb/tmp/uibridge.sock"
#define UB_SOCKET_DIR "/var/jb/tmp"

@interface UBAgentHub ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *connections;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *metadata;
@property (nonatomic, assign) int listenFD;
@end

@implementation UBAgentHub

+ (instancetype)shared {
    static UBAgentHub *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[UBAgentHub alloc] init]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _connections = [NSMutableDictionary dictionary];
        _metadata = [NSMutableDictionary dictionary];
        _listenFD = -1;
    }
    return self;
}

#pragma mark server

- (BOOL)start {
    mkdir(UB_SOCKET_DIR, 0777);
    unlink(UB_SOCKET_PATH);

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return NO;

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strlcpy(addr.sun_path, UB_SOCKET_PATH, sizeof(addr.sun_path));

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        NSLog(@"[uibridge] agent socket bind failed: %s", strerror(errno));
        close(fd);
        return NO;
    }
    listen(fd, 32);
    chmod(UB_SOCKET_PATH, 0666);

    self.listenFD = fd;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self acceptLoop];
    });
    return YES;
}

- (void)acceptLoop {
    while (1) {
        int clientFD = accept(self.listenFD, NULL, NULL);
        if (clientFD < 0) {
            if (errno == EINTR) continue;
            break;
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [self handshake:clientFD];
        });
    }
}

- (NSString *)readLine:(int)fd timeout:(NSTimeInterval)timeout {
    NSMutableData *buf = [NSMutableData data];
    uint8_t chunk[4096];
    NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + timeout;

    while (1) {
        const uint8_t *bytes = buf.bytes;
        for (NSUInteger i = 0; i < buf.length; i++) {
            if (bytes[i] == '\n') {
                return [[NSString alloc] initWithData:[buf subdataWithRange:NSMakeRange(0, i)]
                                             encoding:NSUTF8StringEncoding];
            }
        }

        NSTimeInterval left = deadline - [NSDate timeIntervalSinceReferenceDate];
        if (left <= 0) return nil;

        fd_set set;
        FD_ZERO(&set);
        FD_SET(fd, &set);
        struct timeval tv;
        tv.tv_sec = (time_t)left;
        tv.tv_usec = (suseconds_t)((left - tv.tv_sec) * 1e6);

        int ready = select(fd + 1, &set, NULL, NULL, &tv);
        if (ready <= 0) return nil;

        ssize_t n = read(fd, chunk, sizeof(chunk));
        if (n <= 0) return nil;
        [buf appendBytes:chunk length:(NSUInteger)n];
    }
}

- (void)handshake:(int)fd {
    NSString *line = [self readLine:fd timeout:10.0];
    if (!line) {
        close(fd);
        return;
    }
    NSDictionary *hello = nil;
    @try {
        hello = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding]
                                                options:0
                                                  error:NULL];
    } @catch (NSException *e) { hello = nil; }

    NSDictionary *info = hello[@"hello"];
    NSString *bundleId = info[@"bundleId"];
    if (![bundleId isKindOfClass:[NSString class]] || bundleId.length == 0) {
        close(fd);
        return;
    }

    dispatch_sync(dispatch_get_main_queue(), ^{
        NSNumber *old = self.connections[bundleId];
        if (old && old.intValue >= 0 && old.intValue != fd) close(old.intValue);
        self.connections[bundleId] = @(fd);
        self.metadata[bundleId] = info;
    });
    NSLog(@"[uibridge] agent attached: %@ pid=%@", bundleId, info[@"pid"]);
    // The fd stays open; the agent never pushes, it only answers, so no reader thread.
}

#pragma mark queries

- (NSArray<NSDictionary *> *)agents {
    __block NSArray *out = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        NSMutableArray *arr = [NSMutableArray array];
        [self.connections enumerateKeysAndObjectsUsingBlock:^(NSString *bundleId, NSNumber *fd, BOOL *stop) {
            NSMutableDictionary *m = [self.metadata[bundleId] mutableCopy] ?: [NSMutableDictionary dictionary];
            m[@"bundleId"] = bundleId;
            m[@"fd"] = fd;
            [arr addObject:m];
        }];
        out = arr;
    });
    return out;
}

- (BOOL)hasAgent:(NSString *)bundleId {
    if (bundleId.length == 0) return NO;
    __block BOOL found = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
        found = (self.connections[bundleId] != nil);
    });
    return found;
}

- (void)dropAgent:(NSString *)bundleId {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.connections removeObjectForKey:bundleId];
        [self.metadata removeObjectForKey:bundleId];
    });
}

- (NSDictionary *)call:(NSString *)cmd
                  args:(NSDictionary *)args
              bundleId:(NSString *)bundleId
               timeout:(NSTimeInterval)timeout {
    if (bundleId.length == 0) return @{ @"ok": @NO, @"error": @"no bundleId" };

    __block NSNumber *fdNumber = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        fdNumber = self.connections[bundleId];
    });
    if (!fdNumber) {
        return @{ @"ok": @NO,
                  @"error": [NSString stringWithFormat:@"no agent for %@ (app not running, or tweak not injected)", bundleId] };
    }
    int fd = fdNumber.intValue;

    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithDictionary:args ?: @{}];
    payload[@"id"] = @(1);
    payload[@"cmd"] = cmd;

    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
    if (!json) return @{ @"ok": @NO, @"error": @"cannot encode request" };

    NSMutableData *out = [json mutableCopy];
    [out appendBytes:"\n" length:1];
    const uint8_t *bytes = out.bytes;
    NSUInteger remaining = out.length;
    while (remaining > 0) {
        ssize_t n = write(fd, bytes, remaining);
        if (n <= 0) {
            if (errno == EINTR) continue;
            [self dropAgent:bundleId];
            return @{ @"ok": @NO, @"error": @"agent socket write failed" };
        }
        bytes += n;
        remaining -= (NSUInteger)n;
    }

    NSString *line = [self readLine:fd timeout:timeout];
    if (!line) {
        [self dropAgent:bundleId];
        return @{ @"ok": @NO, @"error": @"agent timed out or disconnected" };
    }

    NSDictionary *resp = nil;
    @try {
        resp = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding]
                                               options:0
                                                 error:NULL];
    } @catch (NSException *e) { resp = nil; }
    if (![resp isKindOfClass:[NSDictionary class]]) {
        return @{ @"ok": @NO, @"error": @"malformed agent reply" };
    }
    return resp;
}

@end
