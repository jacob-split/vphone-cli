#import "VPhoneAXBroker.h"
#import <Foundation/Foundation.h>

static BOOL VPAXIsSpringBoard(void) {
    NSString *name = NSProcessInfo.processInfo.processName;
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
    return [name isEqualToString:@"SpringBoard"] || [bundle isEqualToString:@"com.apple.springboard"];
}

__attribute__((constructor)) static void VPhoneAXInit(void) {
    @autoreleasepool {
        if (!VPAXIsSpringBoard()) return;
        NSLog(@"[VPhoneAX] loaded into SpringBoard pid=%d", getpid());
        const int delaysMs[] = {500, 2000, 5000, 10000, 20000};
        for (size_t i = 0; i < sizeof(delaysMs)/sizeof(delaysMs[0]); i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)delaysMs[i] * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                [[VPhoneAXBroker sharedBroker] start];
            });
        }
    }
}
