#import <Foundation/Foundation.h>

extern void wildedge_auto_init(void);
void wildedge_loader_force_link(void);
void wildedge_loader_force_link(void) {}

@interface _WildEdgeAutoLoader : NSObject
@end

@implementation _WildEdgeAutoLoader
+ (void)load {
    wildedge_auto_init();
}
@end
