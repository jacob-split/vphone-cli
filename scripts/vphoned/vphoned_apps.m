/*
 * vphoned_apps — App lifecycle management via private APIs.
 *
 * Uses LSApplicationWorkspace (CoreServices) and FBSSystemService
 * (FrontBoardServices).
 */

#import "vphoned_apps.h"
#import "vphoned_accessibility.h"
#import "vphoned_protocol.h"
#include <dlfcn.h>
#include <errno.h>
#include <objc/message.h>
#include <signal.h>
#include <unistd.h>

// MARK: - Private API Declarations

@interface LSApplicationProxy : NSObject
@property(readonly) NSString *bundleIdentifier;
@property(readonly) NSString *localizedName;
@property(readonly) NSString *shortVersionString;
@property(readonly) NSString *applicationType;
@property(readonly) NSURL *bundleURL;
@property(readonly) NSURL *dataContainerURL;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allInstalledApplications;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleID;
@end

// FBSSystemService loaded via dlsym
static Class gFBSSystemServiceClass = Nil;

static BOOL gAppsLoaded = NO;

BOOL vp_apps_load(void) {
  if (gAppsLoaded) return YES;
  // FrontBoardServices
  void *fbs = dlopen("/System/Library/PrivateFrameworks/"
                     "FrontBoardServices.framework/FrontBoardServices",
                     RTLD_LAZY);
  if (fbs) {
    gFBSSystemServiceClass = NSClassFromString(@"FBSSystemService");
    if (!gFBSSystemServiceClass) {
      NSLog(@"vphoned: FBSSystemService class not found");
    }
  } else {
    NSLog(@"vphoned: dlopen FrontBoardServices failed: %s", dlerror());
  }

  // LSApplicationWorkspace is in CoreServices (already linked)
  Class lsClass = NSClassFromString(@"LSApplicationWorkspace");
  if (!lsClass) {
    NSLog(@"vphoned: LSApplicationWorkspace class not found");
    return NO;
  }

  gAppsLoaded = YES;
  NSLog(@"vphoned: apps loaded (FBS=%s)",
        gFBSSystemServiceClass ? "yes" : "no");
  return YES;
}

// MARK: - Helpers

static pid_t pid_for_app(NSString *bundleID) {
  if (!gFBSSystemServiceClass)
    return 0;
  id service = ((id (*)(Class, SEL))objc_msgSend)(
      gFBSSystemServiceClass, sel_registerName("sharedService"));
  if (!service)
    return 0;
  return ((pid_t (*)(id, SEL, id))objc_msgSend)(
      service, sel_registerName("pidForApplication:"), bundleID);
}

static NSString *state_for_pid(pid_t pid) {
  if (pid > 0)
    return @"running";
  return @"not_running";
}

typedef pid_t (*AXFrontBoardFocusedAppPIDFunc)(void);
typedef CFTypeRef (*AXFrontBoardCopyObjectFunc)(void);

static BOOL vp_pid_is_live(pid_t pid) {
  if (pid <= 0 || pid > 1000000) return NO;
  if (kill(pid, 0) == 0) return YES;
  return errno == EPERM;
}

static pid_t vp_pid_from_ax_collection(id value) {
  if ([value isKindOfClass:[NSNumber class]]) {
    pid_t pid = (pid_t)[(NSNumber *)value intValue];
    return vp_pid_is_live(pid) ? pid : 0;
  }
  NSArray *items = nil;
  if ([value isKindOfClass:[NSArray class]]) items = value;
  else if ([value isKindOfClass:[NSSet class]]) items = [(NSSet *)value allObjects];
  else if ([value respondsToSelector:@selector(allObjects)]) items = [value allObjects];
  for (id item in items ?: @[]) {
    pid_t pid = vp_pid_from_ax_collection(item);
    if (pid > 0) return pid;
  }
  return 0;
}

static pid_t foreground_app_pid(void) {
  static AXFrontBoardFocusedAppPIDFunc focusedPID = NULL;
  static AXFrontBoardCopyObjectFunc focusedPIDs = NULL;
  static AXFrontBoardCopyObjectFunc focusedPIDsIgnoringSiri = NULL;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    void *handle = dlopen("/System/Library/PrivateFrameworks/AXFrontBoardUtils.framework/AXFrontBoardUtils",
                         RTLD_LAZY | RTLD_GLOBAL);
    if (handle) {
      focusedPID = (AXFrontBoardFocusedAppPIDFunc)dlsym(handle, "AXFrontBoardFocusedAppPID");
      focusedPIDs = (AXFrontBoardCopyObjectFunc)dlsym(handle, "AXFrontBoardFocusedAppPIDs");
      focusedPIDsIgnoringSiri = (AXFrontBoardCopyObjectFunc)dlsym(handle, "AXFrontBoardFocusedAppPIDsIgnoringSiri");
    }
  });

  // The singular symbol has returned ABI-garbage on the iOS 27 hybrid guest.
  // Prefer the collection APIs and validate every candidate against the live PID table.
  AXFrontBoardCopyObjectFunc collectionFns[] = {focusedPIDsIgnoringSiri, focusedPIDs};
  for (size_t i = 0; i < sizeof(collectionFns) / sizeof(collectionFns[0]); i++) {
    AXFrontBoardCopyObjectFunc fn = collectionFns[i];
    if (!fn) continue;
    CFTypeRef raw = fn();
    if (!raw) continue;
    pid_t pid = vp_pid_from_ax_collection((__bridge id)raw);
    if (pid > 0) return pid;
  }
  if (focusedPID) {
    pid_t pid = focusedPID();
    if (vp_pid_is_live(pid)) return pid;
  }
  return 0;
}

// MARK: - Command Handler

NSDictionary *vp_handle_apps_command(NSDictionary *msg) {
  NSString *type = msg[@"t"];
  id reqId = msg[@"id"];

  if (!gAppsLoaded && !vp_apps_load()) {
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = @"apps not available";
    return r;
  }

  // -- app_list --
  if ([type isEqualToString:@"app_list"]) {
    LSApplicationWorkspace *ws = [LSApplicationWorkspace defaultWorkspace];
    NSArray *allApps = [ws allInstalledApplications];
    NSString *filter = msg[@"filter"] ?: @"all";

    NSMutableArray *result = [NSMutableArray array];
    for (LSApplicationProxy *proxy in allApps) {
      NSString *appType = proxy.applicationType;
      BOOL isSystem = [appType isEqualToString:@"System"];

      if ([filter isEqualToString:@"user"] && isSystem)
        continue;
      if ([filter isEqualToString:@"system"] && !isSystem)
        continue;

      pid_t pid = pid_for_app(proxy.bundleIdentifier);

      if ([filter isEqualToString:@"running"] && pid <= 0)
        continue;

      [result addObject:@{
        @"bundle_id" : proxy.bundleIdentifier ?: @"",
        @"name" : proxy.localizedName ?: @"",
        @"version" : proxy.shortVersionString ?: @"",
        @"type" : isSystem ? @"system" : @"user",
        @"state" : state_for_pid(pid),
        @"pid" : @(pid > 0 ? pid : 0),
        @"path" : proxy.bundleURL.path ?: @"",
        @"data_container" : proxy.dataContainerURL.path ?: @"",
      }];
    }

    NSMutableDictionary *r = vp_make_response(@"app_list", reqId);
    r[@"apps"] = result;
    return r;
  }

  // -- app_foreground --
  if ([type isEqualToString:@"app_foreground"]) {
    NSDictionary *semanticContext = vp_accessibility_frontmost_context();
    if ([semanticContext isKindOfClass:[NSDictionary class]]) {
      pid_t semanticPID = (pid_t)[semanticContext[@"pid"] intValue];
      NSString *bundleID = [semanticContext[@"bundleId"] isKindOfClass:[NSString class]] ? semanticContext[@"bundleId"] : nil;
      NSString *name = [semanticContext[@"name"] isKindOfClass:[NSString class]] ? semanticContext[@"name"] : nil;
      if (semanticPID > 0 && bundleID.length > 0) {
        NSMutableDictionary *r = vp_make_response(@"app_foreground", reqId);
        r[@"pid"] = @(semanticPID);
        r[@"bundle_id"] = bundleID;
        r[@"name"] = name ?: @"";
        r[@"source"] = @"semantic_frontmost_context";
        r[@"ok"] = @YES;
        return r;
      }
    }

    pid_t foregroundPID = foreground_app_pid();
    LSApplicationWorkspace *ws = [LSApplicationWorkspace defaultWorkspace];
    LSApplicationProxy *matched = nil;
    for (LSApplicationProxy *proxy in [ws allInstalledApplications]) {
      if (foregroundPID > 0 && pid_for_app(proxy.bundleIdentifier) == foregroundPID) {
        matched = proxy;
        break;
      }
    }
    NSMutableDictionary *r = vp_make_response(@"app_foreground", reqId);
    r[@"pid"] = @(foregroundPID > 0 ? foregroundPID : 0);
    r[@"bundle_id"] = matched.bundleIdentifier ?: (foregroundPID > 0 ? @"" : @"com.apple.springboard");
    r[@"name"] = matched.localizedName ?: (foregroundPID > 0 ? @"" : @"SpringBoard");
    r[@"ok"] = @(foregroundPID > 0 || matched != nil);
    return r;
  }

  // -- app_launch --
  if ([type isEqualToString:@"app_launch"]) {
    NSString *bundleID = msg[@"bundle_id"];
    if (!bundleID) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] = @"missing bundle_id";
      return r;
    }

    LSApplicationWorkspace *ws = [LSApplicationWorkspace defaultWorkspace];
    NSString *url = msg[@"url"];

    BOOL ok;
    if (url) {
      // Open URL (which will launch the handling app)
      NSURL *nsurl = [NSURL URLWithString:url];
      // Try openURL:withOptions: if available
      SEL openURLSel = sel_registerName("openURL:withOptions:");
      if ([ws respondsToSelector:openURLSel]) {
        ok = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(ws, openURLSel, nsurl,
                                                       nil);
      } else {
        ok = [ws openApplicationWithBundleID:bundleID];
      }
    } else {
      ok = [ws openApplicationWithBundleID:bundleID];
    }

    if (!ok) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] = [NSString stringWithFormat:@"failed to launch %@", bundleID];
      return r;
    }

    // Brief wait for app to start
    usleep(500000); // 500ms

    pid_t pid = pid_for_app(bundleID);
    NSMutableDictionary *r = vp_make_response(@"app_launch", reqId);
    r[@"ok"] = @YES;
    r[@"pid"] = @(pid > 0 ? pid : 0);
    return r;
  }

  // -- app_terminate --
  if ([type isEqualToString:@"app_terminate"]) {
    NSString *bundleID = msg[@"bundle_id"];
    if (!bundleID) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] = @"missing bundle_id";
      return r;
    }

    if (gFBSSystemServiceClass) {
      id service = ((id (*)(Class, SEL))objc_msgSend)(
          gFBSSystemServiceClass, sel_registerName("sharedService"));
      if (service) {
        // terminateApplication:forReason:andReport:withDescription:
        // reason 5 = user requested, report NO
        ((void (*)(id, SEL, id, int, BOOL, id))objc_msgSend)(
            service,
            sel_registerName(
                "terminateApplication:forReason:andReport:withDescription:"),
            bundleID, 5, NO, @"vphoned terminate request");
      }
    } else {
      // Fallback: kill by PID
      pid_t pid = pid_for_app(bundleID);
      if (pid > 0)
        kill(pid, SIGTERM);
    }

    NSMutableDictionary *r = vp_make_response(@"app_terminate", reqId);
    r[@"ok"] = @YES;
    return r;
  }

  NSMutableDictionary *r = vp_make_response(@"err", reqId);
  r[@"msg"] = [NSString stringWithFormat:@"unknown apps command: %@", type];
  return r;
}
