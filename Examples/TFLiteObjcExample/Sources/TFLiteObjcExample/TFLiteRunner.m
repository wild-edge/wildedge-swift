#import <TFLTensorFlowLite.h>
#import <TFLTensor.h>

#import "TFLiteRunner.h"

@implementation TFLiteRunner

+ (void)runWithModelPath:(NSString *)modelPath {
    NSError *error = nil;

    // trackLoad fires automatically via TFLInterceptor.
    TFLInterpreter *interpreter = [[TFLInterpreter alloc] initWithModelPath:modelPath
                                                                      error:&error];
    if (error || !interpreter) {
        NSLog(@"[TFLiteObjcExample] init error: %@", error);
        return;
    }

    [interpreter allocateTensorsWithError:&error];
    if (error) {
        NSLog(@"[TFLiteObjcExample] allocateTensors error: %@", error);
        return;
    }

    // trackInference fires automatically via TFLInterceptor.
    BOOL success = [interpreter invokeWithError:&error];
    if (!success || error) {
        NSLog(@"[TFLiteObjcExample] invoke error: %@", error);
    } else {
        NSLog(@"[TFLiteObjcExample] invoke ok");
    }

    // TFLInterpreter dealloc → trackUnload fires automatically.
}

@end
