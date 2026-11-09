#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// AppKit/Foundation legacy decoders can raise NSException on malformed bytes.
/// Swift cannot catch those exceptions, so keep decoding and object inspection
/// inside this narrow Objective-C RTF boundary and return nil on invalid input.
/// Flat RTFD is read by a bounded Swift parser, never NSFileWrapper deserialization.
FOUNDATION_EXPORT NSString * _Nullable ClipboardDecodeRTFText(NSData *data);

NS_ASSUME_NONNULL_END
