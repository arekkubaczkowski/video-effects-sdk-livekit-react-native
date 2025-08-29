import Foundation
import WebRTC
import CoreVideo

// MARK: - Global Video Frame Processor (Singleton)

@objc(TsvbGlobalVideoFrameProcessor)
public class TsvbGlobalVideoFrameProcessor: NSObject {
    
    // MARK: - Singleton
    
    @objc public static let shared = TsvbGlobalVideoFrameProcessor()
    
    // MARK: - Properties
    
    private var isRegistered: Bool = false
    
    // MARK: - Initialization
    
    private override init() {
        super.init()
    }
    
    // MARK: - Registration
    
    @objc public func ensureRegistered() {
        guard !isRegistered else { return }
        
        // Register the processor with WebRTC
        if let providerClass = NSClassFromString("ProcessorProvider") as? NSObject.Type {
            let selector = NSSelectorFromString("addProcessor:forName:")
            if providerClass.responds(to: selector) {
                providerClass.perform(selector, with: self, with: "tsvb")
                isRegistered = true
            }
        }
    }
    
    @objc public func unregister() {
        guard isRegistered else { return }
        
        if let providerClass = NSClassFromString("ProcessorProvider") as? NSObject.Type {
            let selector = NSSelectorFromString("removeProcessor:")
            if providerClass.responds(to: selector) {
                providerClass.perform(selector, with: "tsvb")
                isRegistered = false
            }
        }
    }
    
    // MARK: - Video Processing Delegation
    
    @objc public func capturer(_ capturer: RTCVideoCapturer, didCaptureVideoFrame frame: RTCVideoFrame) -> RTCVideoFrame {
        // Get the shared module instance
        guard let moduleInstance = VideoEffectsSdkReactNativeModule.sharedInstance() as? TsvbVideoEffectsModuleProtocol else {
            return frame
        }
        
        // Check if effects are enabled
        guard moduleInstance.isBlurEnabled || moduleInstance.hasVirtualBackground else {
            return frame
        }
        
        // Extract pixel buffer
        guard let rtcBuffer = frame.buffer as? RTCCVPixelBuffer else {
            return frame
        }
        
        let pixelBuffer = rtcBuffer.pixelBuffer
        
        // Process the frame
        guard let processedBuffer = moduleInstance.processFrameInternal(pixelBuffer) else {
            return frame
        }
        
        // Create new RTCVideoFrame with processed buffer
        let newRtcBuffer = RTCCVPixelBuffer(pixelBuffer: processedBuffer)
        return RTCVideoFrame(buffer: newRtcBuffer,
                            rotation: frame.rotation,
                            timeStampNs: frame.timeStampNs)
    }
}

// MARK: - Video Frame Processor Wrapper (for compatibility)

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
        // Always ensure the global processor is registered
        TsvbGlobalVideoFrameProcessor.shared.ensureRegistered()
    }
    
    @objc public func unregister() {
        // Delegate to global processor
        TsvbGlobalVideoFrameProcessor.shared.unregister()
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