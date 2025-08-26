import Foundation
import CoreVideo
import WebRTC

/// Video processor that applies TSVB effects to WebRTC video frames
@objc(TsvbVideoProcessor)
public class TsvbVideoProcessor: NSObject {
    
    // MARK: - Properties
    
    private weak var tsvbModule: TsvbVideoEffectsModuleProtocol?
    private var isEnabled: Bool = true
    private var hasLoggedFirstCall = false
    
    // MARK: - Initialization
    
    @objc public init(tsvbModule: TsvbVideoEffectsModuleProtocol) {
        self.tsvbModule = tsvbModule
        super.init()
    }
    
    // MARK: - Configuration
    
    @objc public func updateOptions(_ options: [String: Any]) {
        if let enabled = options["enabled"] as? Bool {
            self.isEnabled = enabled
        }
    }
    
    // MARK: - Video Processing
    
    @objc public func capturer(_ capturer: RTCVideoCapturer, didCaptureVideoFrame frame: RTCVideoFrame) -> RTCVideoFrame {
        guard isEnabled else { return frame }
        guard let module = tsvbModule else { return frame }
        guard shouldProcessFrame(module: module) else { return frame }
        
        return processFrame(frame, with: module) ?? frame
    }
    
}

// MARK: - Private Methods

private extension TsvbVideoProcessor {
    func shouldProcessFrame(module: TsvbVideoEffectsModuleProtocol) -> Bool {
        return module.isBlurEnabled || module.hasVirtualBackground
    }
    
    func processFrame(_ frame: RTCVideoFrame, with module: TsvbVideoEffectsModuleProtocol) -> RTCVideoFrame? {
        guard let pixelBuffer = extractPixelBuffer(from: frame) else {
            return nil
        }
        
        guard let processedBuffer = module.processFrameInternal(pixelBuffer) else {
            return nil
        }
        
        return createRTCVideoFrame(
            from: processedBuffer,
            timestamp: frame.timeStampNs,
            rotation: frame.rotation
        )
    }
    
    func extractPixelBuffer(from frame: RTCVideoFrame) -> CVPixelBuffer? {
        guard let rtcBuffer = frame.buffer as? RTCCVPixelBuffer else {
            return nil
        }
        return rtcBuffer.pixelBuffer
    }
    
    func createRTCVideoFrame(from pixelBuffer: CVPixelBuffer,
                            timestamp: Int64,
                            rotation: RTCVideoRotation) -> RTCVideoFrame? {
        let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        return RTCVideoFrame(buffer: rtcBuffer, 
                            rotation: rotation,
                            timeStampNs: timestamp)
    }
}