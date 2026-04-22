#import <Foundation/Foundation.h>

extern void wildedge_auto_init(void);

@interface _WildEdgeAutoLoader : NSObject
@end

@implementation _WildEdgeAutoLoader
+ (void)load {
    wildedge_auto_init();
}
@end
