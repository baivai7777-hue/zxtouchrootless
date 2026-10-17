#ifndef ZX_SCREENSHOT_H
#define ZX_SCREENSHOT_H

#import <Foundation/Foundation.h>

// 截图任务（TASK_SCREENSHOT = 30）。
// 请求格式（三个参数都可省略，省略 = 老行为：原图、质量 85、不比对）：
//   30;;最大宽度;;JPEG质量(1-100);;差异阈值(0=不比对)
// 回包：
//   画面没变（差异 < 阈值）：          0;;unchanged;;<差异值>\r\n
//   有图（带阈值时多一个差异字段）：    0;;image/jpeg;;<字节数>[;;<差异值>]\r\n + JPEG 字节
//   失败：                              -1;;原因\r\n
void screenshotTaskFromRawData(UInt8 *eventData, CFWriteStreamRef writeStreamRef);

#endif
