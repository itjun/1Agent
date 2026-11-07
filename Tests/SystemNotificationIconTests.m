#import <AppKit/AppKit.h>
#import <dlfcn.h>

// 直接走系统的应用图标解析，不能用 NSWorkspace 的 Finder 自定义图标代替。
@interface NSObject (SystemIconTest)
- (id)initWithBundleURL:(NSURL *)url;
- (id)initWithBundleIdentifier:(NSString *)identifier;
- (id)imageForSize:(CGSize)size scale:(double)scale;
- (NSData *)data;
+ (CGImageRef)createCGImageWithIFImageData:(NSData *)data CF_RETURNS_RETAINED;
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2 && argc != 3) return 1;
        BOOL isRegisteredIcon = argc == 3 && strcmp(argv[2], "--registered") == 0;
        dlopen("/System/Library/PrivateFrameworks/IconServices.framework/IconServices", RTLD_LAZY);
        Class iconClass = NSClassFromString(isRegisteredIcon ? @"ISBundleIdentifierIcon" : @"ISBundleIcon");
        Class imageClass = NSClassFromString(@"ISImage");
        SEL initializer = isRegisteredIcon ? @selector(initWithBundleIdentifier:) : @selector(initWithBundleURL:);
        if (![iconClass instancesRespondToSelector:initializer] ||
            ![imageClass respondsToSelector:@selector(createCGImageWithIFImageData:)]) {
            fprintf(stderr, "System icon renderer unavailable; visual verification required\n");
            return 1;
        }
        id icon;
        if (isRegisteredIcon) {
            NSString *identifier = [NSBundle bundleWithPath:@(argv[1])].bundleIdentifier;
            if (!identifier) return 1;
            icon = [[iconClass alloc] initWithBundleIdentifier:identifier];
        } else {
            icon = [[iconClass alloc] initWithBundleURL:[NSURL fileURLWithPath:@(argv[1])]];
        }
        id image = [icon imageForSize:CGSizeMake(64, 64) scale:2];
        CGImageRef cgImage = [imageClass createCGImageWithIFImageData:[image data]];
        if (!cgImage) return 1;
        NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithCGImage:cgImage];
        CGImageRelease(cgImage);
        NSUInteger visiblePixels = 0;
        for (NSInteger y = 0; y < bitmap.pixelsHigh; y++) {
            for (NSInteger x = 0; x < bitmap.pixelsWide; x++) {
                NSColor *color = [[bitmap colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
                if (color.alphaComponent > 0.5 &&
                    MIN(color.redComponent, MIN(color.greenComponent, color.blueComponent)) < 0.6) {
                    visiblePixels++;
                }
            }
        }
        // 阴影和透明边缘不计入；白底白图会得到 0，完整标志应有足够可见内容。
        BOOL isReadable = visiblePixels > bitmap.pixelsWide * bitmap.pixelsHigh / 100;
        printf("System application icon (%s): %lu visible pixels — %s\n", isRegisteredIcon ? "bundle identifier" : "bundle path", visiblePixels, isReadable ? "PASS" : "FAIL");
        return isReadable ? 0 : 1;
    }
}
