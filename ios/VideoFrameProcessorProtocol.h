#import <Foundation/Foundation.h>
#import <WebRTC/RTCVideoCapturer.h>
#import <WebRTC/RTCVideoFrame.h>

NS_ASSUME_NONNULL_BEGIN

/// Protocol for video frame processing
/// This protocol is used by WebRTC to process video frames
@protocol VideoFrameProcessorDelegate <NSObject>

- (RTCVideoFrame *)capturer:(RTCVideoCapturer *)capturer didCaptureVideoFrame:(RTCVideoFrame *)frame;

@end

NS_ASSUME_NONNULL_END