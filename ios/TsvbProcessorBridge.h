#import <Foundation/Foundation.h>

@protocol TsvbVideoEffectsModuleProtocol;

@interface TsvbProcessorBridge : NSObject

+ (void)registerProcessorWithModule:(id<TsvbVideoEffectsModuleProtocol>)module;
+ (void)unregisterProcessor;

@end