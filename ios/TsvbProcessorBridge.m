#import "TsvbProcessorBridge.h"
#import "TsvbVideoProcessorWrapper.h"

/// Singleton processor instance
static TsvbVideoProcessorWrapper *sharedProcessor = nil;

@implementation TsvbProcessorBridge

+ (void)registerProcessorWithModule:(id<TsvbVideoEffectsModuleProtocol>)module {
    // Ensure only one processor is registered at a time
    if (sharedProcessor) {
        [self unregisterProcessor];
    }
    
    sharedProcessor = [[TsvbVideoProcessorWrapper alloc] initWithTsvbModule:module];
    
    if (sharedProcessor) {
        [sharedProcessor registerWithProvider];
        NSLog(@"✅ TSVB video processor registered");
    } else {
        NSLog(@"❌ Failed to create TSVB video processor");
    }
}

+ (void)unregisterProcessor {
    if (sharedProcessor) {
        [sharedProcessor unregisterFromProvider];
        sharedProcessor = nil;
        NSLog(@"✅ TSVB video processor unregistered");
    }
}

@end