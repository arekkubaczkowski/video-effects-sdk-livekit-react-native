#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// Protocol for TSVB module interface
@protocol TsvbVideoEffectsModuleProtocol <NSObject>
- (CVPixelBufferRef _Nullable)processFrameInternal:(CVPixelBufferRef)pixelBuffer;
- (BOOL)isBlurEnabled;
- (BOOL)hasVirtualBackground;
@end

/// Wrapper class that bridges Swift processor with WebRTC's Objective-C interface
@interface TsvbVideoProcessorWrapper : NSObject

- (instancetype)initWithTsvbModule:(id<TsvbVideoEffectsModuleProtocol>)tsvbModule;
- (void)registerWithProvider;
- (void)unregisterFromProvider;

@end

NS_ASSUME_NONNULL_END