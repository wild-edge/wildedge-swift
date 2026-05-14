#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TFLiteRunner : NSObject
+ (void)runWithModelPath:(NSString *)modelPath;
@end

NS_ASSUME_NONNULL_END
