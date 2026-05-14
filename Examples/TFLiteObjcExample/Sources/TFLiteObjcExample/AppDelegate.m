#import "AppDelegate.h"
#import "TFLiteRunner.h"

// WildEdge auto-inits via +load using WILDEDGE_DSN from the environment or Info.plist.
// TFLInterpreter is intercepted automatically — no WildEdge calls needed.

static NSString * const kModelURL = @"https://storage.googleapis.com/download.tensorflow.org/models/tflite/task_library/image_classification/ios/lite-model_efficientnet_lite0_uint8_2.tflite";
static NSString * const kModelFilename = @"wildedge_sample_model.tflite";

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {

    [self modelPathWithCompletion:^(NSString *path) {
        if (path) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [TFLiteRunner runWithModelPath:path];
            });
        }
    }];
    return YES;
}

// MARK: - Model

- (void)modelPathWithCompletion:(void (^)(NSString * _Nullable))completion {
    // 1. Bundled model takes priority (drag model.tflite into Xcode → "Add to target").
    NSString *bundled = [NSBundle.mainBundle pathForResource:@"model" ofType:@"tflite"];
    if (bundled) {
        NSLog(@"[TFLiteObjcExample] Using bundled model");
        completion(bundled);
        return;
    }

    // 2. Previously downloaded model in Caches.
    NSString *cached = [self cachedModelPath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:cached]) {
        NSLog(@"[TFLiteObjcExample] Using cached model at %@", cached);
        completion(cached);
        return;
    }

    // 3. Download sample model.
    NSLog(@"[TFLiteObjcExample] Downloading sample model from %@", kModelURL);
    NSURL *url = [NSURL URLWithString:kModelURL];
    NSURLSessionDownloadTask *task = [NSURLSession.sharedSession
        downloadTaskWithURL:url
        completionHandler:^(NSURL *tmpURL, NSURLResponse *response, NSError *error) {
            if (error || !tmpURL) {
                NSLog(@"[TFLiteObjcExample] Download failed: %@", error.localizedDescription);
                completion(nil);
                return;
            }

            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            if (http.statusCode < 200 || http.statusCode >= 300) {
                NSLog(@"[TFLiteObjcExample] Download HTTP %ld", (long)http.statusCode);
                completion(nil);
                return;
            }

            NSError *moveError;
            [[NSFileManager defaultManager] moveItemAtPath:tmpURL.path
                                                    toPath:cached
                                                     error:&moveError];
            if (moveError) {
                NSLog(@"[TFLiteObjcExample] Save failed: %@", moveError.localizedDescription);
                completion(nil);
                return;
            }

            NSLog(@"[TFLiteObjcExample] Model saved to %@", cached);
            completion(cached);
        }];
    [task resume];
}

- (NSString *)cachedModelPath {
    NSString *caches = NSSearchPathForDirectoriesInDomains(
        NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return [caches stringByAppendingPathComponent:kModelFilename];
}

@end
