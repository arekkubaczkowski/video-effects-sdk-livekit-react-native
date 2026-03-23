import ExpoModulesCore
import AVFoundation
import WebRTC
import UIKit
@preconcurrency import TSVB
import os

// MARK: - State

enum TsvbState: Int {
    case uninitialized = 0
    case authenticating = 1
    case idle = 2    // SDK ready, no effect enabled
    case active = 3  // Effect enabled, processing frames
    case error = 4
}

// MARK: - Frame Processor

/// Per-usage frame processor. NOT a singleton.
/// Holds a strong reference to the pipeline and lock.
/// Created when effects are initialized, destroyed on cleanup.
final class TsvbFrameProcessor: NSObject {

    private var pipeline: Pipeline?
    private var lock = os_unfair_lock()

    /// Atomic flag read on capture thread without lock (fast path).
    /// Written under lock when effects are toggled.
    private let _active = OSAllocatedUnfairLock(initialState: false)

    init(pipeline: Pipeline) {
        self.pipeline = pipeline
        super.init()
    }

    var isActive: Bool {
        _active.withLock { $0 }
    }

    func setActive(_ active: Bool) {
        _active.withLock { $0 = active }
    }

    func processFrame(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        // Fast path — no lock needed for this check
        guard _active.withLock({ $0 }) else {
            return pixelBuffer
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else {
            return pixelBuffer
        }

        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        guard let pipeline = pipeline else {
            return pixelBuffer
        }

        let result = pipeline.process(pixelBuffer: pixelBuffer, metalCompatible: true, error: nil)
        return result?.toCVPixelBuffer() ?? pixelBuffer
    }

    /// Called under external synchronization (module's control queue).
    func updatePipeline(_ pipeline: Pipeline?) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        self.pipeline = pipeline
    }

    func teardown() {
        _active.withLock { $0 = false }
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        pipeline = nil
    }
}

// MARK: - VideoFrameProcessorDelegate bridge

/// ObjC-compatible wrapper that conforms to the fork's VideoFrameProcessorDelegate.
/// Delegates all frame processing to TsvbFrameProcessor.
@objc(TsvbVideoFrameProcessorBridge)
final class TsvbVideoFrameProcessorBridge: NSObject {

    private let processor: TsvbFrameProcessor

    init(processor: TsvbFrameProcessor) {
        self.processor = processor
        super.init()
    }

    /// Called by WebRTC's VideoEffectProcessor on the capture thread.
    @objc func capturer(_ capturer: RTCVideoCapturer, didCaptureVideoFrame frame: RTCVideoFrame) -> RTCVideoFrame {
        guard processor.isActive else {
            return frame
        }

        guard let rtcBuffer = frame.buffer as? RTCCVPixelBuffer else {
            return frame
        }

        guard let processedBuffer = processor.processFrame(rtcBuffer.pixelBuffer) else {
            return frame
        }

        let newBuffer = RTCCVPixelBuffer(pixelBuffer: processedBuffer)
        return RTCVideoFrame(buffer: newBuffer, rotation: frame.rotation, timeStampNs: frame.timeStampNs)
    }
}

// MARK: - Main Module

public class VideoEffectsSdkReactNativeModule: Module {

    // MARK: - Properties

    private var sdkFactory: SDKFactory?
    private var pipeline: Pipeline?
    private var frameFactory: FrameFactory?

    private var frameProcessor: TsvbFrameProcessor?
    private var processorBridge: TsvbVideoFrameProcessorBridge?

    private var state: TsvbState = .uninitialized
    private var blurEnabled = false
    private var replaceBackgroundEnabled = false
    private var replacementController: (any ReplacementController)?

    /// The track ID the processor is currently attached to.
    /// Used only to detach from old track when attaching to new one.
    private var attachedTrackId: String?

    /// Serial queue for ALL state mutations and pipeline operations.
    private let controlQueue = DispatchQueue(label: "com.tsvb.control")

    // MARK: - Module Definition

    public func definition() -> ModuleDefinition {
        Name("VideoEffectsSdkReactNativeModule")

        AsyncFunction("initialize") { (customerID: String, trackId: String) -> [String: Any] in
            return await self.doInitialize(customerID: customerID, trackId: trackId)
        }

        AsyncFunction("enableBlurBackground") { (power: Double?) -> [String: Any] in
            return await self.doEnableBlur(power: Float(power ?? 0.5))
        }

        AsyncFunction("disableBlurBackground") { () -> [String: Any] in
            return await self.doDisableBlur()
        }

        AsyncFunction("enableReplaceBackground") { (assetSource: [String: Any]?, promise: Promise) in
            Task {
                let result = await self.doEnableReplace(assetSource: assetSource)
                promise.resolve(result)
            }
        }

        AsyncFunction("disableReplaceBackground") { () -> [String: Any] in
            return await self.doDisableReplace()
        }

        Function("isInitialized") {
            return self.state == .idle || self.state == .active
        }

        Function("isBlurEnabled") {
            return self.blurEnabled
        }

        Function("hasVirtualBackground") {
            return self.replaceBackgroundEnabled
        }

        Function("cleanup") {
            self.doCleanup()
        }
    }

    // MARK: - Initialize

    private func doInitialize(customerID: String, trackId: String) async -> [String: Any] {
        return await onControlQueue { () async -> [String: Any] in
            // If already initialized, just re-attach to new track if needed
            if self.state == .idle || self.state == .active {
                if self.attachedTrackId != trackId {
                    self.attachProcessorToTrack(trackId)
                }
                return ["success": true, "status": "already_initialized"]
            }

            guard self.state != .authenticating else {
                return ["success": false, "error": "Initialization already in progress"]
            }

            self.state = .authenticating

            do {
                let factory = TSVB.SDKFactory()
                self.sdkFactory = factory

                let authResult = try await factory.auth(customerID: customerID)

                guard authResult.status == .active else {
                    self.state = .error
                    return ["success": false, "error": self.authErrorMessage(authResult.status)]
                }

                let pipeline = factory.newPipeline()
                self.pipeline = pipeline
                self.frameFactory = factory.newFrameFactory()

                if let config = pipeline.copyConfiguration() {
                    config.segmentationPreset = .quality
                    pipeline.setConfiguration(config)
                }

                // Create frame processor (not a singleton — owned by this module instance)
                let fp = TsvbFrameProcessor(pipeline: pipeline)
                self.frameProcessor = fp
                self.processorBridge = TsvbVideoFrameProcessorBridge(processor: fp)

                self.state = .idle

                // Attach to track
                self.attachProcessorToTrack(trackId)

                return ["success": true, "status": "active"]
            } catch {
                self.state = .error
                return ["success": false, "error": error.localizedDescription]
            }
        }
    }

    // MARK: - Effects Control

    private func doEnableBlur(power: Float) async -> [String: Any] {
        return await onControlQueue {
            guard self.state == .idle || self.state == .active,
                  let pipeline = self.pipeline else {
                return ["success": false, "error": "SDK not initialized"]
            }

            let result = pipeline.enableBlurBackground(power: power)
            guard result == .ok else {
                return ["success": false, "error": "Failed to enable blur"]
            }

            pipeline.disableReplaceBackground()
            pipeline.disableDenoiseBackground()
            self.blurEnabled = true
            self.replaceBackgroundEnabled = false
            self.replacementController = nil
            self.state = .active
            self.frameProcessor?.setActive(true)

            return ["success": true]
        }
    }

    private func doDisableBlur() async -> [String: Any] {
        return await onControlQueue {
            guard let pipeline = self.pipeline else {
                return ["success": true]
            }

            pipeline.disableBlurBackground()
            self.blurEnabled = false

            if !self.replaceBackgroundEnabled {
                self.state = .idle
                self.frameProcessor?.setActive(false)
            }

            return ["success": true]
        }
    }

    private func doEnableReplace(assetSource: [String: Any]?) async -> [String: Any] {
        guard state == .idle || state == .active, let pipeline = pipeline else {
            return ["success": false, "error": "SDK not initialized"]
        }

        // Load image outside control queue (potentially slow I/O)
        var backgroundImage: UIImage? = nil

        if let source = assetSource, let uri = source["uri"] as? String {
            backgroundImage = await loadImage(uri: uri)
            if backgroundImage == nil {
                return ["success": false, "error": "Failed to load image from: \(uri)"]
            }
        }

        return await onControlQueue {
            var controller: (any ReplacementController)? = nil
            let result = pipeline.enableReplaceBackground(&controller)

            guard result == .ok, let ctrl = controller else {
                return ["success": false, "error": "Failed to enable replace background"]
            }

            self.replacementController = ctrl

            if let image = backgroundImage, let factory = self.frameFactory {
                if let data = image.jpegData(compressionQuality: 0.9),
                   let frame = factory.image(with: data) {
                    ctrl.background = frame
                } else if let data = image.pngData(),
                          let frame = factory.image(with: data) {
                    ctrl.background = frame
                }
            }

            pipeline.disableBlurBackground()
            pipeline.disableDenoiseBackground()
            self.blurEnabled = false
            self.replaceBackgroundEnabled = true
            self.state = .active
            self.frameProcessor?.setActive(true)

            return ["success": true]
        }
    }

    private func doDisableReplace() async -> [String: Any] {
        return await onControlQueue {
            guard let pipeline = self.pipeline else {
                return ["success": true]
            }

            pipeline.disableReplaceBackground()
            self.replaceBackgroundEnabled = false
            self.replacementController = nil

            if !self.blurEnabled {
                self.state = .idle
                self.frameProcessor?.setActive(false)
            }

            return ["success": true]
        }
    }

    // MARK: - Cleanup

    private func doCleanup() {
        controlQueue.sync {
            self.frameProcessor?.teardown()
            self.detachProcessorFromTrack()

            if let pipeline = self.pipeline {
                pipeline.disableBlurBackground()
                pipeline.disableReplaceBackground()
                pipeline.disableDenoiseBackground()
            }

            self.pipeline = nil
            self.frameFactory = nil
            self.sdkFactory = nil
            self.frameProcessor = nil
            self.processorBridge = nil
            self.blurEnabled = false
            self.replaceBackgroundEnabled = false
            self.replacementController = nil
            self.state = .uninitialized
        }
    }

    deinit {
        frameProcessor?.teardown()
        // Don't call detachProcessorFromTrack in deinit — ObjC runtime calls are unsafe here
        if let pipeline = pipeline {
            pipeline.disableBlurBackground()
            pipeline.disableReplaceBackground()
            pipeline.disableDenoiseBackground()
        }
    }

    // MARK: - Track Attachment (via fork's direct API)

    private func attachProcessorToTrack(_ trackId: String) {
        // Detach from previous track if needed
        if attachedTrackId != nil && attachedTrackId != trackId {
            detachProcessorFromTrack()
        }

        guard let bridge = processorBridge else { return }

        // Call WebRTCModule's setVideoFrameProcessor:forTrackId: via ObjC reflection
        if let webRTCModule = findWebRTCModule() {
            let selector = NSSelectorFromString("setVideoFrameProcessor:forTrackId:")
            if webRTCModule.responds(to: selector) {
                webRTCModule.perform(selector, with: bridge, with: trackId)
                attachedTrackId = trackId
            }
        }
    }

    private func detachProcessorFromTrack() {
        guard let trackId = attachedTrackId else { return }

        if let webRTCModule = findWebRTCModule() {
            let selector = NSSelectorFromString("setVideoFrameProcessor:forTrackId:")
            if webRTCModule.responds(to: selector) {
                webRTCModule.perform(selector, with: nil, with: trackId)
            }
        }

        attachedTrackId = nil
    }

    private func findWebRTCModule() -> NSObject? {
        // Find WebRTCModule via RCTBridge
        guard let bridge = appContext.reactBridge else { return nil }
        let selector = NSSelectorFromString("moduleForName:")
        guard bridge.responds(to: selector) else { return nil }
        return bridge.perform(selector, with: "WebRTCModule")?.takeUnretainedValue() as? NSObject
    }

    // MARK: - Helpers

    private func onControlQueue<T>(closure: @escaping () -> T) async -> T {
        return await withCheckedContinuation { continuation in
            controlQueue.async {
                continuation.resume(returning: closure())
            }
        }
    }

    private func onControlQueue<T>(closure: @escaping () async -> T) async -> T {
        return await withCheckedContinuation { continuation in
            self.controlQueue.async {
                Task {
                    let result = await closure()
                    continuation.resume(returning: result)
                }
            }
        }
    }

    private func loadImage(uri: String) async -> UIImage? {
        if uri.hasPrefix("http://") || uri.hasPrefix("https://"),
           let url = URL(string: uri) {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                return UIImage(data: data)
            } catch {
                return nil
            }
        } else if uri.hasPrefix("file://") {
            return UIImage(contentsOfFile: String(uri.dropFirst(7)))
        } else {
            let name = ((uri as NSString).lastPathComponent as NSString).deletingPathExtension
            return UIImage(named: name)
        }
    }

    private func authErrorMessage(_ status: AuthStatus) -> String {
        switch status {
        case .expired: return "License expired"
        case .inactive: return "License is inactive"
        default: return "Unknown authorization error"
        }
    }
}
