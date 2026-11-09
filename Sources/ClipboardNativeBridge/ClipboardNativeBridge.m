#import "ClipboardNativeBridge.h"
#import <AppKit/AppKit.h>

NSString *ClipboardDecodeRTFText(NSData *data) {
    @try {
        NSAttributedString *value = [[NSAttributedString alloc] initWithRTF:data documentAttributes:NULL];
        return [value.string copy];
    } @catch (NSException *exception) {
        (void)exception;
        return nil;
    }
}
