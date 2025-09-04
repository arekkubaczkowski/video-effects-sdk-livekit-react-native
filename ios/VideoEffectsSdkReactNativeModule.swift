import ExpoModulesCore
import AVFoundation
import WebRTC
@preconcurrency import TSVB
import ObjectiveC

// MARK: - Protocols

@objc public protocol TsvbVideoEffectsModuleProtocol: AnyObject {
    @objc(processFrameInternal:) func processFrameInternal(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer?
    @objc var isBlurEnabled: Bool { get }
    @objc var hasVirtualBackground: Bool { get }
}

// MARK: - Utility Functions

func synchronized<ReturnT>(_ obj: AnyObject, closure: () -> ReturnT) -> ReturnT {
    objc_sync_enter(obj)
    defer { objc_sync_exit(obj) }
    return closure()
}

// MARK: - Main Module

public class VideoEffectsSdkReactNativeModule: Module, TsvbVideoEffectsModuleProtocol {
    
    // MARK: - Singleton
    
    private static var _sharedInstance: VideoEffectsSdkReactNativeModule?
    
    @objc public static func sharedInstance() -> Any? {
        return _sharedInstance
    }
    
    // MARK: - Properties
    
    // TSVB SDK components
    private var sdkFactory: SDKFactory?
    private var pipeline: Pipeline?
    private var frameFactory: FrameFactory?
    
    // Video processing
    private var videoFrameProcessor: TsvbVideoFrameProcessor?
    
    // State management
    private var isInitialized = false
    private var blurEnabled = false
    private var replaceBackgroundEnabled = false
    private var pipelineReady = false
    private var currentTrackId: String?
    
    // Concurrency
    private let pipelineControlQueue = DispatchQueue(label: "com.tsvb.pipeline-control")
    
    // MARK: - Expo Module Definition
    
    public func definition() -> ModuleDefinition {
        Name("VideoEffectsSdkReactNativeModule")
        
        OnCreate {
            VideoEffectsSdkReactNativeModule._sharedInstance = self
        }
        
        AsyncFunction("initialize") { (customerID: String, trackId: String) -> [String: Any] in
            return await self.initializeSDK(customerID: customerID, trackId: trackId)
        }
        
        AsyncFunction("enableBlurBackground") { (power: Double?) -> [String: Any] in
            let blurPower = power ?? 0.3
            return await self.enableBlurBackground(power: blurPower)
        }
        
        AsyncFunction("disableBlurBackground") { () -> [String: Any] in
            return await self.disableBlurBackground()
        }
        
        AsyncFunction("enableReplaceBackground") { (imagePath: String?) -> [String: Any] in
            return await self.enableReplaceBackground(imagePath: imagePath)
        }
        
        AsyncFunction("disableReplaceBackground") { () -> [String: Any] in
            return await self.disableReplaceBackground()
        }
        
        Function("isInitialized") {
            return self.isInitialized
        }

        Function("isBlurEnabled") {
            return self.isBlurEnabled
        }
        
        Function("hasVirtualBackground") {
            return self.hasVirtualBackground
        }
        
        Function("cleanup") {
            self.cleanup()
        }
        
    }
    
    // MARK: - Public API (TsvbVideoEffectsModuleProtocol)
    
    @objc public func isSDKInitialized() -> Bool { 
        return isInitialized 
    }
    
    @objc public var isBlurEnabled: Bool { 
        return blurEnabled 
    }
    
    @objc public var hasVirtualBackground: Bool { 
        return replaceBackgroundEnabled 
    }
    
    // MARK: - SDK Operations
    
    private func initializeSDK(customerID: String, trackId: String) async -> [String: Any] {
        // Check if track ID has changed
        let trackIdChanged = currentTrackId != nil && currentTrackId != trackId
        
        if trackIdChanged {
            currentTrackId = trackId
            registerVideoProcessor()
            
            return ["success": true, "status": "track_updated"]
        }
        
        // If already initialized with same track, just return success
        if isInitialized && currentTrackId == trackId {
            return ["success": true, "status": "already_initialized"]
        }
        
        // First-time initialization
        do {
            sdkFactory = TSVB.SDKFactory()
            
            guard let factory = sdkFactory else {
                return ["success": false, "error": "Failed to create SDK factory"]
            }
            
            let result = try await factory.auth(customerID: customerID)
            
            if result.status == .active {
                pipeline = factory.newPipeline()
                frameFactory = factory.newFrameFactory()
                
                if let pipeline = pipeline {
                    let pipelineConfig = pipeline.copyConfiguration()
                    pipelineConfig?.segmentationPreset = .quality
                    pipeline.setConfiguration(pipelineConfig!)
                }
                
                isInitialized = true
                pipelineReady = true
                currentTrackId = trackId
                
                registerVideoProcessor()
                
                return ["success": true, "status": "active"]
            } else {
                let errorMessage = getAuthErrorMessage(status: result.status)
                return ["success": false, "error": errorMessage]
            }
        } catch {
            return ["success": false, "error": error.localizedDescription]
        }
    }
    
    private func enableBlurBackground(power: Double) async -> [String: Any] {
        guard isInitialized, let pipeline = pipeline else {
            return ["success": false, "error": "SDK not initialized"]
        }
        
        return await inControlQueue {
            return synchronized(pipeline) {
                let result = pipeline.enableBlurBackground(power: Float(power))
                
                if result == .ok {
                    pipeline.disableReplaceBackground()
                    pipeline.disableDenoiseBackground()
                    self.blurEnabled = true
                    self.pipelineReady = true
                    
                    return ["success": true]
                } else {
                    return ["success": false, "error": "Failed to enable blur background"]
                }
            }
        }
    }
    
    private func disableBlurBackground() async -> [String: Any] {
        guard isInitialized, let pipeline = pipeline else {
            return ["success": false, "error": "SDK not initialized"]
        }
        
        return await inControlQueue {
            return synchronized(pipeline) {
                pipeline.disableBlurBackground()
                self.blurEnabled = false
                
                return ["success": true]
            }
        }
    }
    
    private func enableReplaceBackground(imagePath: String?) async -> [String: Any] {
        guard isInitialized, let pipeline = pipeline else {
            return ["success": false, "error": "SDK not initialized"]
        }
        
        return await inControlQueue {
            return synchronized(pipeline) {
                let result = pipeline.enableReplaceBackground(nil)
                
                if result == .ok {
                    pipeline.disableBlurBackground()
                    pipeline.disableDenoiseBackground()
                    self.blurEnabled = false
                    self.replaceBackgroundEnabled = true
                    
                    return ["success": true]
                } else {
                    return ["success": false, "error": "Failed to enable replace background"]
                }
            }
        }
    }
    
    private func disableReplaceBackground() async -> [String: Any] {
        guard isInitialized, let pipeline = pipeline else {
            return ["success": false, "error": "SDK not initialized"]
        }
        
        return await inControlQueue {
            return synchronized(pipeline) {
                pipeline.disableReplaceBackground()
                self.replaceBackgroundEnabled = false
                
                return ["success": true]
            }
        }
    }
    
    @objc(processFrameInternal:) public func processFrameInternal(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        guard isInitialized, let pipeline = pipeline, pipelineReady else {
            return pixelBuffer
        }
        
        guard CVPixelBufferGetWidth(pixelBuffer) > 0 && CVPixelBufferGetHeight(pixelBuffer) > 0 else {
            return pixelBuffer
        }
        
        let result = synchronized(pipeline) {
            return pipeline.process(pixelBuffer: pixelBuffer, metalCompatible: true, error: nil)
        }
        
        return result?.toCVPixelBuffer() ?? pixelBuffer
    }
    
    private func inControlQueue<ReturnT>(closure: @escaping () -> ReturnT) async -> ReturnT {
        return await withCheckedContinuation { continuation in
            pipelineControlQueue.async {
                let result = closure()
                continuation.resume(returning: result)
            }
        }
    }
    
    private func getAuthErrorMessage(status: AuthStatus) -> String {
        switch status {
        case .expired:
            return "License expired"
        case .inactive:
            return "License is inactive"
        default:
            return "Unknown authorization error"
        }
    }
    
    // MARK: - Video Processor Management
    
    private func registerVideoProcessor() {
        unregisterVideoProcessor() // Clean up any existing processor first
        videoFrameProcessor = TsvbVideoFrameProcessor(module: self)
        videoFrameProcessor?.register()
    }
    
    private func unregisterVideoProcessor() {
        videoFrameProcessor?.unregister()
        videoFrameProcessor = nil
    }
    
    // MARK: - Lifecycle Management
    
    private func cleanup() {
        if let pipeline = pipeline {
            synchronized(pipeline) {
                pipeline.disableBlurBackground()
                pipeline.disableReplaceBackground()
                pipeline.disableDenoiseBackground()
            }
        }
        
        // Unregister video processor
        unregisterVideoProcessor()
        
        pipeline = nil
        frameFactory = nil
        sdkFactory = nil
        isInitialized = false
        blurEnabled = false
        replaceBackgroundEnabled = false
        pipelineReady = false
        currentTrackId = nil
    }
    
    deinit {
        cleanup()
    }
}
