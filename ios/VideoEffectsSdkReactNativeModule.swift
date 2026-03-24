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
    private var _active: Bool = false

    init(pipeline: Pipeline) {
        self.pipeline = pipeline
        super.init()
    }

    var isActive: Bool {
        os_unfair_lock_lock(&lock)
        let val = _active
        os_unfair_lock_unlock(&lock)
        return val
    }

    func setActive(_ active: Bool) {
        os_unfair_lock_lock(&lock)
        _active = active
        os_unfair_lock_unlock(&lock)
    }

    func processFrame(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        os_unfair_lock_lock(&lock)
        guard _active, let pipeline = pipeline else {
            os_unfair_lock_unlock(&lock)
            return pixelBuffer
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else {
            os_unfair_lock_unlock(&lock)
            return pixelBuffer
        }

        let result = pipeline.process(pixelBuffer: pixelBuffer, metalCompatible: true, error: nil)
        os_unfair_lock_unlock(&lock)
        return result?.toCVPixelBuffer() ?? pixelBuffer
    }

    /// Called under external synchronization (module's control queue).
    func updatePipeline(_ pipeline: Pipeline?) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        self.pipeline = pipeline
    }

    func teardown() {
        os_unfair_lock_lock(&lock)
        _active = false
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

    private var lastReportedWidth: Int32 = 0
    private var lastReportedHeight: Int32 = 0
    var onFrameSizeChanged: ((Int32, Int32) -> Void)?

    /// Called by WebRTC's VideoEffectProcessor on the capture thread.
    @objc func capturer(_ capturer: RTCVideoCapturer, didCaptureVideoFrame frame: RTCVideoFrame) -> RTCVideoFrame {
        // Report frame dimensions to module (for background image cropping)
        let w = frame.width
        let h = frame.height
        if w != lastReportedWidth || h != lastReportedHeight {
            lastReportedWidth = w
            lastReportedHeight = h
            onFrameSizeChanged?(w, h)
        }

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
    private var attachedTrackId: String?

    /// Device orientation reported by JS layer. Used for background image rotation.
    private var currentOrientation: String = "portrait"

    /// Original (unrotated) background image — kept for re-rotation on orientation change.
    private var originalBackgroundImage: UIImage?

    /// Last known camera frame dimensions (landscape buffer). Updated by frame processor.
    private var lastFrameWidth: Int = 0
    private var lastFrameHeight: Int = 0

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

        Function("setDeviceOrientation") { (orientation: String) in
            let changed = self.currentOrientation != orientation
            self.currentOrientation = orientation
            if changed {
                self.reapplyBackgroundForOrientation()
            }
        }
    }

    // MARK: - Initialize

    private func doInitialize(customerID: String, trackId: String) async -> [String: Any] {
        return await onControlQueue { () async -> [String: Any] in
            // If already initialized, just re-attach to new track if needed
            if self.state == .idle || self.state == .active {
                if self.attachedTrackId != trackId {
                    let attachResult = self.attachProcessorToTrack(trackId)
                    return ["success": true, "status": "already_initialized", "attachResult": attachResult]
                }
                return ["success": true, "status": "already_initialized", "attachResult": "already_attached"]
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

                guard let pipeline = factory.newPipeline() else {
                    self.state = .error
                    return ["success": false, "error": "Failed to create pipeline"]
                }
                self.pipeline = pipeline
                self.frameFactory = factory.newFrameFactory()

                if let config = pipeline.copyConfiguration() {
                    config.segmentationPreset = .quality
                    pipeline.setConfiguration(config)
                }

                // Create frame processor (not a singleton — owned by this module instance)
                let fp = TsvbFrameProcessor(pipeline: pipeline)
                self.frameProcessor = fp
                let bridge = TsvbVideoFrameProcessorBridge(processor: fp)
                bridge.onFrameSizeChanged = { [weak self] w, h in
                    self?.lastFrameWidth = Int(w)
                    self?.lastFrameHeight = Int(h)
                }
                self.processorBridge = bridge

                self.state = .idle

                // Attach to track
                let attachResult = self.attachProcessorToTrack(trackId)

                return ["success": true, "status": "active", "attachResult": attachResult]
            } catch {
                self.state = .error
                return ["success": false, "error": error.localizedDescription]
            }
        }
    }

    // MARK: - Effects Control

    private func doEnableBlur(power: Float) async -> [String: Any] {
        return await onControlQueue {
            let currentState = "\(self.state)"
            let hasPipeline = self.pipeline != nil
            let hasProcessor = self.frameProcessor != nil

            guard self.state == .idle || self.state == .active,
                  let pipeline = self.pipeline else {
                return ["success": false, "error": "SDK not initialized", "debug_state": currentState, "debug_hasPipeline": hasPipeline]
            }

            let result = pipeline.enableBlurBackground(power: power)
            guard result == .ok else {
                return ["success": false, "error": "Failed to enable blur, result: \(result)"]
            }

            pipeline.disableReplaceBackground()
            pipeline.disableDenoiseBackground()
            self.blurEnabled = true
            self.replaceBackgroundEnabled = false
            self.replacementController = nil
            self.state = .active
            self.frameProcessor?.setActive(true)

            return [
                "success": true,
                "debug_processorActive": self.frameProcessor?.isActive ?? false,
                "debug_hasProcessor": hasProcessor,
                "debug_attachedTrack": self.attachedTrackId ?? "none",
            ]
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

            if let image = backgroundImage {
                self.originalBackgroundImage = image
                self.applyBackgroundImage(image, to: ctrl)
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
            self.originalBackgroundImage = nil

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

    @discardableResult
    private func attachProcessorToTrack(_ trackId: String) -> String {
        if attachedTrackId != nil && attachedTrackId != trackId {
            detachProcessorFromTrack()
        }

        guard let bridge = processorBridge else {
            NSLog("[VideoEffects Native] processorBridge is nil")
            return "error:no_processor_bridge"
        }

        // Register with ProcessorProvider (static class — works in both bridged and bridgeless mode)
        if let providerClass = NSClassFromString("ProcessorProvider") as? NSObject.Type {
            let addSelector = NSSelectorFromString("addProcessor:forName:")
            if providerClass.responds(to: addSelector) {
                providerClass.perform(addSelector, with: bridge, with: "tsvb")
                attachedTrackId = trackId
                NSLog("[VideoEffects Native] Registered processor with ProcessorProvider, trackId: \(trackId)")
                return "registered:\(trackId)"
            } else {
                NSLog("[VideoEffects Native] ProcessorProvider does not respond to addProcessor:forName:")
                return "error:no_add_method"
            }
        } else {
            NSLog("[VideoEffects Native] ProcessorProvider class not found")
            return "error:no_processor_provider"
        }
    }

    private func detachProcessorFromTrack() {
        guard attachedTrackId != nil else { return }

        if let providerClass = NSClassFromString("ProcessorProvider") as? NSObject.Type {
            let removeSelector = NSSelectorFromString("removeProcessor:")
            if providerClass.responds(to: removeSelector) {
                providerClass.perform(removeSelector, with: "tsvb")
            }
        }

        attachedTrackId = nil
    }

    // MARK: - Helpers

    private func onControlQueue<T>(closure: @escaping () -> T) async -> T {
        return await withCheckedContinuation { continuation in
            controlQueue.async {
                continuation.resume(returning: closure())
            }
        }
    }

    private func applyBackgroundImage(_ image: UIImage, to controller: any ReplacementController) {
        let rotated = Self.rotateForCameraPipeline(image, orientation: currentOrientation)
        guard let factory = self.frameFactory else { return }

        if let data = rotated.jpegData(compressionQuality: 0.9),
           let frame = factory.image(with: data) {
            controller.background = frame
        } else if let data = rotated.pngData(),
                  let frame = factory.image(with: data) {
            controller.background = frame
        }
    }

    /// Center-crop image to target aspect ratio (like CSS object-fit: cover)
    private static func centerCrop(_ image: UIImage, toAspectRatio targetRatio: CGFloat) -> UIImage {
        let imageRatio = image.size.width / image.size.height

        if abs(imageRatio - targetRatio) < 0.01 {
            return image // Already correct aspect ratio
        }

        let cropRect: CGRect
        if imageRatio > targetRatio {
            // Image is wider — crop sides
            let newWidth = image.size.height * targetRatio
            let xOffset = (image.size.width - newWidth) / 2
            cropRect = CGRect(x: xOffset, y: 0, width: newWidth, height: image.size.height)
        } else {
            // Image is taller — crop top/bottom
            let newHeight = image.size.width / targetRatio
            let yOffset = (image.size.height - newHeight) / 2
            cropRect = CGRect(x: 0, y: yOffset, width: image.size.width, height: newHeight)
        }

        // Scale cropRect to pixel coordinates
        let scale = image.scale
        let pixelRect = CGRect(
            x: cropRect.origin.x * scale,
            y: cropRect.origin.y * scale,
            width: cropRect.size.width * scale,
            height: cropRect.size.height * scale
        )

        guard let cgImage = image.cgImage?.cropping(to: pixelRect) else { return image }
        return UIImage(cgImage: cgImage, scale: scale, orientation: image.imageOrientation)
    }

    private func reapplyBackgroundForOrientation() {
        controlQueue.async {
            guard self.replaceBackgroundEnabled,
                  let image = self.originalBackgroundImage,
                  let ctrl = self.replacementController else { return }
            self.applyBackgroundImage(image, to: ctrl)
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
        var image: UIImage?

        if uri.hasPrefix("http://") || uri.hasPrefix("https://"),
           let url = URL(string: uri) {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                image = UIImage(data: data)
            } catch {
                return nil
            }
        } else if uri.hasPrefix("file://") {
            image = UIImage(contentsOfFile: String(uri.dropFirst(7)))
        } else {
            let name = ((uri as NSString).lastPathComponent as NSString).deletingPathExtension
            image = UIImage(named: name)
        }

        return image
    }

    /// Rotate background image to match the camera pipeline's buffer orientation.
    /// SDK treats landscape-left as base orientation. Empirically confirmed:
    /// - portrait:        needs 90° CCW
    /// - landscape-left:  no rotation needed
    /// - landscape-right: needs 180°
    private static func rotateForCameraPipeline(_ image: UIImage, orientation: String) -> UIImage {
        switch orientation {
        case "landscape-left":
            return image
        case "landscape-right":
            return rotateImage(image, angle: .pi, swapDimensions: false)
        default:
            // portrait
            return rotateImage(image, angle: -.pi / 2, swapDimensions: true)
        }
    }

    private static func rotateImage(_ image: UIImage, angle: CGFloat, swapDimensions: Bool) -> UIImage {
        let outputSize = swapDimensions
            ? CGSize(width: image.size.height, height: image.size.width)
            : image.size

        UIGraphicsBeginImageContextWithOptions(outputSize, false, image.scale)
        guard let context = UIGraphicsGetCurrentContext() else { return image }

        context.translateBy(x: outputSize.width / 2, y: outputSize.height / 2)
        context.rotate(by: angle)
        image.draw(in: CGRect(
            x: -image.size.width / 2,
            y: -image.size.height / 2,
            width: image.size.width,
            height: image.size.height
        ))

        let rotated = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return rotated ?? image
    }

    private func authErrorMessage(_ status: AuthStatus) -> String {
        switch status {
        case .expired: return "License expired"
        case .inactive: return "License is inactive"
        default: return "Unknown authorization error"
        }
    }
}
