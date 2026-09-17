#import "VPhoneAXLog.h"
#import <fcntl.h>
#import <stdarg.h>
#import <unistd.h>

NSString *const VPhoneAXStateDirectory = @"/var/mobile/Library/VPhoneAX";
NSString *const VPhoneAXLogPath = @"/var/mobile/Library/VPhoneAX/vphoneax.log";

void VPAXLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!message.length) return;

    NSError *mkdirError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:VPhoneAXStateDirectory
                              withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions:@0770}
                                                    error:&mkdirError];
    NSString *line = [NSString stringWithFormat:@"%@ [VPhoneAX] %@\n", NSDate.date, message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    int fd = open(VPhoneAXLogPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        (void)write(fd, data.bytes, data.length);
        close(fd);
    }
    NSLog(@"[VPhoneAX] %@", message);
    if (mkdirError) NSLog(@"[VPhoneAX] state-dir error: %@", mkdirError);
}
