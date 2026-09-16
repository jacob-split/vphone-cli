#import "VPhoneAXBroker.h"
#import "VPhoneAXRuntime.h"
#import "vendor/ios-mcp/MCPAXAttributeBridge.h"
#import "vendor/ios-mcp/MCPAXNodeSource.h"
#import "vendor/ios-mcp/MCPAXQueryContext.h"
#import "vendor/ios-mcp/MCPAXRemoteContextResolver.h"
#import <UIKit/UIKit.h>
#import <arpa/inet.h>
#import <errno.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <unistd.h>

static NSString *const VPAXSocketPath = @"/var/mobile/Library/VPhoneAX/vphone-ax.sock";
static const uint32_t VPAXMaxMessageBytes = 16 * 1024 * 1024;

static BOOL VPAXReadFully(int fd, void *buffer, size_t count) {
    uint8_t *p = buffer;
    while (count) {
        ssize_t n = read(fd, p, count);
        if (n == 0) return NO;
        if (n < 0) { if (errno == EINTR) continue; return NO; }
        p += n; count -= (size_t)n;
    }
    return YES;
}

static BOOL VPAXWriteFully(int fd, const void *buffer, size_t count) {
    const uint8_t *p = buffer;
    while (count) {
        ssize_t n = write(fd, p, count);
        if (n <= 0) { if (n < 0 && errno == EINTR) continue; return NO; }
        p += n; count -= (size_t)n;
    }
    return YES;
}

static NSDictionary *VPAXReadMessage(int fd) {
    uint32_t netLen = 0;
    if (!VPAXReadFully(fd, &netLen, sizeof(netLen))) return nil;
    uint32_t len = ntohl(netLen);
    if (len == 0 || len > VPAXMaxMessageBytes) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:len];
    if (!VPAXReadFully(fd, data.mutableBytes, len)) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}

static BOOL VPAXWriteMessage(int fd, NSDictionary *dict) {
    if (![NSJSONSerialization isValidJSONObject:dict]) return NO;
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
    if (!data || data.length > VPAXMaxMessageBytes) return NO;
    uint32_t netLen = htonl((uint32_t)data.length);
    return VPAXWriteFully(fd, &netLen, sizeof(netLen)) && VPAXWriteFully(fd, data.bytes, data.length);
}

static NSString *VPAXString(id value) {
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value respondsToSelector:@selector(stringValue)]) return [value stringValue];
    return nil;
}

static NSDictionary *VPAXFrame(id node) {
    if (![node isKindOfClass:[NSDictionary class]]) return nil;
    for (NSString *key in @[@"visible_rect", @"visibleFrame", @"rect", @"frame", @"focusable_frame_for_zoom"]) {
        id value = node[key];
        if ([value isKindOfClass:[NSDictionary class]]) return value;
    }
    return nil;
}

static NSDictionary *VPTapForFrame(NSDictionary *frame) {
    if (![frame isKindOfClass:[NSDictionary class]]) return nil;
    NSNumber *x = frame[@"x"] ?: frame[@"X"];
    NSNumber *y = frame[@"y"] ?: frame[@"Y"];
    NSNumber *w = frame[@"width"] ?: frame[@"Width"];
    NSNumber *h = frame[@"height"] ?: frame[@"Height"];
    if (!x || !y || !w || !h || w.doubleValue <= 0 || h.doubleValue <= 0) return nil;
    return @{@"x": @(x.doubleValue + w.doubleValue / 2.0), @"y": @(y.doubleValue + h.doubleValue / 2.0)};
}

static NSString *VPAXNormalizedRole(NSDictionary *node) {
    NSString *raw = VPAXString(node[@"role"]) ?: VPAXString(node[@"type"]) ?: @"";
    NSString *lower = raw.lowercaseString;
    NSDictionary *map = @{
        @"button": @"button", @"link": @"link", @"image": @"image",
        @"searchfield": @"search_field", @"securetextfield": @"secure_text_field",
        @"textfield": @"text_field", @"textview": @"text_view", @"statictext": @"text",
        @"switch": @"switch", @"slider": @"slider", @"picker": @"picker",
        @"cell": @"cell", @"table": @"table", @"collection": @"collection",
        @"navigationbar": @"navigation_bar", @"tabbar": @"tab_bar", @"key": @"keyboard_key",
        @"alert": @"alert", @"window": @"window", @"application": @"application"
    };
    for (NSString *needle in map) if ([lower containsString:needle]) return map[needle];

    unsigned long long traits = [node[@"traits"] respondsToSelector:@selector(unsignedLongLongValue)] ? [node[@"traits"] unsignedLongLongValue] : 0;
    if (traits & UIAccessibilityTraitButton) return @"button";
    if (traits & UIAccessibilityTraitLink) return @"link";
    if (traits & UIAccessibilityTraitSearchField) return @"search_field";
    if (traits & UIAccessibilityTraitKeyboardKey) return @"keyboard_key";
    if (traits & UIAccessibilityTraitImage) return @"image";
    if (traits & UIAccessibilityTraitHeader) return @"header";
    if (traits & UIAccessibilityTraitAdjustable) return @"adjustable";
    if (node[@"placeholder"]) return @"text_field";
    if ([node[@"clickable"] boolValue] || [node[@"user_interaction_enabled"] boolValue]) return @"control";
    if ([node[@"children"] isKindOfClass:[NSArray class]] && [node[@"children"] count]) return @"group";
    if (node[@"label"] || node[@"text"] || node[@"value"]) return @"text";
    return @"element";
}

static BOOL VPAXRoleClickable(NSString *role) {
    static NSSet *roles;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ roles = [NSSet setWithArray:@[@"button",@"link",@"search_field",@"text_field",@"secure_text_field",@"text_view",@"switch",@"slider",@"picker",@"adjustable",@"keyboard_key",@"control",@"cell"]]; });
    return [roles containsObject:role];
}

@interface VPhoneAXBroker ()
@property(nonatomic) int listenFD;
@property(nonatomic) dispatch_queue_t queue;
@property(nonatomic) MCPAXAttributeBridge *bridge;
@property(nonatomic) MCPAXNodeSource *nodeSource;
@property(nonatomic) MCPAXRemoteContextResolver *resolver;
@property(nonatomic) NSDictionary *bootstrap;
@property(nonatomic) uint64_t generation;
@end

@implementation VPhoneAXBroker
+ (instancetype)sharedBroker { static VPhoneAXBroker *b; static dispatch_once_t once; dispatch_once(&once, ^{ b=[VPhoneAXBroker new]; }); return b; }

- (instancetype)init {
    if ((self=[super init])) {
        _listenFD = -1;
        _queue = dispatch_queue_create("com.vphone.ax.broker", DISPATCH_QUEUE_SERIAL);
        _bridge = [MCPAXAttributeBridge new];
        _nodeSource = [[MCPAXNodeSource alloc] initWithAttributeBridge:_bridge];
        _resolver = [MCPAXRemoteContextResolver new];
        _generation = 0;
    }
    return self;
}

- (void)start {
    if (self.listenFD >= 0) return;
    self.bootstrap = VPhoneAXBootstrapRuntime();
    NSString *dir = VPAXSocketPath.stringByDeletingLastPathComponent;
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0770} error:nil];
    unlink(VPAXSocketPath.fileSystemRepresentation);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { NSLog(@"[VPhoneAX] socket failed: %s", strerror(errno)); return; }
    struct sockaddr_un addr = {0}; addr.sun_family = AF_UNIX;
    strlcpy(addr.sun_path, VPAXSocketPath.fileSystemRepresentation, sizeof(addr.sun_path));
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 4) != 0) {
        NSLog(@"[VPhoneAX] bind/listen failed: %s", strerror(errno)); close(fd); return;
    }
    chmod(VPAXSocketPath.fileSystemRepresentation, 0660);
    self.listenFD = fd;
    NSLog(@"[VPhoneAX] broker listening on %@", VPAXSocketPath);
    dispatch_async(self.queue, ^{ [self acceptLoop]; });
}

- (void)stop { int fd=self.listenFD; self.listenFD=-1; if (fd>=0) close(fd); unlink(VPAXSocketPath.fileSystemRepresentation); }

- (void)acceptLoop {
    while (self.listenFD >= 0) {
        int client = accept(self.listenFD, NULL, NULL);
        if (client < 0) { if (errno == EINTR) continue; usleep(100000); continue; }
        @autoreleasepool {
            NSDictionary *req = VPAXReadMessage(client);
            NSDictionary *resp = req ? [self handleRequest:req] : @{ @"ok":@NO, @"error":@"invalid request" };
            if (!VPAXWriteMessage(client, resp)) NSLog(@"[VPhoneAX] response write failed");
        }
        close(client);
    }
}

- (MCPAXQueryContext *)context { return [self.resolver frontmostContext]; }

- (NSMutableDictionary *)semanticNode:(NSDictionary *)source path:(NSString *)path generation:(uint64_t)generation {
    NSMutableDictionary *node = [source mutableCopy] ?: [NSMutableDictionary dictionary];
    NSString *rawRole = VPAXString(source[@"role"]) ?: VPAXString(source[@"type"]);
    NSString *role = VPAXNormalizedRole(source);
    if (rawRole.length && ![rawRole isEqualToString:role]) node[@"raw_role"] = rawRole;
    node[@"role"] = role;
    node[@"semantic_id"] = [NSString stringWithFormat:@"g%llu:%@", generation, path];
    node[@"path"] = path;
    BOOL clickable = [source[@"clickable"] boolValue] || [source[@"user_interaction_enabled"] boolValue] || VPAXRoleClickable(role);
    node[@"clickable"] = @(clickable);
    if (!node[@"tap"]) { NSDictionary *tap = VPTapForFrame(VPAXFrame(source)); if (tap) node[@"tap"] = tap; }
    NSArray *children = [source[@"children"] isKindOfClass:[NSArray class]] ? source[@"children"] : nil;
    if (children.count) {
        NSMutableArray *out=[NSMutableArray arrayWithCapacity:children.count];
        [children enumerateObjectsUsingBlock:^(NSDictionary *child, NSUInteger idx, BOOL *stop) {
            [out addObject:[self semanticNode:child path:[NSString stringWithFormat:@"%@.%lu",path,(unsigned long)idx] generation:generation]];
            (void)stop;
        }];
        node[@"children"] = out;
    }
    return node;
}

- (NSDictionary *)semanticPayload:(NSDictionary *)payload {
    uint64_t gen = ++self.generation;
    NSMutableDictionary *out=[payload mutableCopy]; out[@"generation"] = @(gen);
    if (!out[@"screen"]) {
        CGRect b = UIScreen.mainScreen.bounds;
        out[@"screen"] = @{@"width": @(CGRectGetWidth(b)), @"height": @(CGRectGetHeight(b)), @"scale": @(UIScreen.mainScreen.scale)};
    }
    NSArray *elements=[payload[@"elements"] isKindOfClass:[NSArray class]] ? payload[@"elements"] : nil;
    if (elements) {
        NSMutableArray *semantic=[NSMutableArray arrayWithCapacity:elements.count];
        [elements enumerateObjectsUsingBlock:^(NSDictionary *node, NSUInteger idx, BOOL *stop) {
            [semantic addObject:[self semanticNode:node path:[NSString stringWithFormat:@"c.%lu",(unsigned long)idx] generation:gen]]; (void)stop;
        }]; out[@"elements"]=semantic;
    }
    NSDictionary *root=[payload[@"root"] isKindOfClass:[NSDictionary class]] ? payload[@"root"] : nil;
    if (root) out[@"root"]=[self semanticNode:root path:@"0" generation:gen];
    return out;
}

- (NSDictionary *)treeForContext:(MCPAXQueryContext *)ctx request:(NSDictionary *)req error:(NSString **)error {
    NSString *mode = [VPAXString(req[@"mode"]) lowercaseString] ?: @"compact";
    NSInteger maxElements = [req[@"max_elements"] respondsToSelector:@selector(integerValue)] ? [req[@"max_elements"] integerValue] : 500;
    if ([mode isEqualToString:@"full"] || [mode isEqualToString:@"tree"] || [mode isEqualToString:@"raw"]) {
        NSInteger depth = [req[@"max_depth"] respondsToSelector:@selector(integerValue)] ? [req[@"max_depth"] integerValue] : 20;
        return [self.nodeSource treeForPid:ctx.pid bundleId:ctx.bundleId contextId:ctx.contextId displayId:ctx.displayId maxDepth:depth maxElements:maxElements error:error];
    }
    BOOL visible = req[@"visible_only"] ? [req[@"visible_only"] boolValue] : YES;
    BOOL clickable = req[@"clickable_only"] ? [req[@"clickable_only"] boolValue] : NO;
    return [self.nodeSource compactElementsForPid:ctx.pid bundleId:ctx.bundleId contextId:ctx.contextId displayId:ctx.displayId maxElements:maxElements visibleOnly:visible clickableOnly:clickable error:error];
}

- (void)flattenNode:(NSDictionary *)node into:(NSMutableArray *)out { if (!node) return; [out addObject:node]; for (NSDictionary *c in node[@"children"]) if ([c isKindOfClass:[NSDictionary class]]) [self flattenNode:c into:out]; }
- (NSArray *)flattenPayload:(NSDictionary *)payload { NSMutableArray *out=[NSMutableArray array]; for (NSDictionary *e in payload[@"elements"]) if ([e isKindOfClass:[NSDictionary class]]) [out addObject:e]; if ([payload[@"root"] isKindOfClass:[NSDictionary class]]) [self flattenNode:payload[@"root"] into:out]; return out; }

- (NSInteger)scoreNode:(NSDictionary *)node selector:(NSDictionary *)sel {
    NSString *identifier=VPAXString(sel[@"identifier"]); NSString *role=[VPAXString(sel[@"role"]) lowercaseString]; NSString *label=VPAXString(sel[@"label"]); NSString *value=VPAXString(sel[@"value"]);
    if (identifier.length && ![VPAXString(node[@"identifier"]) isEqualToString:identifier]) return -1;
    if (role.length && ![[VPAXString(node[@"role"]) lowercaseString] isEqualToString:role]) return -1;
    if (sel[@"visible"] && [node[@"visible"] respondsToSelector:@selector(boolValue)] && [node[@"visible"] boolValue] != [sel[@"visible"] boolValue]) return -1;
    if (sel[@"clickable"] && [node[@"clickable"] boolValue] != [sel[@"clickable"] boolValue]) return -1;
    if (value.length && ![VPAXString(node[@"value"]) isEqualToString:value]) return -1;
    NSInteger score=0; if (identifier.length) score+=200; if (role.length) score+=50; if (value.length) score+=30;
    if (label.length) {
        NSMutableArray<NSString *> *candidates=[NSMutableArray array];
        for (NSString *key in @[@"label",@"text",@"title",@"placeholder",@"identifier"]) { NSString *s=VPAXString(node[key]); if (s.length) [candidates addObject:s]; }
        for (id a in node[@"aliases"]) if ([a isKindOfClass:[NSString class]]) [candidates addObject:a];
        NSInteger best=-1; BOOL contains=[sel[@"contains"] boolValue];
        for (NSString *c in candidates) {
            if ([c isEqualToString:label]) best=MAX(best,100);
            else if ([c caseInsensitiveCompare:label]==NSOrderedSame) best=MAX(best,80);
            else if (contains && [c rangeOfString:label options:NSCaseInsensitiveSearch].location!=NSNotFound) best=MAX(best,60);
        }
        if (best<0) return -1; score+=best;
    }
    return score;
}

- (NSDictionary *)findInPayload:(NSDictionary *)payload selector:(NSDictionary *)selector {
    NSArray *nodes=[self flattenPayload:payload]; NSMutableArray *matches=[NSMutableArray array]; NSInteger best=-1;
    for (NSDictionary *node in nodes) { NSInteger score=[self scoreNode:node selector:selector]; if (score<0) continue; if (score>best){best=score;[matches removeAllObjects];} if(score==best)[matches addObject:node]; }
    id screen = payload[@"screen"] ?: @{};
    if (!matches.count) return @{ @"ok":@NO, @"error":@"not_found", @"generation":payload[@"generation"] ?: @0, @"screen":screen };
    NSInteger index = [selector[@"index"] respondsToSelector:@selector(integerValue)] ? [selector[@"index"] integerValue] : -1;
    if (index >= 0) { if (index >= (NSInteger)matches.count) return @{ @"ok":@NO,@"error":@"index_out_of_range",@"match_count":@(matches.count),@"screen":screen }; return @{ @"ok":@YES,@"node":matches[index],@"match_count":@(matches.count),@"generation":payload[@"generation"] ?: @0,@"screen":screen }; }
    if (matches.count > 1) { NSUInteger n=MIN(matches.count,10); return @{ @"ok":@NO,@"error":@"ambiguous",@"match_count":@(matches.count),@"candidates":[matches subarrayWithRange:NSMakeRange(0,n)],@"generation":payload[@"generation"] ?: @0,@"screen":screen }; }
    return @{ @"ok":@YES,@"node":matches.firstObject,@"match_count":@1,@"generation":payload[@"generation"] ?: @0,@"screen":screen };
}

- (NSDictionary *)handleRequest:(NSDictionary *)req {
    NSString *type=VPAXString(req[@"t"]) ?: @"";
    if ([type isEqualToString:@"status"]) {
        MCPAXQueryContext *ctx=[self context]; NSString *runtimeError=nil; BOOL runtime=[self.bridge ensureRuntimeAvailable:&runtimeError];
        NSMutableDictionary *r=[@{@"ok":@(runtime),@"runtime":VPhoneAXRuntimeStatus(),@"bootstrap":self.bootstrap ?: @{}} mutableCopy];
        if (ctx) r[@"frontmost_context"]=[ctx dictionaryRepresentation]; if (runtimeError.length) r[@"error"]=runtimeError; return r;
    }
    MCPAXQueryContext *ctx=[self context]; if (!ctx || ctx.pid<=0) return @{ @"ok":@NO,@"error":@"no_frontmost_context" };
    if ([type isEqualToString:@"tree"]) {
        NSString *error=nil; NSDictionary *raw=[self treeForContext:ctx request:req error:&error];
        if (!raw) { self.bootstrap=VPhoneAXBootstrapRuntime(); raw=[self treeForContext:ctx request:req error:&error]; }
        if (!raw) return @{ @"ok":@NO,@"error":error ?: @"tree_failed" };
        NSMutableDictionary *r=[[self semanticPayload:raw] mutableCopy]; r[@"ok"]=@YES; r[@"frontmost_context"]=[ctx dictionaryRepresentation]; return r;
    }
    if ([type isEqualToString:@"hit_test"]) {
        double x=[req[@"x"] doubleValue], y=[req[@"y"] doubleValue]; NSString *error=nil;
        NSDictionary *raw=[self.nodeSource elementAtPoint:CGPointMake(x,y) pid:ctx.pid contextId:ctx.contextId displayId:ctx.displayId allowParameterizedHitTest:YES error:&error];
        if (!raw) return @{ @"ok":@NO,@"error":error ?: @"hit_test_failed" };
        uint64_t gen=++self.generation; return @{ @"ok":@YES,@"node":[self semanticNode:raw path:@"hit" generation:gen],@"generation":@(gen) };
    }
    if ([type isEqualToString:@"find"]) {
        NSDictionary *selector=[req[@"selector"] isKindOfClass:[NSDictionary class]] ? req[@"selector"] : @{};
        NSMutableDictionary *query=[req mutableCopy]; query[@"mode"]=@"compact"; query[@"max_elements"]=req[@"max_elements"] ?: @1000; query[@"visible_only"]=req[@"visible_only"] ?: @YES;
        NSString *error=nil; NSDictionary *raw=[self treeForContext:ctx request:query error:&error]; NSDictionary *semantic=raw ? [self semanticPayload:raw] : nil;
        NSDictionary *found=semantic ? [self findInPayload:semantic selector:selector] : nil;
        if (!found || (![found[@"ok"] boolValue] && [found[@"error"] isEqual:@"not_found"] && (req[@"deep"]==nil || [req[@"deep"] boolValue]))) {
            query[@"mode"]=@"full"; query[@"max_depth"]=req[@"max_depth"] ?: @20; raw=[self treeForContext:ctx request:query error:&error]; semantic=raw ? [self semanticPayload:raw] : nil; found=semantic ? [self findInPayload:semantic selector:selector] : nil;
        }
        return found ?: @{ @"ok":@NO,@"error":error ?: @"find_failed" };
    }
    if ([type isEqualToString:@"bootstrap"]) { self.bootstrap=VPhoneAXBootstrapRuntime(); return @{ @"ok":@YES,@"bootstrap":self.bootstrap }; }
    return @{ @"ok":@NO,@"error":[NSString stringWithFormat:@"unknown command: %@",type] };
}
@end
