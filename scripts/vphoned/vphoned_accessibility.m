#import "vphoned_accessibility.h"
#import "vphoned_hid.h"
#import "vphoned_protocol.h"
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <errno.h>
#import <math.h>

static NSString *const kVPAXSocketPath = @"/var/mobile/Library/VPhoneAX/vphone-ax.sock";

static int vp_ax_connect(void) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strlcpy(addr.sun_path, kVPAXSocketPath.fileSystemRepresentation, sizeof(addr.sun_path));
    struct timeval timeout = {.tv_sec = 30, .tv_usec = 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) { close(fd); return -1; }
    return fd;
}

static NSDictionary *vp_ax_request(NSDictionary *request, NSString **error) {
    int fd = vp_ax_connect();
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

static NSMutableDictionary *vp_ax_forward_payload(NSDictionary *msg, NSString *brokerType) {
    NSMutableDictionary *request = [NSMutableDictionary dictionaryWithObject:brokerType forKey:@"t"];
    for (NSString *key in @[@"mode",@"max_depth",@"max_elements",@"visible_only",@"clickable_only",@"deep",@"selector",@"x",@"y"]) {
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
    if (![action isEqualToString:@"tap"]) return vp_ax_error([NSString stringWithFormat:@"unsupported semantic action: %@", action], reqId);

    NSMutableDictionary *find = [NSMutableDictionary dictionaryWithDictionary:@{@"t":@"find", @"selector":selector, @"deep":@YES}];
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
    if (!tap || width <= 0 || height <= 0) return vp_ax_error(@"semantic target has no actionable tap geometry", reqId);

    double nx = fmin(1.0, fmax(0.0, x / width));
    double ny = fmin(1.0, fmax(0.0, y / height));
    vp_hid_touch(0, nx, ny);
    usleep(60000);
    vp_hid_touch(3, nx, ny);

    NSMutableDictionary *result = [found mutableCopy];
    result[@"action"] = @"tap";
    result[@"tap_normalized"] = @{@"x":@(nx), @"y":@(ny)};
    return vp_ax_wrap_response(result, reqId);
}

NSDictionary *vp_handle_accessibility_command(NSDictionary *msg) {
    id reqId = msg[@"id"];
    NSString *type = [msg[@"t"] isKindOfClass:[NSString class]] ? msg[@"t"] : @"";
    if ([type isEqualToString:@"accessibility_action"]) return vp_ax_action(msg, reqId);

    NSDictionary *mapping = @{
        @"accessibility_status": @"status",
        @"accessibility_tree": @"tree",
        @"accessibility_find": @"find",
        @"accessibility_hit_test": @"hit_test",
        @"accessibility_bootstrap": @"bootstrap"
    };
    NSString *brokerType = mapping[type];
    if (!brokerType) return vp_ax_error([NSString stringWithFormat:@"unknown accessibility command: %@", type], reqId);

    NSString *error = nil;
    NSDictionary *response = vp_ax_request(vp_ax_forward_payload(msg, brokerType), &error);
    if (!response) return vp_ax_error(error, reqId);
    return vp_ax_wrap_response(response, reqId);
}
