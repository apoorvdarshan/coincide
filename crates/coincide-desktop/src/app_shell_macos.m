#import <AppKit/AppKit.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// PNG bytes of an application's Finder icon drawn side x side pixels, or NULL.
// The caller frees the bytes with coincide_free.
uint8_t *coincide_application_icon_png(const char *path, int side, size_t *length) {
    @autoreleasepool {
        *length = 0;
        if (!path || side <= 0 || side > 256) return NULL;
        NSString *file = [NSString stringWithUTF8String:path];
        if (!file) return NULL;
        NSImage *icon = [[NSWorkspace sharedWorkspace] iconForFile:file];
        if (!icon) return NULL;
        NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                           pixelsWide:side
                                                                           pixelsHigh:side
                                                                        bitsPerSample:8
                                                                      samplesPerPixel:4
                                                                             hasAlpha:YES
                                                                             isPlanar:NO
                                                                       colorSpaceName:NSDeviceRGBColorSpace
                                                                          bytesPerRow:0
                                                                         bitsPerPixel:0];
        if (!bitmap) return NULL;
        NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
        if (!context) return NULL;
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:context];
        [icon drawInRect:NSMakeRect(0, 0, side, side)
                fromRect:NSZeroRect
               operation:NSCompositingOperationCopy
                fraction:1.0];
        [context flushGraphics];
        [NSGraphicsContext restoreGraphicsState];
        NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        if (!png || png.length == 0) return NULL;
        uint8_t *bytes = malloc(png.length);
        if (!bytes) return NULL;
        memcpy(bytes, png.bytes, png.length);
        *length = png.length;
        return bytes;
    }
}

void coincide_free(void *bytes) { free(bytes); }

// The Dock icon's badge; NULL clears it. Main thread only.
void coincide_set_dock_badge(const char *label) {
    @autoreleasepool {
        NSString *text = label ? [NSString stringWithUTF8String:label] : nil;
        [[NSApp dockTile] setBadgeLabel:text];
    }
}
