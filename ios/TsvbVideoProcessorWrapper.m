#import "TsvbVideoProcessorWrapper.h"
#import <WebRTC/WebRTC.h>

// MARK: - Private Interfaces

// Protocol for VideoFrameProcessor delegate
@protocol VideoFrameProcessorDelegate <NSObject>
- (RTCVideoFrame *)capturer:(RTCVideoCapturer *)capturer didCaptureVideoFrame:(RTCVideoFrame *)frame;
@end

// ProcessorProvider interface for WebRTC integration
@interface ProcessorProvider : NSObject
+ (void)addProcessor:(NSObject<VideoFrameProcessorDelegate> *)processor forName:(NSString *)name;
+ (void)removeProcessor:(NSString *)name;
@end

// MARK: - Implementation

@interface TsvbVideoProcessorWrapper () <VideoFrameProcessorDelegate>
@property (nonatomic, strong) id swiftProcessor;
- (id)createSwiftProcessor:(id<TsvbVideoEffectsModuleProtocol>)tsvbModule;
- (RTCVideoFrame *)processFrame:(RTCVideoFrame *)frame withCapturer:(RTCVideoCapturer *)capturer;
@end

@implementation TsvbVideoProcessorWrapper

- (instancetype)initWithTsvbModule:(id<TsvbVideoEffectsModuleProtocol>)tsvbModule {
    self = [super init];
    if (self) {
        self.swiftProcessor = [self createSwiftProcessor:tsvbModule];
    }
    return self;
}

- (RTCVideoFrame *)capturer:(RTCVideoCapturer *)capturer didCaptureVideoFrame:(RTCVideoFrame *)frame {
    return [self processFrame:frame withCapturer:capturer];
}

- (void)registerWithProvider {
    [ProcessorProvider addProcessor:self forName:@"tsvb"];
}

- (void)unregisterFromProvider {
    [ProcessorProvider removeProcessor:@"tsvb"];
}

// MARK: - Private Methods

- (id)createSwiftProcessor:(id<TsvbVideoEffectsModuleProtocol>)tsvbModule {
    Class processorClass = NSClassFromString(@"VideoEffectsSdkReactNativeModule.TsvbVideoProcessor");
    if (processorClass) {
        SEL initSelector = NSSelectorFromString(@"initWithTsvbModule:");
        
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        return [[processorClass alloc] performSelector:initSelector withObject:tsvbModule];
        #pragma clang diagnostic pop
    }
    return nil;
}

- (RTCVideoFrame *)processFrame:(RTCVideoFrame *)frame withCapturer:(RTCVideoCapturer *)capturer {
    if (!self.swiftProcessor) {
        return frame;
    }
    
    SEL processorSelector = NSSelectorFromString(@"capturer:didCaptureVideoFrame:");
    if (![self.swiftProcessor respondsToSelector:processorSelector]) {
        return frame;
    }
    
    NSMethodSignature *signature = [self.swiftProcessor methodSignatureForSelector:processorSelector];
    if (!signature) {
        return frame;
    }
    
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    [invocation setTarget:self.swiftProcessor];
    [invocation setSelector:processorSelector];
    [invocation setArgument:&capturer atIndex:2];
    [invocation setArgument:&frame atIndex:3];
    [invocation invoke];
    
    __unsafe_unretained RTCVideoFrame *result;
    [invocation getReturnValue:&result];
    return result ?: frame;
}

@end