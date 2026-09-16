#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface VPhoneAXBroker : NSObject
+ (instancetype)sharedBroker;
- (void)start;
- (void)stop;
@end
NS_ASSUME_NONNULL_END
