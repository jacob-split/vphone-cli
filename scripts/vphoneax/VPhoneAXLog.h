#pragma once
#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSString *const VPhoneAXStateDirectory;
FOUNDATION_EXPORT NSString *const VPhoneAXLogPath;
void VPAXLog(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);
