#include "Screenshot.h"
#include "Screen.h"
#include "SocketServer.h"
#import <UIKit/UIKit.h>
#import <os/lock.h>

// ---- 画面差异：每帧算一张 36x78 的灰度缩略图，和上一帧逐像素比平均差（0~255）。
// 一台手机只服务一个电脑端客户端，所以全局一份即可。
#define ZX_THUMB_W 36
#define ZX_THUMB_H 78
static NSData *zxLastThumb = nil;
static os_unfair_lock zxThumbLock = OS_UNFAIR_LOCK_INIT;

static NSData *zxGrayThumbnail(UIImage *image)
{
    if (!image || !image.CGImage) return nil;
    NSMutableData *buf = [NSMutableData dataWithLength:ZX_THUMB_W * ZX_THUMB_H];
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate([buf mutableBytes], ZX_THUMB_W, ZX_THUMB_H, 8, ZX_THUMB_W, gray,
                                             (CGBitmapInfo)kCGImageAlphaNone);
    CGColorSpaceRelease(gray);
    if (!ctx) return nil;
    CGContextSetInterpolationQuality(ctx, kCGInterpolationLow);
    CGContextDrawImage(ctx, CGRectMake(0, 0, ZX_THUMB_W, ZX_THUMB_H), image.CGImage);
    CGContextRelease(ctx);
    return buf;
}

static double zxMeanAbsDiff(NSData *a, NSData *b)
{
    if (!a || !b || [a length] == 0 || [a length] != [b length]) return 255.0;
    const UInt8 *pa = (const UInt8 *)[a bytes];
    const UInt8 *pb = (const UInt8 *)[b bytes];
    NSUInteger n = [a length];
    unsigned long total = 0;
    for (NSUInteger i = 0; i < n; i++) {
        total += (pa[i] > pb[i]) ? (unsigned long)(pa[i] - pb[i]) : (unsigned long)(pb[i] - pa[i]);
    }
    return (double)total / (double)n;
}

// 和原来 Task.xm 里一样：按当前屏幕方向把截图摆正
static UIImage *zxOrientedImage(CGImageRef screenshot)
{
    UIImageOrientation imageOrientation = UIImageOrientationUp;
    int screenOrientation = [Screen getScreenOrientation];
    if (screenOrientation == 4) {
        imageOrientation = UIImageOrientationRight;
    } else if (screenOrientation == 3) {
        imageOrientation = UIImageOrientationLeft;
    } else if (screenOrientation == 2) {
        imageOrientation = UIImageOrientationDown;
    }
    CGFloat scale = [Screen getScale];
    UIImage *image = [UIImage imageWithCGImage:screenshot scale:scale orientation:imageOrientation];
    if (image && imageOrientation != UIImageOrientationUp) {
        CGSize orientedSize = CGSizeMake(CGImageGetWidth(screenshot) / scale, CGImageGetHeight(screenshot) / scale);
        if (imageOrientation == UIImageOrientationLeft || imageOrientation == UIImageOrientationRight) {
            orientedSize = CGSizeMake(orientedSize.height, orientedSize.width);
        }
        UIGraphicsBeginImageContextWithOptions(orientedSize, YES, scale);
        [image drawInRect:CGRectMake(0, 0, orientedSize.width, orientedSize.height)];
        UIImage *orientedImage = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        if (orientedImage) image = orientedImage;
    }
    return image;
}

// 在手机上先缩到 maxWidth 像素宽再发（电脑端 OCR / 模型本来就只用 585 宽，原图 3/4 的字节是白传的）
static UIImage *zxDownscale(UIImage *image, int maxWidth)
{
    if (!image || maxWidth <= 0) return image;
    CGFloat pixelW = image.size.width * image.scale;
    CGFloat pixelH = image.size.height * image.scale;
    if (pixelW <= maxWidth) return image;
    CGFloat targetW = (CGFloat)maxWidth;
    CGFloat targetH = round(pixelH * targetW / pixelW);
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(targetW, targetH), YES, 1.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (ctx) CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
    [image drawInRect:CGRectMake(0, 0, targetW, targetH)];
    UIImage *small = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return small ? small : image;
}

void screenshotTaskFromRawData(UInt8 *eventData, CFWriteStreamRef writeStreamRef)
{
    if (!writeStreamRef) return;

    int maxWidth = 0;
    int quality = 85;
    double diffThreshold = 0;
    NSString *raw = [NSString stringWithFormat:@"%s", eventData];
    NSArray *data = [raw componentsSeparatedByString:@";;"];
    if ([data count] >= 1 && [data[0] length] > 0) maxWidth = [data[0] intValue];
    if ([data count] >= 2 && [data[1] length] > 0) quality = [data[1] intValue];
    if ([data count] >= 3 && [data[2] length] > 0) diffThreshold = [data[2] doubleValue];
    if (quality < 1 || quality > 100) quality = 85;
    if (maxWidth < 0) maxWidth = 0;

    CGImageRef screenshot = NULL;
    BOOL responseHeaderSent = NO;
    @try {
        screenshot = [Screen createScreenShotCGImageRef];
        if (!screenshot) {
            notifyClient((UInt8 *)"-1;;Unable to capture screenshot\r\n", writeStreamRef);
            return;
        }
        UIImage *image = zxOrientedImage(screenshot);
        CGImageRelease(screenshot);
        screenshot = NULL;
        image = zxDownscale(image, maxWidth);

        double diff = -1;
        if (diffThreshold > 0) {
            NSData *thumb = zxGrayThumbnail(image);
            os_unfair_lock_lock(&zxThumbLock);
            diff = zxMeanAbsDiff(zxLastThumb, thumb);
            if (thumb) zxLastThumb = thumb;
            os_unfair_lock_unlock(&zxThumbLock);
            if (diff < diffThreshold) {
                NSString *reply = [NSString stringWithFormat:@"0;;unchanged;;%.2f\r\n", diff];
                notifyClient((UInt8 *)[reply UTF8String], writeStreamRef);
                return;
            }
        }

        NSData *jpegData = image ? UIImageJPEGRepresentation(image, (CGFloat)quality / 100.0) : nil;
        if (!jpegData || [jpegData length] == 0) {
            notifyClient((UInt8 *)"-1;;Unable to encode screenshot as JPEG\r\n", writeStreamRef);
            return;
        }
        NSString *header = (diffThreshold > 0)
            ? [NSString stringWithFormat:@"0;;image/jpeg;;%lu;;%.2f\r\n", (unsigned long)[jpegData length], diff]
            : [NSString stringWithFormat:@"0;;image/jpeg;;%lu\r\n", (unsigned long)[jpegData length]];
        NSData *headerData = [header dataUsingEncoding:NSUTF8StringEncoding];
        if (!headerData || notifyClientData((const UInt8 *)[headerData bytes], (CFIndex)[headerData length], writeStreamRef) != 0) {
            return;
        }
        responseHeaderSent = YES;
        if (notifyClientData((const UInt8 *)[jpegData bytes], (CFIndex)[jpegData length], writeStreamRef) != 0) {
            NSLog(@"com.zjx.springboard: Failed to send screenshot JPEG payload.");
        }
    }
    @catch (NSException *exception) {
        NSLog(@"com.zjx.springboard: Screenshot task failed: %@", exception.reason);
        if (!responseHeaderSent) {
            notifyClient((UInt8 *)"-1;;Unable to capture screenshot\r\n", writeStreamRef);
        }
    }
    @finally {
        if (screenshot) CGImageRelease(screenshot);
    }
}
