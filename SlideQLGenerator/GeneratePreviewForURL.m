#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreServices/CoreServices.h>
#include <QuickLook/QuickLook.h>
#include <openslide/openslide.h>

OSStatus GeneratePreviewForURL(void *thisInterface, QLPreviewRequestRef preview,
                               CFURLRef url, CFStringRef contentTypeUTI,
                               CFDictionaryRef options);
void CancelPreviewGeneration(void *thisInterface, QLPreviewRequestRef preview);

OSStatus GenerateThumbnailForURL(void *thisInterface,
                                 QLThumbnailRequestRef thumbnail, CFURLRef url,
                                 CFStringRef contentTypeUTI,
                                 CFDictionaryRef options, CGSize maxSize);
void CancelThumbnailGeneration(void *thisInterface,
                               QLThumbnailRequestRef thumbnail);

/* -- Thumbnail Generation -- */

OSStatus GenerateThumbnailForURL(void *thisInterface,
                                 QLThumbnailRequestRef thumbnail, CFURLRef url,
                                 CFStringRef contentTypeUTI,
                                 CFDictionaryRef options, CGSize maxSize) {
  @autoreleasepool {
    NSString *path = [(__bridge NSURL *)url path];
    const char *cpath = [path UTF8String];

    openslide_t *osr = openslide_open(cpath);
    if (!osr)
      return noErr;

    // Get associated image "thumbnail" first, then "macro"
    const char *const *names = openslide_get_associated_image_names(osr);
    const char *imageName = NULL;
    for (int i = 0; names[i]; i++) {
      if (strcmp(names[i], "thumbnail") == 0) {
        imageName = "thumbnail";
        break;
      }
      if (strcmp(names[i], "macro") == 0) {
        imageName = "macro";
      }
    }

    CGImageRef cgImage = NULL;

    if (imageName) {
      int64_t w, h;
      openslide_get_associated_image_dimensions(osr, imageName, &w, &h);
      if (w > 0 && h > 0) {
        uint32_t *buf = (uint32_t *)malloc(w * h * 4);
        if (buf) {
          openslide_read_associated_image(osr, imageName, buf);
          // OpenSlide returns pre-multiplied ARGB, convert to RGBA for CGImage
          CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
          CGContextRef ctx = CGBitmapContextCreate(
              buf, w, h, 8, w * 4, cs,
              kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
          cgImage = CGBitmapContextCreateImage(ctx);
          CGContextRelease(ctx);
          CGColorSpaceRelease(cs);
          free(buf);
        }
      }
    }

    if (!cgImage) {
      // Fallback: read from level 0 at reduced size
      int32_t levels = openslide_get_level_count(osr);
      int32_t bestLevel = levels - 1; // smallest level
      int64_t w, h;
      openslide_get_level_dimensions(osr, bestLevel, &w, &h);
      if (w > 0 && h > 0) {
        // Limit to reasonable thumbnail size
        if (w > 2048) {
          bestLevel = levels > 1 ? levels - 2 : 0;
        }
        openslide_get_level_dimensions(osr, bestLevel, &w, &h);
        // Cap at 1024
        int64_t readW = w > 1024 ? 1024 : w;
        int64_t readH = h > 1024 ? 1024 : h;
        uint32_t *buf = (uint32_t *)malloc(readW * readH * 4);
        if (buf) {
          openslide_read_region(osr, buf, 0, 0, bestLevel, readW, readH);
          CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
          CGContextRef ctx = CGBitmapContextCreate(
              buf, readW, readH, 8, readW * 4, cs,
              kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
          cgImage = CGBitmapContextCreateImage(ctx);
          CGContextRelease(ctx);
          CGColorSpaceRelease(cs);
          free(buf);
        }
      }
    }

    openslide_close(osr);

    if (cgImage) {
      QLThumbnailRequestSetImage(thumbnail, cgImage, NULL);
      CGImageRelease(cgImage);
    }
  }
  return noErr;
}

void CancelThumbnailGeneration(void *thisInterface,
                               QLThumbnailRequestRef thumbnail) {}

/* -- Preview Generation -- */

OSStatus GeneratePreviewForURL(void *thisInterface, QLPreviewRequestRef preview,
                               CFURLRef url, CFStringRef contentTypeUTI,
                               CFDictionaryRef options) {
  @autoreleasepool {
    NSString *path = [(__bridge NSURL *)url path];
    const char *cpath = [path UTF8String];

    openslide_t *osr = openslide_open(cpath);
    if (!osr)
      return noErr;

    // Get slide dimensions
    int64_t slideW, slideH;
    openslide_get_level_dimensions(osr, 0, &slideW, &slideH);

    // Try to get "macro" or "thumbnail" associated image for preview
    const char *const *names = openslide_get_associated_image_names(osr);
    const char *imageName = NULL;
    for (int i = 0; names[i]; i++) {
      if (strcmp(names[i], "macro") == 0) {
        imageName = "macro";
        break;
      }
      if (strcmp(names[i], "thumbnail") == 0) {
        imageName = "thumbnail";
      }
      if (strcmp(names[i], "label") == 0 && !imageName) {
        imageName = "label";
      }
    }

    CGImageRef cgImage = NULL;
    int64_t imgW = 0, imgH = 0;

    if (imageName) {
      openslide_get_associated_image_dimensions(osr, imageName, &imgW, &imgH);
      if (imgW > 0 && imgH > 0) {
        uint32_t *buf = (uint32_t *)malloc(imgW * imgH * 4);
        if (buf) {
          openslide_read_associated_image(osr, imageName, buf);
          CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
          CGContextRef ctx = CGBitmapContextCreate(
              buf, imgW, imgH, 8, imgW * 4, cs,
              kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
          cgImage = CGBitmapContextCreateImage(ctx);
          CGContextRelease(ctx);
          CGColorSpaceRelease(cs);
          free(buf);
        }
      }
    }

    if (!cgImage) {
      // Read from lowest resolution level
      int32_t levels = openslide_get_level_count(osr);
      int32_t bestLevel = levels - 1;
      openslide_get_level_dimensions(osr, bestLevel, &imgW, &imgH);
      if (imgW > 0 && imgH > 0) {
        int64_t readW = imgW > 2048 ? 2048 : imgW;
        int64_t readH = imgH > 2048 ? 2048 : imgH;
        uint32_t *buf = (uint32_t *)malloc(readW * readH * 4);
        if (buf) {
          openslide_read_region(osr, buf, 0, 0, bestLevel, readW, readH);
          CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
          CGContextRef ctx = CGBitmapContextCreate(
              buf, readW, readH, 8, readW * 4, cs,
              kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
          cgImage = CGBitmapContextCreateImage(ctx);
          CGContextRelease(ctx);
          CGColorSpaceRelease(cs);
          free(buf);
          imgW = readW;
          imgH = readH;
        }
      }
    }

    openslide_close(osr);

    if (cgImage && !QLPreviewRequestIsCancelled(preview)) {
      // Create a graphics context for the preview
      CGSize previewSize = CGSizeMake(imgW, imgH);
      CGContextRef ctx =
          QLPreviewRequestCreateContext(preview, previewSize, true, NULL);
      if (ctx) {
        CGRect rect = CGRectMake(0, 0, imgW, imgH);
        CGContextDrawImage(ctx, rect, cgImage);
        QLPreviewRequestFlushContext(preview, ctx);
        CFRelease(ctx);
      }
      CGImageRelease(cgImage);
    } else if (cgImage) {
      CGImageRelease(cgImage);
    }
  }
  return noErr;
}

void CancelPreviewGeneration(void *thisInterface, QLPreviewRequestRef preview) {
}
