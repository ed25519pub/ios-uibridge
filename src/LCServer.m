//
//  LCServer.m
//  uibridge -- newline delimited JSON over TCP
//
//  Why raw TCP instead of an HTTP/WebSocket stack: the payload is tiny, the
//  client is a local automation agent, and this keeps the daemon dependency free
//  and immune to the iOS WebSocket / HTTP server availability quirks.
//

#import "LCServer.h"
#import "LCCommands.h"

#import <arpa/inet.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <sys/socket.h>
#import <unistd.h>

@interface LCServer ()
@property (nonatomic, assign) int listenFD;
@property (nonatomic, strong) dispatch_queue_t commandQueue;
@end

@implementation LCServer

+ (instancetype)shared {
    static LCServer *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[LCServer alloc] init]; });
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
            const uint8_t *bytes = buffer.bytes;
            NSUInteger length = buffer.length;
            for (NSUInteger i = 0; i < length; i++) {
                if (bytes[i] != '\n') continue;

                NSData *line = [buffer subdataWithRange:NSMakeRange(0, i)];
                [buffer replaceBytesInRange:NSMakeRange(0, i + 1) withBytes:NULL length:0];

                if (line.length == 0) {
                    drained = NO;
                    break;
                }

                __block NSData *response = nil;
                dispatch_sync(self.commandQueue, ^{
                    response = [LCCommands handleLine:line];
                });

                NSMutableData *out = [response mutableCopy];
                [out appendBytes:"\n" length:1];

                const uint8_t *outBytes = out.bytes;
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
