import Foundation
import WebRTC
import CoreVideo

// MARK: - Video Frame Processor

@objc(TsvbVideoFrameProcessor)
public class TsvbVideoFrameProcessor: NSObject {
    
    // MARK: - Properties
    
    private weak var tsvbModule: TsvbVideoEffectsModuleProtocol?
    private var isEnabled: Bool = true
    
    // MARK: - Initialization
    
    @objc public init(module: Any) {
        self.tsvbModule = module as? TsvbVideoEffectsModuleProtocol
        super.init()
    }
    
    // MARK: - Registration
    
    @objc public func register() {
        // Use runtime to find the actual ProcessorProvider class from WebRTC
        if let providerClass = NSClassFromString("ProcessorProvider") as? NSObject.Type {
            let selector = NSSelectorFromString("addProcessor:forName:")
            if providerClass.responds(to: selector) {
                providerClass.perform(selector, with: self, with: "tsvb")
            }
        }
    }
    
    @objc public func unregister() {
        // Use runtime to find the actual ProcessorProvider class from WebRTC
        if let providerClass = NSClassFromString("ProcessorProvider") as? NSObject.Type {
            let selector = NSSelectorFromString("removeProcessor:")
            if providerClass.responds(to: selector) {
                providerClass.perform(selector, with: "tsvb")
            }
        }
    }
    
    // MARK: - Video Processing
    
    @objc public func capturer(_ capturer: RTCVideoCapturer, didCaptureVideoFrame frame: RTCVideoFrame) -> RTCVideoFrame {
        guard isEnabled else { return frame }
        guard let module = tsvbModule else { return frame }
        
        // Check if effects are enabled
        guard module.isBlurEnabled || module.hasVirtualBackground else { 
            return frame 
        }
        
        // Extract pixel buffer
        guard let rtcBuffer = frame.buffer as? RTCCVPixelBuffer else {
            return frame
        }
        
        let pixelBuffer = rtcBuffer.pixelBuffer
        
        // Process the frame
        guard let processedBuffer = module.processFrameInternal(pixelBuffer) else {
            return frame
        }
        
        // Create new RTCVideoFrame with processed buffer
        let newRtcBuffer = RTCCVPixelBuffer(pixelBuffer: processedBuffer)
        return RTCVideoFrame(buffer: newRtcBuffer, 
                            rotation: frame.rotation,
                            timeStampNs: frame.timeStampNs)
    }
    
    // MARK: - Configuration
    
    @objc public func setEnabled(_ enabled: Bool) {
        self.isEnabled = enabled
    }
}