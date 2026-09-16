#import "VPhoneAXRuntime.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <unistd.h>

typedef BOOL (*VPAXBoolGetter)(void);
typedef void (*VPAXBoolSetter)(BOOL);
typedef void (*VPAXVoidFunc)(void);
typedef void (*VPAXSetRequestingClientFunc)(uint32_t);

typedef struct {
    BOOL resolved;
    void *accessibilityHandle;
    void *utilitiesHandle;
    void *axRuntimeHandle;
    VPAXBoolGetter applicationAccessibilityEnabled;
    VPAXBoolSetter applicationAccessibilitySetEnabled;
    VPAXBoolGetter voiceOverUsageConfirmed;
    VPAXBoolSetter voiceOverUsageSetConfirmed;
    VPAXVoidFunc primeDisplayManager;
    VPAXSetRequestingClientFunc setRequestingClient;
} VPAXRuntime;

static VPAXRuntime gRuntime;
static id gAXUIClient;

@interface VPAXClientDelegate : NSObject
@property(atomic) BOOL serverReady;
@property(atomic, copy) NSString *lastMessage;
@end
@implementation VPAXClientDelegate
- (void)userInterfaceClient:(id)client willActivateUserInterfaceServiceWithInitializationMessage:(id)message {
    self.serverReady = YES;
    self.lastMessage = [message description];
    (void)client;
}
- (id)userInterfaceClient:(id)client processMessageFromServer:(id)message withIdentifier:(id)identifier error:(id *)error {
    self.lastMessage = [message description];
    if (error) *error = nil;
    (void)client; (void)identifier;
    return nil;
}
@end
static VPAXClientDelegate *gDelegate;

static void *VPAXDlopenFirst(const char **paths, size_t count) {
    for (size_t i = 0; i < count; i++) {
        void *h = dlopen(paths[i], RTLD_NOW | RTLD_GLOBAL);
        if (h) return h;
    }
    return NULL;
}

static void *VPAXSymbol(void *handle, const char *a, const char *b) {
    void *sym = handle ? dlsym(handle, a) : dlsym(RTLD_DEFAULT, a);
    if (!sym && b) sym = handle ? dlsym(handle, b) : dlsym(RTLD_DEFAULT, b);
    return sym;
}

static void VPAXResolveRuntime(void) {
    if (gRuntime.resolved) return;
    gRuntime.resolved = YES;

    const char *accessibilityPaths[] = {
        "/System/Library/Frameworks/Accessibility.framework/Accessibility",
        "/usr/lib/libAccessibility.dylib",
        "/var/jb/usr/lib/libAccessibility.dylib"
    };
    const char *utilityPaths[] = {
        "/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities",
        "/var/jb/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities"
    };
    const char *runtimePaths[] = {
        "/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime",
        "/var/jb/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime"
    };

    gRuntime.accessibilityHandle = VPAXDlopenFirst(accessibilityPaths, sizeof(accessibilityPaths)/sizeof(accessibilityPaths[0]));
    gRuntime.utilitiesHandle = VPAXDlopenFirst(utilityPaths, sizeof(utilityPaths)/sizeof(utilityPaths[0]));
    gRuntime.axRuntimeHandle = VPAXDlopenFirst(runtimePaths, sizeof(runtimePaths)/sizeof(runtimePaths[0]));

    gRuntime.applicationAccessibilityEnabled = (VPAXBoolGetter)VPAXSymbol(gRuntime.accessibilityHandle, "_AXSApplicationAccessibilityEnabled", "__AXSApplicationAccessibilityEnabled");
    gRuntime.applicationAccessibilitySetEnabled = (VPAXBoolSetter)VPAXSymbol(gRuntime.accessibilityHandle, "_AXSApplicationAccessibilitySetEnabled", "__AXSApplicationAccessibilitySetEnabled");
    gRuntime.voiceOverUsageConfirmed = (VPAXBoolGetter)VPAXSymbol(gRuntime.accessibilityHandle, "_AXSVoiceOverTouchUsageConfirmed", "__AXSVoiceOverTouchUsageConfirmed");
    gRuntime.voiceOverUsageSetConfirmed = (VPAXBoolSetter)VPAXSymbol(gRuntime.accessibilityHandle, "_AXSVoiceOverTouchSetUsageConfirmed", "__AXSVoiceOverTouchSetUsageConfirmed");
    gRuntime.primeDisplayManager = (VPAXVoidFunc)VPAXSymbol(gRuntime.utilitiesHandle, "_AXDevicePrimeDisplayManager", NULL);
    gRuntime.setRequestingClient = (VPAXSetRequestingClientFunc)VPAXSymbol(gRuntime.axRuntimeHandle, "__AXSetRequestingClient", "_AXSetRequestingClient");
}

static BOOL VPAXLoadAccessibilityUI(void) {
    if (NSClassFromString(@"AXUIClient")) return YES;
    const char *paths[] = {
        "/System/Library/PrivateFrameworks/AccessibilityUI.framework/AccessibilityUI",
        "/var/jb/System/Library/PrivateFrameworks/AccessibilityUI.framework/AccessibilityUI"
    };
    return VPAXDlopenFirst(paths, sizeof(paths)/sizeof(paths[0])) != NULL && NSClassFromString(@"AXUIClient") != Nil;
}

static NSDictionary *VPAXPrimeWorkspace(void) {
    VPAXResolveRuntime();
    NSMutableDictionary *r = [NSMutableDictionary dictionary];
    BOOL beforeApp = gRuntime.applicationAccessibilityEnabled ? gRuntime.applicationAccessibilityEnabled() : NO;
    BOOL beforeVO = gRuntime.voiceOverUsageConfirmed ? gRuntime.voiceOverUsageConfirmed() : NO;
    if (gRuntime.primeDisplayManager) gRuntime.primeDisplayManager();
    if (gRuntime.applicationAccessibilitySetEnabled && !beforeApp) gRuntime.applicationAccessibilitySetEnabled(YES);
    if (gRuntime.voiceOverUsageSetConfirmed && !beforeVO) gRuntime.voiceOverUsageSetConfirmed(YES);
    if (gRuntime.setRequestingClient) gRuntime.setRequestingClient(2);
    BOOL afterApp = gRuntime.applicationAccessibilityEnabled ? gRuntime.applicationAccessibilityEnabled() : beforeApp;
    BOOL afterVO = gRuntime.voiceOverUsageConfirmed ? gRuntime.voiceOverUsageConfirmed() : beforeVO;
    r[@"applicationAccessibilityBefore"] = @(beforeApp);
    r[@"applicationAccessibilityAfter"] = @(afterApp);
    r[@"voiceOverUsageBefore"] = @(beforeVO);
    r[@"voiceOverUsageAfter"] = @(afterVO);
    r[@"primedDisplayManager"] = @(gRuntime.primeDisplayManager != NULL);
    r[@"setRequestingClient"] = @(gRuntime.setRequestingClient != NULL);
    r[@"ok"] = @((afterApp || gRuntime.applicationAccessibilitySetEnabled) && gRuntime.axRuntimeHandle != NULL);
    return r;
}

static void VPAXSend(id client, NSDictionary *message, NSUInteger identifier) {
    SEL sel = @selector(sendAsynchronousMessage:withIdentifier:targetAccessQueue:completion:);
    if (client && [client respondsToSelector:sel]) {
        ((void (*)(id, SEL, id, NSUInteger, id, id))objc_msgSend)(client, sel, message ?: @{}, identifier, nil, nil);
    }
}

NSDictionary *VPhoneAXRuntimeStatus(void) {
    VPAXResolveRuntime();
    NSMutableDictionary *r = [NSMutableDictionary dictionary];
    r[@"pid"] = @(getpid());
    r[@"process"] = NSProcessInfo.processInfo.processName ?: @"";
    r[@"axRuntimeLoaded"] = @(gRuntime.axRuntimeHandle != NULL);
    r[@"accessibilityLoaded"] = @(gRuntime.accessibilityHandle != NULL);
    r[@"accessibilityUtilitiesLoaded"] = @(gRuntime.utilitiesHandle != NULL);
    r[@"hasAXUIClient"] = @(NSClassFromString(@"AXUIClient") != Nil);
    r[@"clientCreated"] = @(gAXUIClient != nil);
    r[@"serverReady"] = @(gDelegate.serverReady);
    r[@"canSetRequestingClient"] = @(gRuntime.setRequestingClient != NULL);
    r[@"canPrimeDisplayManager"] = @(gRuntime.primeDisplayManager != NULL);
    if (gRuntime.applicationAccessibilityEnabled) r[@"applicationAccessibilityEnabled"] = @(gRuntime.applicationAccessibilityEnabled());
    if (gRuntime.voiceOverUsageConfirmed) r[@"voiceOverUsageConfirmed"] = @(gRuntime.voiceOverUsageConfirmed());
    if (gDelegate.lastMessage.length) r[@"lastServerMessage"] = gDelegate.lastMessage;
    return r;
}

NSDictionary *VPhoneAXBootstrapRuntime(void) {
    __block NSMutableDictionary *result = [NSMutableDictionary dictionary];
    void (^work)(void) = ^{
        BOOL loadedUI = VPAXLoadAccessibilityUI();
        NSDictionary *workspace = VPAXPrimeWorkspace();
        result[@"loadedAccessibilityUI"] = @(loadedUI);
        result[@"workspace"] = workspace;
        if (loadedUI) {
            Class cls = NSClassFromString(@"AXUIClient");
            if (!gDelegate) gDelegate = [VPAXClientDelegate new];
            if (!gAXUIClient && cls) {
                id allocated = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(alloc));
                if ([allocated respondsToSelector:@selector(initWithIdentifier:serviceBundleName:)]) {
                    gAXUIClient = ((id (*)(id, SEL, id, id))objc_msgSend)(allocated, @selector(initWithIdentifier:serviceBundleName:), @"VPhoneAXClient", @"VoiceOver");
                }
            }
            if (gAXUIClient && [gAXUIClient respondsToSelector:@selector(setDelegate:)]) {
                ((void (*)(id, SEL, id))objc_msgSend)(gAXUIClient, @selector(setDelegate:), gDelegate);
            }
            if (gAXUIClient) {
                VPAXSend(gAXUIClient, @{@"register": @YES}, 25);
                VPAXSend(gAXUIClient, @{}, 8);
                VPAXSend(gAXUIClient, @{@"enabled": @NO}, 7);
            }
        }
        [result addEntriesFromDictionary:VPhoneAXRuntimeStatus()];
        result[@"ok"] = @([workspace[@"ok"] boolValue] && gRuntime.axRuntimeHandle != NULL);
    };
    if ([NSThread isMainThread]) work(); else dispatch_sync(dispatch_get_main_queue(), work);
    return result;
}
