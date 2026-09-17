#import "VPhoneAXBroker.h"
#import "VPhoneAXRuntime.h"
#import "VPhoneAXLog.h"
#import "vendor/ios-mcp/MCPAXAttributeBridge.h"
#import "vendor/ios-mcp/MCPAXNodeSource.h"
#import "vendor/ios-mcp/MCPAXQueryContext.h"
#import "vendor/ios-mcp/MCPAXRemoteContextResolver.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <arpa/inet.h>
#import <errno.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <unistd.h>
#import <float.h>

static NSString *const VPAXSocketPath = @"/var/mobile/Library/VPhoneAX/vphone-ax.sock";
static const uint32_t VPAXMaxMessageBytes = 16 * 1024 * 1024;


static id VPAXSendObject(id target, SEL sel) {
    if (!target || !sel || ![target respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, sel);
}

static NSNumber *VPAXSendBool(id target, SEL sel) {
    if (!target || !sel || ![target respondsToSelector:sel]) return nil;
    BOOL value = ((BOOL (*)(id, SEL))objc_msgSend)(target, sel);
    return @(value);
}

static NSNumber *VPAXSpringBoardLocked(void) {
    Class managerClass = NSClassFromString(@"SBLockScreenManager");
    id manager = VPAXSendObject(managerClass, NSSelectorFromString(@"sharedInstance"));
    return VPAXSendBool(manager, NSSelectorFromString(@"isUILocked"));
}

static NSString *VPAXString(id value);

static NSString *VPAXObjectStringSelector(id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!object || ![object respondsToSelector:selector]) return nil;
    id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
    if ([value isKindOfClass:[NSString class]]) return value;
    return value ? [value description] : nil;
}

static NSDictionary *VPAXPressVisibleAXElementForNode(NSDictionary *node) {
    Class elementClass = NSClassFromString(@"AXElement");
    SEL primarySel = NSSelectorFromString(@"primaryApp");
    if (!elementClass || ![elementClass respondsToSelector:primarySel]) {
        return @{ @"ok": @NO, @"error": @"AXElement.primaryApp unavailable" };
    }
    id app = ((id (*)(id, SEL))objc_msgSend)(elementClass, primarySel);
    SEL explorerSel = NSSelectorFromString(@"explorerElements");
    if (!app || ![app respondsToSelector:explorerSel]) {
        return @{ @"ok": @NO, @"error": @"AXElement primary app has no explorerElements" };
    }
    id elements = ((id (*)(id, SEL))objc_msgSend)(app, explorerSel);
    if (!elements || ![elements respondsToSelector:@selector(count)] ||
        ![elements respondsToSelector:@selector(objectAtIndex:)]) {
        return @{ @"ok": @NO, @"error": @"AXElement explorerElements unavailable" };
    }

    NSString *targetText = VPAXString(node[@"text"]);
    NSString *targetIdentifier = VPAXString(node[@"identifier"]);
    NSArray *targetAliases = [node[@"aliases"] isKindOfClass:[NSArray class]] ? node[@"aliases"] : @[];
    NSMutableArray *matches = [NSMutableArray array];
    NSUInteger count = ((NSUInteger (*)(id, SEL))objc_msgSend)(elements, @selector(count));
    for (NSUInteger i = 0; i < count; i++) {
        id candidate = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(elements, @selector(objectAtIndex:), i);
        if (!candidate) continue;
        NSString *label = VPAXObjectStringSelector(candidate, @"label");
        NSString *value = VPAXObjectStringSelector(candidate, @"value");
        NSString *identifier = VPAXObjectStringSelector(candidate, @"identifier");
        BOOL textMatch = targetText.length > 0 &&
            ((label && [label isEqualToString:targetText]) || (value && [value isEqualToString:targetText]));
        BOOL aliasMatch = NO;
        for (id aliasValue in targetAliases) {
            NSString *alias = VPAXString(aliasValue);
            if (alias.length > 0 && ((label && [label isEqualToString:alias]) ||
                                     (value && [value isEqualToString:alias]))) {
                aliasMatch = YES;
                break;
            }
        }
        BOOL identifierMatch = targetIdentifier.length > 0 && identifier && [identifier isEqualToString:targetIdentifier];
        if (identifierMatch || textMatch || aliasMatch) {
            [matches addObject:candidate];
        }
    }
    if (matches.count != 1) {
        return @{ @"ok": @NO, @"error": matches.count == 0 ? @"AXElement wrapper not found" : @"AXElement wrapper ambiguous",
                  @"match_count": @(matches.count), @"explorer_count": @(count) };
    }

    id target = matches.firstObject;
    SEL scrollSel = NSSelectorFromString(@"scrollToVisible");
    if ([target respondsToSelector:scrollSel]) {
        @try { ((void (*)(id, SEL))objc_msgSend)(target, scrollSel); } @catch (__unused NSException *e) {}
    }
    SEL pressSel = NSSelectorFromString(@"press");
    if (![target respondsToSelector:pressSel]) {
        return @{ @"ok": @NO, @"error": @"matched AXElement has no press selector",
                  @"wrapper_class": NSStringFromClass([target class]) ?: @"" };
    }
    @try {
        ((void (*)(id, SEL))objc_msgSend)(target, pressSel);
    } @catch (NSException *exception) {
        return @{ @"ok": @NO, @"error": exception.reason ?: exception.name ?: @"AXElement press exception",
                  @"wrapper_class": NSStringFromClass([target class]) ?: @"" };
    }
    return @{ @"ok": @YES, @"action": @"press", @"injection": @"ax_element_wrapper_press",
              @"wrapper_class": NSStringFromClass([target class]) ?: @"", @"explorer_count": @(count) };
}

static NSDictionary *VPAXTypeVisibleAXElementForNode(NSDictionary *node, NSString *text) {
    Class elementClass = NSClassFromString(@"AXElement");
    SEL primarySel = NSSelectorFromString(@"primaryApp");
    if (!elementClass || ![elementClass respondsToSelector:primarySel]) {
        return @{ @"ok": @NO, @"error": @"AXElement.primaryApp unavailable" };
    }
    id app = ((id (*)(id, SEL))objc_msgSend)(elementClass, primarySel);
    SEL explorerSel = NSSelectorFromString(@"explorerElements");
    if (!app || ![app respondsToSelector:explorerSel]) {
        return @{ @"ok": @NO, @"error": @"AXElement primary app has no explorerElements" };
    }
    id elements = ((id (*)(id, SEL))objc_msgSend)(app, explorerSel);
    if (!elements || ![elements respondsToSelector:@selector(count)] ||
        ![elements respondsToSelector:@selector(objectAtIndex:)]) {
        return @{ @"ok": @NO, @"error": @"AXElement explorerElements unavailable" };
    }

    NSString *targetText = VPAXString(node[@"text"]);
    NSString *targetIdentifier = VPAXString(node[@"identifier"]);
    NSArray *targetAliases = [node[@"aliases"] isKindOfClass:[NSArray class]] ? node[@"aliases"] : @[];
    NSMutableArray *matches = [NSMutableArray array];
    NSUInteger count = ((NSUInteger (*)(id, SEL))objc_msgSend)(elements, @selector(count));
    for (NSUInteger i = 0; i < count; i++) {
        id candidate = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(elements, @selector(objectAtIndex:), i);
        if (!candidate) continue;
        NSString *label = VPAXObjectStringSelector(candidate, @"label");
        NSString *value = VPAXObjectStringSelector(candidate, @"value");
        NSString *identifier = VPAXObjectStringSelector(candidate, @"identifier");
        BOOL textMatch = targetText.length > 0 &&
            ((label && [label isEqualToString:targetText]) || (value && [value isEqualToString:targetText]));
        BOOL aliasMatch = NO;
        for (id aliasValue in targetAliases) {
            NSString *alias = VPAXString(aliasValue);
            if (alias.length > 0 && ((label && [label isEqualToString:alias]) ||
                                     (value && [value isEqualToString:alias]))) {
                aliasMatch = YES;
                break;
            }
        }
        BOOL identifierMatch = targetIdentifier.length > 0 && identifier && [identifier isEqualToString:targetIdentifier];
        if (identifierMatch || textMatch || aliasMatch) [matches addObject:candidate];
    }
    if (matches.count != 1) {
        return @{ @"ok": @NO,
                  @"error": matches.count == 0 ? @"AXElement wrapper not found" : @"AXElement wrapper ambiguous",
                  @"match_count": @(matches.count), @"explorer_count": @(count) };
    }

    id target = matches.firstObject;
    SEL pressSel = NSSelectorFromString(@"press");
    SEL insertSel = NSSelectorFromString(@"insertText:");
    if (![target respondsToSelector:insertSel]) {
        return @{ @"ok": @NO, @"error": @"matched AXElement has no insertText: selector",
                  @"wrapper_class": NSStringFromClass([target class]) ?: @"" };
    }
    @try {
        if ([target respondsToSelector:pressSel]) {
            ((void (*)(id, SEL))objc_msgSend)(target, pressSel);
            usleep(120000);
        }
        ((void (*)(id, SEL, id))objc_msgSend)(target, insertSel, text ?: @"");
    } @catch (NSException *exception) {
        return @{ @"ok": @NO, @"error": exception.reason ?: exception.name ?: @"AXElement insertText exception",
                  @"wrapper_class": NSStringFromClass([target class]) ?: @"" };
    }
    return @{ @"ok": @YES, @"action": @"type", @"injection": @"ax_element_wrapper_insert_text",
              @"characters": @((text ?: @"").length),
              @"wrapper_class": NSStringFromClass([target class]) ?: @"", @"explorer_count": @(count) };
}

static NSDictionary *VPAXWakeInteractiveDisplay(void) {
    __block NSMutableDictionary *result = [NSMutableDictionary dictionary];
    void (^work)(void) = ^{
        @try {
            // Modern SpringBoard backlight controller.
            Class backlightClass = NSClassFromString(@"SBBacklightController");
            id backlight = VPAXSendObject(backlightClass, NSSelectorFromString(@"sharedInstanceIfExists"));
            if (!backlight) backlight = VPAXSendObject(backlightClass, NSSelectorFromString(@"sharedInstance"));
            if (backlight) {
                NSNumber *before = VPAXSendBool(backlight, NSSelectorFromString(@"screenIsOn"));
                if (before) result[@"screen_on_before"] = before;
                SEL turnOn = NSSelectorFromString(@"turnOnScreenFullyWithBacklightSource:");
                if ([backlight respondsToSelector:turnOn]) {
                    ((void (*)(id, SEL, long long))objc_msgSend)(backlight, turnOn, 2LL);
                    result[@"backlight_turn_on"] = @YES;
                }
                SEL resetLock = NSSelectorFromString(@"resetLockScreenIdleTimer");
                if ([backlight respondsToSelector:resetLock]) {
                    ((void (*)(id, SEL))objc_msgSend)(backlight, resetLock);
                    result[@"backlight_idle_reset"] = @YES;
                }
            }

            // Long-lived SpringBoard HID wake path used across iOS generations.
            Class userAgentClass = NSClassFromString(@"SBUserAgent");
            id userAgent = VPAXSendObject(userAgentClass, NSSelectorFromString(@"sharedUserAgent"));
            SEL undim = NSSelectorFromString(@"undimScreen");
            if (userAgent && [userAgent respondsToSelector:undim]) {
                ((void (*)(id, SEL))objc_msgSend)(userAgent, undim);
                result[@"user_agent_undim"] = @YES;
            }

            id springBoard = UIApplication.sharedApplication;
            SEL resetUndim = NSSelectorFromString(@"resetIdleTimerAndUndim");
            if (springBoard && [springBoard respondsToSelector:resetUndim]) {
                ((void (*)(id, SEL))objc_msgSend)(springBoard, resetUndim);
                result[@"springboard_reset_undim"] = @YES;
            }

            if (backlight) {
                NSNumber *after = VPAXSendBool(backlight, NSSelectorFromString(@"screenIsOn"));
                if (after) result[@"screen_on_after"] = after;
            }
            result[@"ok"] = @YES;
        } @catch (NSException *exception) {
            result[@"ok"] = @NO;
            result[@"error"] = exception.reason ?: exception.name ?: @"wake_exception";
        }
    };
    if ([NSThread isMainThread]) work();
    else dispatch_sync(dispatch_get_main_queue(), work);
    return result;
}

static NSDictionary *VPAXAttemptUnlockStrategy(NSString *strategy, NSNumber *sourceValue) {
    __block NSMutableDictionary *result = [@{ @"ok": @NO } mutableCopy];
    void (^work)(void) = ^{
        @try {
            Class managerClass = NSClassFromString(@"SBLockScreenManager");
            id manager = VPAXSendObject(managerClass, NSSelectorFromString(@"sharedInstance"));
            if (!manager) {
                result[@"error"] = @"lock_screen_manager_unavailable";
                return;
            }
            NSNumber *before = VPAXSendBool(manager, NSSelectorFromString(@"isUILocked"));
            if (before) result[@"locked_before"] = before;
            id cover = VPAXSendObject(manager, NSSelectorFromString(@"coverSheetViewController"));
            if (before && !before.boolValue) {
                // A cold-boot worker can report unlocked while SpringBoard is still
                // frontmost and the interactive display is dim/asleep. Normalize
                // the presentation and wake state instead of treating the lock bit
                // alone as sufficient proof that the UI is usable.
                id presentation = VPAXSendObject(manager, NSSelectorFromString(@"coverSheetPresentationManager"));
                SEL hideSel = NSSelectorFromString(@"setCoverSheetPresented:animated:withCompletion:");
                if (presentation && [presentation respondsToSelector:hideSel]) {
                    ((void (*)(id, SEL, BOOL, BOOL, id))objc_msgSend)(presentation, hideSel, NO, NO, nil);
                    result[@"cover_sheet_hide_requested"] = @YES;
                }
                result[@"display_wake"] = VPAXWakeInteractiveDisplay();
                result[@"ok"] = @YES;
                result[@"changed"] = @NO;
                result[@"locked_after"] = @NO;
                result[@"method"] = @"normalizeUnlockedUI + dismissCoverSheet + wakeDisplay";
                return;
            }

            NSNumber *authenticated = VPAXSendBool(cover, NSSelectorFromString(@"isAuthenticated"));
            if (authenticated) result[@"authenticated"] = authenticated;
            if (authenticated && !authenticated.boolValue) {
                result[@"error"] = @"authentication_required";
                return;
            }

            int source = sourceValue ? sourceValue.intValue : 0;
            result[@"strategy"] = strategy ?: @"manager";
            result[@"source"] = @(source);

            if ([strategy isEqualToString:@"manager"]) {
                SEL sel = NSSelectorFromString(@"unlockUIFromSource:withOptions:");
                if (![manager respondsToSelector:sel]) { result[@"error"] = @"manager_unlock_unavailable"; return; }
                ((void (*)(id, SEL, int, id))objc_msgSend)(manager, sel, source, nil);
                result[@"method"] = @"unlockUIFromSource:withOptions:";
            } else if ([strategy isEqualToString:@"start"]) {
                SEL sel = NSSelectorFromString(@"startUIUnlockFromSource:withOptions:");
                if (![manager respondsToSelector:sel]) { result[@"error"] = @"manager_start_unlock_unavailable"; return; }
                ((void (*)(id, SEL, int, id))objc_msgSend)(manager, sel, source, nil);
                result[@"method"] = @"startUIUnlockFromSource:withOptions:";
            } else if ([strategy isEqualToString:@"start_finish"]) {
                SEL startSel = NSSelectorFromString(@"startUIUnlockFromSource:withOptions:");
                SEL finishSel = NSSelectorFromString(@"_finishUIUnlockFromSource:withOptions:");
                if (![manager respondsToSelector:startSel] || ![manager respondsToSelector:finishSel]) {
                    result[@"error"] = @"manager_start_finish_unavailable"; return;
                }
                ((void (*)(id, SEL, int, id))objc_msgSend)(manager, startSel, source, nil);
                BOOL finished = ((BOOL (*)(id, SEL, int, id))objc_msgSend)(manager, finishSel, source, nil);
                result[@"finish_return"] = @(finished);

                // The lock manager can clear isUILocked before the Cover Sheet
                // presentation actually leaves the display. Explicitly dismiss it
                // as part of the same main-thread unlock transaction so foreground
                // app input is not intercepted by a visually stale lock screen.
                id presentation = VPAXSendObject(manager, NSSelectorFromString(@"coverSheetPresentationManager"));
                SEL hideSel = NSSelectorFromString(@"setCoverSheetPresented:animated:withCompletion:");
                if (presentation && [presentation respondsToSelector:hideSel]) {
                    ((void (*)(id, SEL, BOOL, BOOL, id))objc_msgSend)(presentation, hideSel, NO, NO, nil);
                    result[@"cover_sheet_hide_requested"] = @YES;
                } else {
                    result[@"cover_sheet_hide_requested"] = @NO;
                }
                result[@"display_wake"] = VPAXWakeInteractiveDisplay();
                result[@"method"] = @"startUIUnlock + _finishUIUnlock + dismissCoverSheet + wakeDisplay";
            } else if ([strategy isEqualToString:@"cover_respond"]) {
                SEL sel = NSSelectorFromString(@"respondToUIUnlockFromSource:");
                if (!cover || ![cover respondsToSelector:sel]) { result[@"error"] = @"cover_respond_unavailable"; return; }
                ((void (*)(id, SEL, int))objc_msgSend)(cover, sel, source);
                result[@"method"] = @"respondToUIUnlockFromSource:";
            } else if ([strategy isEqualToString:@"cover_finish"]) {
                SEL prepare = NSSelectorFromString(@"prepareForUIUnlock");
                SEL finish = NSSelectorFromString(@"finishUIUnlockFromSource:");
                if (!cover || ![cover respondsToSelector:finish]) { result[@"error"] = @"cover_finish_unavailable"; return; }
                if ([cover respondsToSelector:prepare]) ((void (*)(id, SEL))objc_msgSend)(cover, prepare);
                ((void (*)(id, SEL, int))objc_msgSend)(cover, finish, source);
                result[@"method"] = @"prepareForUIUnlock + finishUIUnlockFromSource:";
            } else if ([strategy isEqualToString:@"presentation_request"]) {
                id presentation = VPAXSendObject(manager, NSSelectorFromString(@"coverSheetPresentationManager"));
                SEL sel = NSSelectorFromString(@"_notifyDelegateRequestsUnlock");
                if (!presentation || ![presentation respondsToSelector:sel]) { result[@"error"] = @"presentation_request_unavailable"; return; }
                ((void (*)(id, SEL))objc_msgSend)(presentation, sel);
                result[@"method"] = @"_notifyDelegateRequestsUnlock";
            } else if ([strategy isEqualToString:@"presentation_hide"]) {
                id presentation = VPAXSendObject(manager, NSSelectorFromString(@"coverSheetPresentationManager"));
                SEL sel = NSSelectorFromString(@"setCoverSheetPresented:animated:withCompletion:");
                if (!presentation || ![presentation respondsToSelector:sel]) { result[@"error"] = @"presentation_hide_unavailable"; return; }
                ((void (*)(id, SEL, BOOL, BOOL, id))objc_msgSend)(presentation, sel, NO, NO, nil);
                result[@"method"] = @"setCoverSheetPresented:animated:withCompletion:";
            } else if ([strategy isEqualToString:@"passcode_empty"]) {
                SEL sel = NSSelectorFromString(@"attemptUnlockWithPasscode:finishUIUnlock:completion:");
                if (![manager respondsToSelector:sel]) { result[@"error"] = @"passcode_unlock_unavailable"; return; }
                ((void (*)(id, SEL, id, BOOL, id))objc_msgSend)(manager, sel, @"", YES, nil);
                result[@"method"] = @"attemptUnlockWithPasscode:finishUIUnlock:completion:";
            } else {
                result[@"error"] = @"unknown_unlock_strategy";
                return;
            }
            result[@"ok"] = @YES;
            result[@"changed"] = @YES;
        } @catch (NSException *exception) {
            result[@"error"] = exception.reason ?: exception.name ?: @"unlock_exception";
            result[@"exception"] = exception.name ?: @"NSException";
        }
    };
    if ([NSThread isMainThread]) work();
    else dispatch_sync(dispatch_get_main_queue(), work);
    return result;
}

static NSArray<NSString *> *VPAXMethodNamesForClass(NSString *name) {
    Class cls = NSClassFromString(name);
    if (!cls) return @[];
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        NSString *sel = NSStringFromSelector(method_getName(methods[i]));
        NSString *lower = sel.lowercaseString;
        if ([lower containsString:@"lock"] || [lower containsString:@"unlock"] ||
            [lower containsString:@"dismiss"] || [lower containsString:@"cover"] ||
            [lower containsString:@"auth"] || [lower containsString:@"passcode"]) {
            [names addObject:sel];
        }
    }
    free(methods);
    [names sortUsingSelector:@selector(compare:)];
    return names;
}

static NSDictionary *VPAXDebugMethodSignatures(void) {
    NSDictionary<NSString *, NSArray<NSString *> *> *targets = @{
        @"SBLockScreenManager": @[
            @"attemptUnlockWithPasscode:",
            @"attemptUnlockWithPasscode:finishUIUnlock:completion:",
            @"startUIUnlockFromSource:withOptions:",
            @"_finishUIUnlockFromSource:withOptions:",
            @"_finishUIUnlockFromSource:withOptions:completion:",
            @"setIsUILocked:", @"_setUILocked:", @"_reallySetUILocked:",
            @"isUILocked", @"isLockScreenActive", @"isLockScreenVisible", @"isUIUnlocking"
        ],
        @"CSCoverSheetViewController": @[
            @"prepareForUIUnlock", @"finishUIUnlockFromSource:",
            @"respondToUIUnlockFromSource:", @"isAuthenticated", @"setAuthenticated:",
            @"dismissed", @"_setDismissed:"
        ],
        @"SBCoverSheetPresentationManager": @[
            @"_isActiveLockScreen", @"_isEffectivelyLocked", @"hasBeenDismissedSinceBoot",
            @"setCoverSheetPresented:animated:withCompletion:",
            @"setCoverSheetTranslationToPresented:forcingTransition:ignoringPreflightRequirements:animated:"
        ]
    };
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSString *className in targets) {
        Class cls = NSClassFromString(className);
        if (!cls) continue;
        NSMutableDictionary *classOut = [NSMutableDictionary dictionary];
        for (NSString *selectorName in targets[className]) {
            Method method = class_getInstanceMethod(cls, NSSelectorFromString(selectorName));
            if (!method) continue;
            const char *types = method_getTypeEncoding(method);
            classOut[selectorName] = types ? [NSString stringWithUTF8String:types] : @"";
        }
        out[className] = classOut;
    }
    return out;
}

static NSDictionary *VPAXDebugLockState(void) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    Class managerClass = NSClassFromString(@"SBLockScreenManager");
    id manager = VPAXSendObject(managerClass, NSSelectorFromString(@"sharedInstance"));
    if (manager) {
        for (NSString *name in @[@"isUILocked", @"isLockScreenActive", @"isLockScreenVisible", @"isUIUnlocking", @"allowUILockUnlock"]) {
            NSNumber *value = VPAXSendBool(manager, NSSelectorFromString(name));
            if (value) out[name] = value;
        }
        id cover = VPAXSendObject(manager, NSSelectorFromString(@"coverSheetViewController"));
        if (cover) {
            NSMutableDictionary *coverState = [NSMutableDictionary dictionary];
            for (NSString *name in @[@"isAuthenticated", @"dismissed", @"isPasscodeLockVisible", @"phoneUnlockEnabledAndRequirementsMet", @"isUnlockDisabled"]) {
                NSNumber *value = VPAXSendBool(cover, NSSelectorFromString(name));
                if (value) coverState[name] = value;
            }
            coverState[@"class"] = NSStringFromClass([cover class]);
            out[@"coverSheet"] = coverState;
        }
    }
    return out;
}

static NSDictionary *VPAXDebugLockRuntime(void) {
    NSArray<NSString *> *targets = @[
        @"SBLockScreenManager", @"SBCoverSheetPresentationManager",
        @"SBMainWorkspace", @"SBDeviceLockController",
        @"CSCoverSheetViewController", @"SBDashBoardViewController"
    ];
    NSMutableDictionary *methods = [NSMutableDictionary dictionary];
    for (NSString *name in targets) {
        Class cls = NSClassFromString(name);
        if (cls) methods[name] = VPAXMethodNamesForClass(name);
    }
    int total = objc_getClassList(NULL, 0);
    __unsafe_unretained Class *classes = total > 0 ? (__unsafe_unretained Class *)malloc(sizeof(Class) * (size_t)total) : NULL;
    NSMutableArray<NSString *> *matching = [NSMutableArray array];
    if (classes) {
        int got = objc_getClassList(classes, total);
        for (int i = 0; i < got; i++) {
            NSString *name = NSStringFromClass(classes[i]);
            NSString *lower = name.lowercaseString;
            if ([lower containsString:@"lockscreen"] || [lower containsString:@"coversheet"] ||
                [lower containsString:@"devicelock"] || [lower containsString:@"unlock"]) {
                if (matching.count < 160) [matching addObject:name];
            }
        }
        free(classes);
    }
    [matching sortUsingSelector:@selector(compare:)];
    return @{ @"methods": methods, @"matching_classes": matching };
}

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

static BOOL VPAXPointOnScreen(NSDictionary *point) {
    if (![point isKindOfClass:[NSDictionary class]]) return NO;
    NSNumber *x=point[@"x"] ?: point[@"X"], *y=point[@"y"] ?: point[@"Y"];
    if (!x || !y) return NO;
    // AX occasionally emits the sentinel point (0,0) for a focused control after
    // its value changes. Treat that as unavailable rather than tapping top-left.
    if (x.doubleValue == 0.0 && y.doubleValue == 0.0) return NO;
    CGRect bounds=UIScreen.mainScreen.bounds;
    return x.doubleValue >= 0 && x.doubleValue <= CGRectGetWidth(bounds) &&
           y.doubleValue >= 0 && y.doubleValue <= CGRectGetHeight(bounds);
}


static NSString *VPAXNormalizedRole(NSDictionary *node) {
    NSNumber *automationType = [node[@"automation_type"] isKindOfClass:[NSNumber class]] ? node[@"automation_type"] : nil;
    if (automationType) {
        NSDictionary<NSNumber *, NSString *> *types = @{
            @9:@"button", @19:@"keyboard", @20:@"keyboard_key", @21:@"navigation_bar",
            @22:@"tab_bar", @26:@"table", @27:@"cell", @32:@"collection", @33:@"slider",
            @38:@"picker", @39:@"picker", @40:@"switch", @42:@"link", @43:@"image",
            @45:@"search_field", @46:@"scroll_view", @48:@"text", @49:@"text_field",
            @50:@"secure_text_field", @52:@"text_view", @58:@"web_view", @75:@"cell"
        };
        NSString *mapped = types[automationType];
        if (mapped) return mapped;
    }
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

    NSString *semanticText = VPAXString(node[@"text"]) ?: VPAXString(node[@"label"]) ?: VPAXString(node[@"placeholder"]) ?: @"";
    if ([semanticText rangeOfString:@"search field" options:NSCaseInsensitiveSearch].location != NSNotFound) return @"search_field";

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
@property(nonatomic) BOOL bootstrapInFlight;
@property(nonatomic) BOOL bootstrapComplete;
@property(nonatomic) uint64_t generation;
@property(nonatomic) BOOL semanticOperational;
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
        _bootstrap = @{@"state": @"not_started"};
        _bootstrapInFlight = NO;
        _bootstrapComplete = NO;
        _generation = 0;
        _semanticOperational = NO;
    }
    return self;
}

- (void)start {
    if (self.listenFD >= 0) return;
    NSString *dir = VPAXSocketPath.stringByDeletingLastPathComponent;
    NSError *dirError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions:@0770}
                                                    error:&dirError];
    if (dirError) VPAXLog(@"state directory error: %@", dirError);
    unlink(VPAXSocketPath.fileSystemRepresentation);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { VPAXLog(@"socket failed: %s", strerror(errno)); return; }
    struct sockaddr_un addr = {0}; addr.sun_family = AF_UNIX;
    strlcpy(addr.sun_path, VPAXSocketPath.fileSystemRepresentation, sizeof(addr.sun_path));
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 4) != 0) {
        VPAXLog(@"bind/listen failed: %s", strerror(errno)); close(fd); return;
    }
    chmod(VPAXSocketPath.fileSystemRepresentation, 0660);
    self.listenFD = fd;
    VPAXLog(@"broker listening on %@", VPAXSocketPath);
    dispatch_async(self.queue, ^{ [self acceptLoop]; });
    [self beginBootstrap:@"broker-start"];
}

- (void)beginBootstrap:(NSString *)reason {
    @synchronized (self) {
        if (self.bootstrapInFlight) {
            VPAXLog(@"bootstrap already in flight (%@)", reason ?: @"unknown");
            return;
        }
        self.bootstrapInFlight = YES;
        self.bootstrapComplete = NO;
        self.bootstrap = @{
            @"state": @"starting",
            @"reason": reason ?: @"unknown",
            @"started_at": @([[NSDate date] timeIntervalSince1970])
        };
    }
    VPAXLog(@"bootstrap begin (%@)", reason ?: @"unknown");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *result = nil;
        @try {
            result = VPhoneAXBootstrapRuntime();
        } @catch (NSException *exception) {
            result = @{
                @"ok": @NO, @"state": @"failed",
                @"exception": exception.name ?: @"NSException",
                @"reason": exception.reason ?: @"unknown"
            };
        }
        NSMutableDictionary *final = [result mutableCopy] ?: [NSMutableDictionary dictionary];
        BOOL ok = [final[@"ok"] boolValue];
        final[@"state"] = ok ? @"ready" : @"failed";
        final[@"finished_at"] = @([[NSDate date] timeIntervalSince1970]);
        @synchronized (self) {
            self.bootstrap = [final copy];
            self.bootstrapComplete = YES;
            self.bootstrapInFlight = NO;
        }
        VPAXLog(@"bootstrap finished state=%@", final[@"state"]);
    });
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
    NSDictionary *frame = VPAXFrame(source);
    NSDictionary *frameTap = VPTapForFrame(frame);
    NSDictionary *reportedTap = [source[@"tap"] isKindOfClass:[NSDictionary class]] ? source[@"tap"] : nil;
    NSDictionary *centerPoint = [source[@"center_point"] isKindOfClass:[NSDictionary class]] ? source[@"center_point"] : nil;
    NSDictionary *visiblePoint = [source[@"visible_point"] isKindOfClass:[NSDictionary class]] ? source[@"visible_point"] : nil;
    if (reportedTap && VPAXPointOnScreen(reportedTap)) {
        node[@"tap"] = reportedTap;
        node[@"tap_source"] = @"ax_reported_screen_point";
    } else if (centerPoint && VPAXPointOnScreen(centerPoint)) {
        node[@"tap"] = centerPoint;
        node[@"tap_source"] = @"ax_center_point";
    } else if (visiblePoint && VPAXPointOnScreen(visiblePoint)) {
        node[@"tap"] = visiblePoint;
        node[@"tap_source"] = @"ax_visible_point";
    } else if (frameTap) {
        node[@"tap"] = frameTap;
        node[@"tap_source"] = @"frame_center_fallback";
    }
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
        NSDictionary *bootstrap = nil; BOOL complete = NO; BOOL inFlight = NO;
        @synchronized (self) {
            bootstrap = self.bootstrap ?: @{@"state": @"not_started"};
            complete = self.bootstrapComplete;
            inFlight = self.bootstrapInFlight;
        }
        NSMutableDictionary *r=[@{
            @"ok": @YES, @"broker_ready": @(self.listenFD >= 0),
            @"bootstrap": bootstrap, @"bootstrap_complete": @(complete),
            @"bootstrap_in_flight": @(inFlight),
            @"semantic_operational": @(self.semanticOperational)
        } mutableCopy];
        r[@"_debug_lock_runtime"] = VPAXDebugLockRuntime();
        r[@"_debug_method_signatures"] = VPAXDebugMethodSignatures();
        r[@"_debug_lock_state"] = VPAXDebugLockState();
        if (complete) {
            r[@"runtime"] = VPhoneAXRuntimeStatus();
            @try {
                MCPAXQueryContext *ctx=[self context];
                if (ctx) r[@"frontmost_context"]=[ctx dictionaryRepresentation];
            } @catch (NSException *exception) {
                r[@"context_error"] = exception.reason ?: exception.name;
            }
        }
        return r;
    }
    if ([type isEqualToString:@"device_state"]) {
        Class axClass = NSClassFromString(@"AXElement");
        id systemWide = VPAXSendObject(axClass, NSSelectorFromString(@"systemWideElement"));
        NSMutableDictionary *r = [@{ @"ok": @YES } mutableCopy];
        // SBLockScreenManager's read-only lock bit is authoritative on this
        // virtualized build; AXElement.isScreenLocked is only retained as a hint.
        NSNumber *locked = VPAXSpringBoardLocked();
        if (locked) r[@"screen_locked"] = locked;
        NSNumber *axLocked = VPAXSendBool(systemWide, NSSelectorFromString(@"isScreenLocked"));
        if (axLocked) r[@"screen_locked_hint"] = axLocked;
        NSNumber *controlCenter = VPAXSendBool(systemWide, NSSelectorFromString(@"isControlCenterVisible"));
        if (controlCenter) r[@"control_center_visible"] = controlCenter;
        UIScreen *screen = UIScreen.mainScreen;
        if (screen) {
            CGRect b = screen.bounds;
            r[@"screen"] = @{
                @"width": @(CGRectGetWidth(b)), @"height": @(CGRectGetHeight(b)),
                @"scale": @(screen.scale), @"native_scale": @(screen.nativeScale)
            };
        }
        @try {
            MCPAXQueryContext *ctx=[self context];
            if (ctx) r[@"frontmost_context"]=[ctx dictionaryRepresentation];
        } @catch (NSException *exception) {
            r[@"context_error"] = exception.reason ?: exception.name;
        }
        r[@"semantic_operational"] = @(self.semanticOperational);
        return r;
    }
    if ([type isEqualToString:@"device_unlock"]) {
        NSString *strategy = [req[@"strategy"] isKindOfClass:[NSString class]] ? req[@"strategy"] : @"start_finish";
        NSNumber *source = [req[@"source"] isKindOfClass:[NSNumber class]] ? req[@"source"] : @0;
        NSMutableDictionary *r = [[VPAXAttemptUnlockStrategy(strategy, source) mutableCopy] ?: [NSMutableDictionary dictionary] mutableCopy];
        // Let SpringBoard finish the transition before reporting its authoritative state.
        usleep(350000);
        NSNumber *after = VPAXSpringBoardLocked();
        if (after) r[@"locked_after"] = after;
        if (after && !after.boolValue) {
            r[@"ok"] = @YES;
            r[@"changed"] = @YES;
        } else if ([r[@"ok"] boolValue]) {
            r[@"ok"] = @NO;
            r[@"error"] = @"unlock_transition_did_not_complete";
        }
        return r;
    }
    if ([type isEqualToString:@"bootstrap"]) {
        [self beginBootstrap:@"explicit-request"];
        NSDictionary *bootstrap = nil; BOOL complete = NO; BOOL inFlight = NO;
        @synchronized (self) {
            bootstrap = self.bootstrap ?: @{@"state": @"not_started"};
            complete = self.bootstrapComplete;
            inFlight = self.bootstrapInFlight;
        }
        return @{ @"ok": @YES, @"bootstrap": bootstrap,
                  @"bootstrap_complete": @(complete), @"bootstrap_in_flight": @(inFlight) };
    }
    MCPAXQueryContext *ctx=[self context]; if (!ctx || ctx.pid<=0) return @{ @"ok":@NO,@"error":@"no_frontmost_context" };
    if ([type isEqualToString:@"tree"]) {
        NSString *error=nil; NSDictionary *raw=[self treeForContext:ctx request:req error:&error];
        if (!raw) {
            [self beginBootstrap:@"tree-retry"];
            return @{ @"ok":@NO, @"error":error ?: @"tree_failed", @"bootstrap":self.bootstrap ?: @{} };
        }
        self.semanticOperational = YES;
        NSMutableDictionary *r=[[self semanticPayload:raw] mutableCopy]; r[@"ok"]=@YES; r[@"frontmost_context"]=[ctx dictionaryRepresentation]; return r;
    }
    if ([type isEqualToString:@"hit_test"]) {
        double x=[req[@"x"] doubleValue], y=[req[@"y"] doubleValue]; NSString *error=nil;
        NSDictionary *raw=[self.nodeSource elementAtPoint:CGPointMake(x,y) pid:ctx.pid contextId:ctx.contextId displayId:ctx.displayId allowParameterizedHitTest:YES error:&error];
        if (raw) {
            self.semanticOperational = YES;
            uint64_t gen=++self.generation;
            return @{ @"ok":@YES,@"node":[self semanticNode:raw path:@"hit" generation:gen],@"generation":@(gen),@"source":@"direct_ax_hit_test" };
        }

        // iOS's remote point hit-test can fail even when the compact AX tree has
        // exact visible geometry. Fall back to the smallest visible semantic
        // element containing the requested point; this is deterministic and uses
        // the same accessibility evidence returned to callers.
        NSMutableDictionary *query=[@{ @"mode":@"compact", @"max_elements":@1000,
                                       @"visible_only":@YES, @"clickable_only":@NO } mutableCopy];
        NSString *treeError=nil;
        NSDictionary *tree=[self treeForContext:ctx request:query error:&treeError];
        NSDictionary *semantic=tree ? [self semanticPayload:tree] : nil;
        NSDictionary *best=nil; double bestArea=DBL_MAX;
        for (NSDictionary *candidate in semantic[@"elements"]) {
            if (![candidate isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *rect=[candidate[@"visible_rect"] isKindOfClass:[NSDictionary class]] ? candidate[@"visible_rect"] : candidate[@"rect"];
            double rx=[rect[@"x"] doubleValue], ry=[rect[@"y"] doubleValue];
            double rw=[rect[@"width"] doubleValue], rh=[rect[@"height"] doubleValue];
            if (rw <= 0 || rh <= 0) continue;
            if (x >= rx && x <= rx+rw && y >= ry && y <= ry+rh) {
                double area=rw*rh;
                if (area < bestArea) { bestArea=area; best=candidate; }
            }
        }
        if (best) {
            self.semanticOperational = YES;
            return @{ @"ok":@YES, @"node":best, @"generation":semantic[@"generation"] ?: @0,
                      @"source":@"semantic_geometry_fallback" };
        }
        return @{ @"ok":@NO,@"error":treeError ?: error ?: @"hit_test_failed" };
    }
    if ([type isEqualToString:@"action"]) {
        NSDictionary *selector=[req[@"selector"] isKindOfClass:[NSDictionary class]] ? req[@"selector"] : @{};
        NSString *action=[(VPAXString(req[@"action"]) ?: @"tap") lowercaseString];
        if (![action isEqualToString:@"tap"] && ![action isEqualToString:@"press"] && ![action isEqualToString:@"type"]) {
            return @{ @"ok":@NO, @"error":[NSString stringWithFormat:@"unsupported action: %@", action] };
        }
        NSMutableDictionary *query=[req mutableCopy];
        query[@"mode"]=@"compact";
        query[@"max_elements"]=req[@"max_elements"] ?: @1000;
        query[@"visible_only"]=req[@"visible_only"] ?: @YES;
        NSString *error=nil;
        NSDictionary *raw=[self treeForContext:ctx request:query error:&error];
        NSDictionary *semantic=raw ? [self semanticPayload:raw] : nil;
        NSDictionary *found=semantic ? [self findInPayload:semantic selector:selector] : nil;
        if (!found || ![found[@"ok"] boolValue]) {
            return found ?: @{ @"ok":@NO, @"error":error ?: @"action_target_not_found" };
        }
        NSDictionary *node=[found[@"node"] isKindOfClass:[NSDictionary class]] ? found[@"node"] : nil;
        NSString *typeText = [action isEqualToString:@"type"] ? (VPAXString(req[@"text"]) ?: @"") : nil;
        NSDictionary *performed = node ? ([action isEqualToString:@"type"]
            ? VPAXTypeVisibleAXElementForNode(node, typeText)
            : VPAXPressVisibleAXElementForNode(node)) : nil;
        if (![action isEqualToString:@"type"] && (!performed || ![performed[@"ok"] boolValue])) {
            NSString *fallbackError=nil;
            NSDictionary *fallback=node ? [self.nodeSource performPressForCompactNode:node
                                                                                     pid:ctx.pid
                                                                                bundleId:ctx.bundleId
                                                                               contextId:ctx.contextId
                                                                               displayId:ctx.displayId
                                                                                   error:&fallbackError] : nil;
            if (fallback && [fallback[@"ok"] boolValue]) {
                performed=fallback;
            } else if (fallback) {
                NSMutableDictionary *combined=[fallback mutableCopy];
                combined[@"wrapper_attempt"]=performed ?: @{};
                performed=combined;
                if (fallbackError.length) error=fallbackError;
            }
        }
        if (!performed || ![performed[@"ok"] boolValue]) {
            NSMutableDictionary *failed=[found mutableCopy];
            failed[@"ok"]=@NO;
            failed[@"error"]=error ?: performed[@"error"] ?: @"ax_press_failed";
            if (performed) failed[@"action_result"]=performed;
            return failed;
        }
        self.semanticOperational = YES;
        NSMutableDictionary *result=[found mutableCopy];
        result[@"action"]=[action isEqualToString:@"type"] ? @"type" : @"tap";
        result[@"injection"]=performed[@"injection"] ?: @"ax_press";
        result[@"action_result"]=performed;
        return result;
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
    return @{ @"ok":@NO,@"error":[NSString stringWithFormat:@"unknown command: %@",type] };
}
@end
