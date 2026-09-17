#import "vphoned_accessibility.h"
#import "vphoned_hid.h"
#import "vphoned_protocol.h"
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <errno.h>
#import <fcntl.h>
#import <poll.h>
#import <math.h>

static NSString *const kVPAXSocketPath = @"/var/mobile/Library/VPhoneAX/vphone-ax.sock";

static int vp_ax_connect(int timeoutSeconds) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strlcpy(addr.sun_path, kVPAXSocketPath.fileSystemRepresentation, sizeof(addr.sun_path));

    // A stale SpringBoard broker socket can leave blocking AF_UNIX connect()
    // waiting indefinitely. Bound connect separately from request I/O so one
    // unavailable broker can never stall vphoned's serial control loop.
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) { close(fd); return -1; }
    if (fcntl(fd, F_SETFL, flags | O_NONBLOCK) != 0) { close(fd); return -1; }

    int rc = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    if (rc != 0) {
        int saved = errno;
        if (saved == EINPROGRESS || saved == EAGAIN || saved == EWOULDBLOCK) {
            struct pollfd pfd = {.fd = fd, .events = POLLOUT, .revents = 0};
            int connectMs = MIN(MAX(timeoutSeconds, 1), 3) * 1000;
            int prc;
            do { prc = poll(&pfd, 1, connectMs); } while (prc < 0 && errno == EINTR);
            if (prc <= 0) {
                errno = prc == 0 ? ETIMEDOUT : errno;
                close(fd);
                return -1;
            }
            int socketError = 0; socklen_t errorLength = sizeof(socketError);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &errorLength) != 0 || socketError != 0) {
                if (socketError) errno = socketError;
                close(fd);
                return -1;
            }
        } else {
            errno = saved;
            close(fd);
            return -1;
        }
    }
    (void)fcntl(fd, F_SETFL, flags);

    struct timeval timeout = {.tv_sec = timeoutSeconds, .tv_usec = 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    return fd;
}

static int vp_ax_request_timeout_seconds(NSDictionary *request) {
    NSString *type = [request[@"t"] isKindOfClass:[NSString class]] ? request[@"t"] : @"";
    if ([type isEqualToString:@"status"] || [type isEqualToString:@"device_state"] ||
        [type isEqualToString:@"bootstrap"] || [type isEqualToString:@"device_unlock"] ||
        [type isEqualToString:@"device_lock"]) {
        return 5;
    }
    return 15;
}

static NSDictionary *vp_ax_request_sync(NSDictionary *request, NSString **error, int timeoutSeconds) {
    int fd = vp_ax_connect(timeoutSeconds);
    if (fd < 0) {
        if (error) *error = [NSString stringWithFormat:@"VPhoneAX broker unavailable at %@: %s", kVPAXSocketPath, strerror(errno)];
        return nil;
    }
    if (!vp_write_message(fd, request)) {
        if (error) *error = @"failed to write VPhoneAX request";
        close(fd); return nil;
    }
    NSDictionary *response = vp_read_message(fd);
    close(fd);
    if (![response isKindOfClass:[NSDictionary class]]) {
        if (error) *error = @"invalid or timed-out VPhoneAX response";
        return nil;
    }
    return response;
}

static dispatch_queue_t vp_ax_request_queue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.split.vphoned.accessibility", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSDictionary *vp_ax_request(NSDictionary *request, NSString **error) {
    int timeoutSeconds = vp_ax_request_timeout_seconds(request);
    __block NSDictionary *response = nil;
    __block NSString *innerError = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(vp_ax_request_queue(), ^{
        @autoreleasepool {
            response = vp_ax_request_sync(request, &innerError, timeoutSeconds);
            dispatch_semaphore_signal(done);
        }
    });

    // The broker itself is not allowed to monopolize vphoned's serial control
    // loop. Socket timeouts should normally win first; this outer deadline is a
    // final guard against SpringBoard/private-framework calls that never return.
    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeoutSeconds + 1) * NSEC_PER_SEC);
    if (dispatch_semaphore_wait(done, deadline) != 0) {
        if (error) *error = [NSString stringWithFormat:@"VPhoneAX broker request exceeded %ds deadline", timeoutSeconds + 1];
        return nil;
    }
    if (error) *error = innerError;
    return response;
}

static NSMutableDictionary *vp_ax_forward_payload(NSDictionary *msg, NSString *brokerType) {
    NSMutableDictionary *request = [NSMutableDictionary dictionaryWithObject:brokerType forKey:@"t"];
    for (NSString *key in @[@"mode",@"max_depth",@"max_elements",@"visible_only",@"clickable_only",@"deep",@"selector",@"x",@"y",@"strategy",@"source",@"action",@"text"]) {
        if (msg[key]) request[key] = msg[key];
    }
    return request;
}

static NSDictionary *vp_ax_wrap_response(NSDictionary *broker, id reqId) {
    NSMutableDictionary *r = vp_make_response(@"accessibility", reqId);
    [r addEntriesFromDictionary:broker ?: @{}];
    r[@"t"] = @"accessibility";
    return r;
}

static NSDictionary *vp_ax_error(NSString *message, id reqId) {
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = message ?: @"semantic accessibility failed";
    return r;
}

static NSDictionary *vp_ax_action(NSDictionary *msg, id reqId) {
    NSDictionary *selector = [msg[@"selector"] isKindOfClass:[NSDictionary class]] ? msg[@"selector"] : @{};
    NSString *action = [msg[@"action"] isKindOfClass:[NSString class]] ? [msg[@"action"] lowercaseString] : @"tap";
    if (![action isEqualToString:@"tap"]) {
        return vp_ax_error([NSString stringWithFormat:@"unsupported semantic action: %@", action], reqId);
    }

    NSMutableDictionary *find = [NSMutableDictionary dictionaryWithDictionary:@{
        @"t": @"find", @"selector": selector, @"deep": @YES
    }];
    if (msg[@"max_depth"]) find[@"max_depth"] = msg[@"max_depth"];

    NSString *error = nil;
    NSDictionary *found = vp_ax_request(find, &error);
    if (!found) return vp_ax_error(error, reqId);
    if (![found[@"ok"] boolValue]) return vp_ax_wrap_response(found, reqId);

    NSDictionary *node = [found[@"node"] isKindOfClass:[NSDictionary class]] ? found[@"node"] : nil;
    NSDictionary *tap = [node[@"tap"] isKindOfClass:[NSDictionary class]] ? node[@"tap"] : nil;
    NSDictionary *screen = [found[@"screen"] isKindOfClass:[NSDictionary class]] ? found[@"screen"] : nil;
    double width = [screen[@"width"] doubleValue], height = [screen[@"height"] doubleValue];
    double x = [tap[@"x"] doubleValue], y = [tap[@"y"] doubleValue];
    if (!tap || width <= 0 || height <= 0) {
        return vp_ax_error(@"semantic target has no actionable tap geometry", reqId);
    }

    double nx = fmin(1.0, fmax(0.0, x / width));
    double ny = fmin(1.0, fmax(0.0, y / height));
    vp_hid_touch(0, nx, ny);
    usleep(80000);
    vp_hid_touch(3, nx, ny);

    NSMutableDictionary *result = [found mutableCopy];
    result[@"action"] = @"tap";
    result[@"injection"] = @"guest_hid";
    result[@"tap_normalized"] = @{@"x":@(nx), @"y":@(ny)};
    return vp_ax_wrap_response(result, reqId);
}

NSDictionary *vp_accessibility_frontmost_context(void) {
    NSString *error = nil;
    NSDictionary *response = vp_ax_request(@{@"t": @"status"}, &error);
    if (![response isKindOfClass:[NSDictionary class]] || ![response[@"ok"] boolValue]) return nil;
    NSDictionary *context = [response[@"frontmost_context"] isKindOfClass:[NSDictionary class]]
        ? response[@"frontmost_context"] : nil;
    return context;
}

NSDictionary *vp_handle_accessibility_command(NSDictionary *msg) {
    id reqId = msg[@"id"];
    NSString *type = [msg[@"t"] isKindOfClass:[NSString class]] ? msg[@"t"] : @"";
    NSDictionary *mapping = @{
        @"accessibility_status": @"status",
        @"accessibility_tree": @"tree",
        @"accessibility_find": @"find",
        @"accessibility_hit_test": @"hit_test",
        @"accessibility_action": @"action",
        @"accessibility_device_state": @"device_state",
        @"accessibility_device_lock": @"device_lock",
        @"accessibility_device_unlock": @"device_unlock",
        @"accessibility_bootstrap": @"bootstrap"
    };
    NSString *brokerType = mapping[type];
    if (!brokerType) return vp_ax_error([NSString stringWithFormat:@"unknown accessibility command: %@", type], reqId);

    NSString *error = nil;
    NSDictionary *response = vp_ax_request(vp_ax_forward_payload(msg, brokerType), &error);
    if (!response) return vp_ax_error(error, reqId);
    return vp_ax_wrap_response(response, reqId);
}
