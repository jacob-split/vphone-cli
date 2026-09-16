#import "vendor/ios-mcp/MCPLogger.h"

@implementation MCPLogger
+ (BOOL)isDebugLoggingEnabled { return NO; }
+ (NSString *)logDirectoryPath { return @"/var/mobile/Library/VPhoneAX"; }
+ (NSString *)logFilePath { return [[self logDirectoryPath] stringByAppendingPathComponent:@"vphoneax.log"]; }
+ (NSString *)previousLogFilePath { return [[self logDirectoryPath] stringByAppendingPathComponent:@"vphoneax.previous.log"]; }
+ (NSArray<NSString *> *)allLogFilePaths { return @[[self logFilePath], [self previousLogFilePath]]; }
+ (NSString *)lastLogError { return nil; }
+ (void)log:(NSString *)format, ... {
    va_list args; va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args); NSLog(@"[VPhoneAX] %@", message);
}
+ (void)logMessage:(NSString *)message { NSLog(@"[VPhoneAX] %@", message ?: @""); }
+ (BOOL)clearLogsWithError:(NSError **)error { if (error) *error = nil; return YES; }
@end
