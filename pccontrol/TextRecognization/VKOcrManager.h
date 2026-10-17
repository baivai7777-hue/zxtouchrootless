#ifndef VKOcrManager_H
#define VKOcrManager_H

#import <Foundation/Foundation.h>
#import <Vision/Vision.h>
#import <CoreImage/CoreImage.h>
#import <UIKit/UIKit.h>

@interface VKOcrManager : NSObject
- (id)initWithCIImage:(CIImage*)image area:(CGRect)aarea orientation:(int)orientation;
- (id)initWithImagePath:(NSString*)path area:(CGRect)aarea orientation:(int)orientation;
- (id)initWithCGImage:(CGImageRef)cgimage area:(CGRect)aarea orientation:(int)orientation;

- (NSString*)recognize:(NSError**)error;
- (NSArray*)areasOfText;
- (void)outputDebugImage:(NSString*)imagePath error:(NSError**)error;

- (void)setMinimumHeight:(float)height;
- (void)setCustomWords:(NSArray*)customWords;
- (void)setRecognitionLevel:(VNRequestTextRecognitionLevel)level;
- (void)setLanguages:(NSArray*)languages;
- (void)setCorrection:(BOOL)correct;
- (void)setCPUOnly:(BOOL)cpuOnly;      // 不走神经网络引擎（越狱环境下 CoreML 报错时用）
- (void)setRevision:(int)revision;   // 0 = 保持默认；iOS 16 可试 3

@end

#endif
