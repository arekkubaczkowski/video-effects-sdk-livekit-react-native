package expo.modules.videoeffectssdkreactnative

import android.content.Context
import android.graphics.Bitmap
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import com.effectssdk.tsvb.pipeline.CameraPipeline
import com.effectssdk.tsvb.pipeline.OnFrameAvailableListener
import org.webrtc.CameraEnumerator
import org.webrtc.CameraVideoCapturer
import org.webrtc.CapturerObserver
import org.webrtc.NV21Buffer
import org.webrtc.SurfaceTextureHelper
import org.webrtc.VideoFrame
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.ExecutorService
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Custom VideoCapturer that uses Effects SDK's CameraPipeline.
 * CameraPipeline owns the camera and delivers processed Bitmap frames
 * via OnFrameAvailableListener.
 *
 * Threading:
 * - [capturerObserver] is set once during initialize() and read on the SDK's frame-emit
 *   thread (via frameListener) and on the SDK's pipeline-init thread (via onPipelineReady
 *   async callback); volatile gives cross-thread visibility and lets us check for
 *   "capturer disposed" inside the async callback.
 * - Pipeline callbacks arrive on the SDK's internal thread (SDK manages its own GL thread)
 * - [isPipelineActive] is volatile for cross-thread visibility
 * - NV21 buffer is pre-allocated and reused (same resolution = same size)
 */
class TsvbCapturer(
    @Volatile private var device: String,
    private val eventsHandler: CameraVideoCapturer.CameraEventsHandler,
    private val enumerator: CameraEnumerator,
    private val manager: TsvbManager
) : CameraVideoCapturer {

    companion object {
        private const val TAG = "TsvbCapturer"

        // If the effects pipeline reports "started" but never emits a first frame within
        // this window, we treat it as the deterministic PowerVR / Tensor-G5 silent stall and
        // swap to the standard camera. Tunable; kept well under the JS-side 8s camera guard.
        private const val FIRST_FRAME_WATCHDOG_MS = 3000L

        // The watchdog samples frame arrival at this cadence across the window above, so the
        // "0 frames" verdict is confirmed by repeated checks rather than a single timer.
        private const val WATCHDOG_CHECK_INTERVAL_MS = 500L

        // dispose() joins the watchdog thread (bounded) so no in-flight tick can drive a
        // fallback after the capturer's refs are nulled.
        private const val WATCHDOG_JOIN_TIMEOUT_MS = 1000L

        // DEBUG/TEST ONLY (debug/force-frame-stall branch): drop every pipeline frame so
        // hasLoggedFirstFrame never sets — forces the silent-stall watchdog→fallback path on a
        // HEALTHY device, mirroring the Pixel 10 zero-frames stall. Never merge to lite/main.
        private const val DEBUG_FORCE_FRAME_STALL = true
    }

    // capturerObserver is read on the SDK's frame-emit thread (frameListener) and on the
    // SDK's pipeline-init thread (onPipelineReady callback); volatile gives the necessary
    // cross-thread visibility and lets us check for "capturer disposed" inside the callback.
    @Volatile
    private var capturerObserver: CapturerObserver? = null
    // Read on the watchdog HandlerThread (via startFallbackCapturer) and the SDK init thread;
    // written on the WebRTC init thread — @Volatile gives the cross-thread happens-before so
    // the watchdog can't read a stale null and send the fallback into onCameraError.
    @Volatile
    private var surfaceTextureHelper: SurfaceTextureHelper? = null
    @Volatile
    private var context: Context? = null

    @Volatile
    private var isPipelineActive = false

    // Fallback: standard camera capturer used if Effects SDK pipeline fails
    private var fallbackCapturer: CameraVideoCapturer? = null
    @Volatile
    var isUsingFallback = false
        private set

    // Capture parameters — set synchronously by startCapture(), read on the SDK frame thread
    @Volatile
    private var currentWidth = 1280
    @Volatile
    private var currentHeight = 720
    @Volatile
    private var currentFps = 30

    // Pre-allocated buffers for frame conversion (reused across frames)
    private var nv21Buffer: ByteArray? = null
    private var argbBuffer: IntArray? = null
    private var nv21Width = 0
    private var nv21Height = 0

    // Frame dropping: skip frame if previous is still being processed
    @Volatile
    private var isProcessingFrame = false

    // One-time log when first frame arrives — diagnoses pipeline-started-but-stuck cases
    @Volatile
    private var hasLoggedFirstFrame = false

    // Frame-arrival watchdog: armed when the pipeline reports ready, cancelled on the first
    // frame. If it fires, the pipeline stalled silently (no frames, no exception) and we swap
    // to the standard camera. Runs on its own HandlerThread; transitions under synchronized(this).
    @Volatile
    private var watchdogThread: HandlerThread? = null
    @Volatile
    private var watchdogHandler: Handler? = null
    @Volatile
    private var watchdogArmedAtMs = 0L

    // At-most-once-per-session latch for the effects→standard-camera transition (teardown +
    // JS notification). The standard-camera (re)start itself is restart-safe and not gated by this.
    private val fallbackTriggered = AtomicBoolean(false)

    // Frame capture
    @Volatile
    var isFrameCaptureEnabled = false
        private set
    @Volatile
    private var captureIntervalMs: Long = 5000
    @Volatile
    private var lastCaptureTimeMs: Long = 0
    var onFrameCaptured: ((filePath: String, width: Int, height: Int, timestamp: Double) -> Unit)? = null
    private var captureExecutor: ExecutorService? = null
    @Volatile
    private var lastCapturedFilePath: String? = null

    fun startFrameCapture(intervalMs: Long, executor: ExecutorService) {
        captureIntervalMs = intervalMs
        lastCaptureTimeMs = 0
        captureExecutor = executor
        isFrameCaptureEnabled = true
    }

    fun stopFrameCapture() {
        isFrameCaptureEnabled = false
        captureExecutor = null
    }

    // Frame listener for CameraPipeline output
    private val frameListener = OnFrameAvailableListener { bitmap, timestamp ->
        // DEBUG/TEST: simulate the zero-frames stall by dropping every frame before it can set
        // hasLoggedFirstFrame, so the watchdog fires at FIRST_FRAME_WATCHDOG_MS exactly as on the
        // affected device. Gated by DEBUG_FORCE_FRAME_STALL (debug/force-frame-stall branch only).
        if (DEBUG_FORCE_FRAME_STALL) return@OnFrameAvailableListener
        if (!isPipelineActive) return@OnFrameAvailableListener
        val observer = capturerObserver ?: return@OnFrameAvailableListener

        if (!hasLoggedFirstFrame) {
            // Set the flag under the same monitor triggerEffectsFallback uses, so a first frame
            // landing at the timeout boundary deterministically beats the watchdog.
            val isFirst = synchronized(this) {
                if (hasLoggedFirstFrame) {
                    false
                } else {
                    hasLoggedFirstFrame = true
                    true
                }
            }
            if (isFirst) {
                Log.i(TAG, "First frame received: ${bitmap.width}x${bitmap.height}")
                // Never re-armed for this instance — reclaim the thread now instead of parking
                // it idle until dispose. No join on the frame hot path.
                quitFrameWatchdog(joinThread = false)
            }
        }

        // Drop frame if previous conversion is still in progress (prevents backpressure lag)
        if (isProcessingFrame) return@OnFrameAvailableListener
        isProcessingFrame = true

        try {
            val width = bitmap.width
            val height = bitmap.height

            // Report actual output dimensions to manager (for background image sizing)
            if (width != manager.captureWidth || height != manager.captureHeight) {
                manager.setCaptureSize(width, height)
                Log.d(TAG, "Capture size updated: ${width}x${height}")
            }

            // Periodic frame capture
            if (isFrameCaptureEnabled) {
                val nowMs = System.currentTimeMillis()
                if (lastCaptureTimeMs == 0L || (nowMs - lastCaptureTimeMs) >= captureIntervalMs) {
                    lastCaptureTimeMs = nowMs
                    saveBitmapAsJpeg(bitmap, width, height)
                }
            }

            val flip = isFrontFacing()

            val nv21 = getNv21Buffer(width, height)
            val argb = getArgbBuffer(width, height)
            bitmap.getPixels(argb, 0, width, 0, 0, width, height)
            argbToNv21(argb, nv21, width, height, flip)

            val buffer = NV21Buffer(nv21, width, height, null)
            val frame = VideoFrame(buffer, 0, timestamp * 1_000_000)
            observer.onFrameCaptured(frame)
            frame.release()
        } catch (e: Exception) {
            Log.e(TAG, "Error processing frame", e)
        } finally {
            isProcessingFrame = false
        }
    }

    private fun saveBitmapAsJpeg(bitmap: Bitmap, width: Int, height: Int) {
        val copy = bitmap.copy(Bitmap.Config.ARGB_8888, false) ?: return
        val executor = captureExecutor ?: return
        executor.submit {
            try {
                lastCapturedFilePath?.let { File(it).delete() }

                val timestamp = System.currentTimeMillis().toDouble()
                val dir = File(context?.cacheDir, "captured_frames")
                dir.mkdirs()
                val file = File(dir, "frame_${timestamp.toLong()}.jpg")
                FileOutputStream(file).use { out ->
                    copy.compress(Bitmap.CompressFormat.JPEG, 80, out)
                }
                copy.recycle()
                lastCapturedFilePath = file.absolutePath
                onFrameCaptured?.invoke(file.absolutePath, width, height, timestamp)
            } catch (e: Exception) {
                copy.recycle()
                Log.e(TAG, "Failed to save captured frame", e)
            }
        }
    }

    // MARK: - CameraVideoCapturer implementation

    override fun initialize(
        surfaceTextureHelper: SurfaceTextureHelper?,
        context: Context?,
        observer: CapturerObserver?
    ) {
        this.surfaceTextureHelper = surfaceTextureHelper
        this.context = context
        this.capturerObserver = observer
        // Note: we no longer hand WebRTC's GL handler to TsvbManager — async SDK API
        // manages its own GL/EGL thread internally.
        Log.d(TAG, "Initialized with device: $device")
    }

    override fun startCapture(width: Int, height: Int, fps: Int) {
        currentWidth = width
        currentHeight = height
        currentFps = fps

        // Clean up previous fallback if any
        stopFallbackCapturer()

        Log.d(TAG, "startCapture: ${width}x${height}@${fps}fps, device=$device")

        // No GL-thread marshalling — TSVB SDK 2.14+ `createCameraPipelineAsync` runs
        // GL/Camera2 init on the SDK's own dedicated thread (its own EGL context current).
        // Our previous workaround posted onto WebRTC's `SurfaceTextureHelper.handler`,
        // which carries the WRONG EGL context (WebRTC's shared one, not MediaPipe's) and
        // additionally gets queued behind remote-frame rendering on JOIN flows — exposing
        // a timing window that silently breaks MediaPipe's frame-listener wiring on
        // Pixel 10 / Android 16. Letting the SDK manage its own thread fixes both.
        manager.getOrCreatePipelineAsync(width, height, device) { pipeline ->
            onPipelineReady(pipeline, width, height, fps)
        }
    }

    private fun onPipelineReady(pipeline: CameraPipeline?, width: Int, height: Int, fps: Int) {
        // By the time the async callback fires, dispose() may have nulled refs.
        // Bail out instead of calling onCameraOpening() on a dead capturer.
        if (capturerObserver == null) {
            Log.w(TAG, "onPipelineReady: capturer disposed before pipeline init — skipping")
            return
        }

        if (pipeline == null) {
            if (isUsingFallback) {
                // Already fell back this session; a stop/start cycle just needs the standard
                // camera brought back up (it was disposed in stopCapture).
                Log.d(TAG, "onPipelineReady: null pipeline while already on fallback — restarting standard camera")
                startFallbackCapturer(width, height, fps)
            } else {
                Log.e(TAG, "Effects SDK pipeline failed — falling back to standard camera")
                triggerEffectsFallback("nullPipeline", width, height, fps)
            }
            return
        }

        pipeline.setOnFrameAvailableListener(frameListener)
        // Only call startPipeline on first creation — pipeline stays running across stop/start
        if (!manager.isPipelineRunning) {
            try {
                Log.i(TAG, "Calling pipeline.startPipeline()")
                pipeline.startPipeline()
                manager.isPipelineRunning = true
                Log.i(TAG, "Pipeline started (first time)")
            } catch (e: Throwable) {
                Log.e(TAG, "pipeline.startPipeline() threw — releasing and falling back", e)
                pipeline.setOnFrameAvailableListener(null)
                triggerEffectsFallback("startPipelineThrew", width, height, fps)
                return
            }
        } else {
            Log.d(TAG, "Pipeline already running, reattached listener")
        }
        // A concurrent watchdog/teardown may have latched the fallback while this callback was
        // in flight — never resurrect a released pipeline.
        if (isUsingFallback) {
            Log.w(TAG, "onPipelineReady: fallback already latched — skipping activation")
            return
        }
        isPipelineActive = true
        eventsHandler.onCameraOpening(device)
        Log.i(TAG, "onCameraOpening dispatched to LiveKit")

        // Arm the silent-stall detector. No-ops on a healthy reattach (this instance already
        // logged a first frame) and when already on fallback.
        armFrameWatchdog()
    }

    override fun stopCapture() {
        Log.d(TAG, "stopCapture")
        // A deliberate stop is not a stall — drop any pending watchdog before frames stop.
        cancelFrameWatchdog()
        isPipelineActive = false
        manager.onCapturerStopped()
        stopFallbackCapturer()
    }

    override fun changeCaptureFormat(width: Int, height: Int, fps: Int) {
        Log.d(TAG, "changeCaptureFormat: ${width}x${height}@${fps}fps")
        stopCapture()
        startCapture(width, height, fps)
    }

    override fun dispose() {
        Log.d(TAG, "dispose")
        quitFrameWatchdog(joinThread = true)
        isPipelineActive = false
        manager.onCapturerStopped()
        fallbackCapturer?.dispose()
        fallbackCapturer = null
        capturerObserver = null
        surfaceTextureHelper = null
        context = null
    }

    override fun isScreencast(): Boolean = false

    // MARK: - Camera switching

    override fun switchCamera(handler: CameraVideoCapturer.CameraSwitchHandler?) {
        val deviceNames = enumerator.getDeviceNames()
        val currentIsFront = isFrontFacing()

        for (name in deviceNames) {
            try {
                val nameIsFront = enumerator.isFrontFacing(name)
                if (nameIsFront != currentIsFront) {
                    switchCamera(handler, name)
                    return
                }
            } catch (e: Exception) {
                Log.w(TAG, "Error checking device $name", e)
            }
        }

        handler?.onCameraSwitchError("No opposite camera found")
    }

    override fun switchCamera(handler: CameraVideoCapturer.CameraSwitchHandler?, deviceName: String?) {
        if (deviceName == null) {
            handler?.onCameraSwitchError("Device name is null")
            return
        }

        // Skip no-op switch to same device
        if (deviceName == device) {
            Log.d(TAG, "switchCamera skipped — already on device: $deviceName")
            handler?.onCameraSwitchDone(isFrontFacing())
            return
        }

        Log.d(TAG, "switchCamera to: $deviceName")

        // If using fallback, delegate switch to fallback capturer
        if (isUsingFallback && fallbackCapturer != null) {
            fallbackCapturer?.switchCamera(handler, deviceName)
            device = deviceName
            return
        }

        device = deviceName
        manager.switchCamera(deviceName)
        handler?.onCameraSwitchDone(isFrontFacing())
        Log.d(TAG, "Camera switched to: $deviceName")
    }

    fun getCurrentDevice(): String = device

    // MARK: - Fallback

    private fun stopFallbackCapturer() {
        fallbackCapturer?.stopCapture()
        fallbackCapturer?.dispose()
        fallbackCapturer = null
    }

    /**
     * If Effects SDK pipeline fails to create, fall back to standard camera capturer.
     * User gets camera without effects — better than black screen.
     */
    private fun startFallbackCapturer(width: Int, height: Int, fps: Int) {
        try {
            val capturer = enumerator.createCapturer(device, eventsHandler)
            if (capturer != null && surfaceTextureHelper != null && context != null) {
                capturer.initialize(surfaceTextureHelper, context, capturerObserver)
                capturer.startCapture(width, height, fps)
                fallbackCapturer = capturer
                Log.w(TAG, "Fallback capturer started — camera works without effects")
            } else {
                Log.e(TAG, "Fallback capturer creation failed — camera unavailable")
                eventsHandler.onCameraError("Both Effects SDK and fallback camera failed")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Fallback capturer exception", e)
            eventsHandler.onCameraError("Fallback camera failed: ${e.message}")
        }
    }

    // MARK: - Frame watchdog

    /**
     * Arms the first-frame watchdog at the end of a successful onPipelineReady. No-op if a
     * frame already arrived on this instance, if we're already on fallback, or if the capturer
     * was disposed. Lazily spins up the dedicated HandlerThread.
     */
    private fun armFrameWatchdog() {
        synchronized(this) {
            if (hasLoggedFirstFrame || isUsingFallback || capturerObserver == null) return
            if (watchdogThread == null) {
                watchdogThread = HandlerThread("TsvbFrameWatchdog").apply { start() }
                watchdogHandler = Handler(watchdogThread!!.looper)
            }
            watchdogHandler?.removeCallbacksAndMessages(null)
            watchdogArmedAtMs = System.currentTimeMillis()
            watchdogHandler?.postDelayed({ frameWatchdogTick() }, WATCHDOG_CHECK_INTERVAL_MS)
            Log.d(TAG, "Frame watchdog armed — sampling every ${WATCHDOG_CHECK_INTERVAL_MS}ms up to ${FIRST_FRAME_WATCHDOG_MS}ms")
        }
    }

    /** Cancels a pending watchdog without tearing down the thread (first frame / deliberate stop). */
    private fun cancelFrameWatchdog() {
        synchronized(this) {
            watchdogHandler?.removeCallbacksAndMessages(null)
        }
    }

    /**
     * Cancels the watchdog and reclaims its thread. When [joinThread] is true (dispose path),
     * waits (bounded) for any in-flight tick to finish so no fallback can run after the
     * capturer's refs are nulled. Joins OUTSIDE the monitor so a tick blocked on
     * synchronized(this) can still complete.
     */
    private fun quitFrameWatchdog(joinThread: Boolean) {
        val thread = synchronized(this) {
            watchdogHandler?.removeCallbacksAndMessages(null)
            val t = watchdogThread
            watchdogThread = null
            watchdogHandler = null
            t
        }
        thread?.quitSafely()
        if (joinThread && thread != null) {
            try {
                thread.join(WATCHDOG_JOIN_TIMEOUT_MS)
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }
    }

    /**
     * Runs every [WATCHDOG_CHECK_INTERVAL_MS] on the watchdog looper. Disarms the moment a
     * frame has arrived; once the full [FIRST_FRAME_WATCHDOG_MS] window has elapsed with still
     * zero frames, it concludes the pipeline silently stalled and triggers the fallback.
     */
    private fun frameWatchdogTick() {
        if (hasLoggedFirstFrame || isUsingFallback || capturerObserver == null) {
            // A frame arrived, we already fell back, or the capturer is gone — stop sampling.
            return
        }
        val elapsed = System.currentTimeMillis() - watchdogArmedAtMs
        if (elapsed >= FIRST_FRAME_WATCHDOG_MS) {
            Log.e(TAG, "Frame watchdog: still 0 frames after ${elapsed}ms — pipeline stalled, falling back")
            triggerEffectsFallback("frameTimeout", currentWidth, currentHeight, currentFps)
            return
        }
        Log.d(TAG, "Frame watchdog: 0 frames at ${elapsed}ms — re-checking in ${WATCHDOG_CHECK_INTERVAL_MS}ms")
        synchronized(this) {
            // Reschedule only if nothing disarmed us in the meantime.
            if (watchdogHandler != null && !hasLoggedFirstFrame && !isUsingFallback && capturerObserver != null) {
                watchdogHandler?.postDelayed({ frameWatchdogTick() }, WATCHDOG_CHECK_INTERVAL_MS)
            }
        }
    }

    /**
     * One-time transition from the effects pipeline to the standard camera: closes the frame
     * gate, releases the stalled pipeline, brings up the standard capturer, and pushes the
     * native→JS "effects unavailable" event. Idempotent per capturer instance via
     * [fallbackTriggered]; the standard-camera (re)start on later stop/start cycles is handled
     * by the onPipelineReady null-path, not here.
     */
    private fun triggerEffectsFallback(reason: String, width: Int, height: Int, fps: Int) {
        synchronized(this) {
            // First frame won the race (its flag is set under this same monitor), or the
            // capturer is gone — nothing to fall back from. Check + claim the latch + close the
            // frame gate ATOMICALLY so a first frame arriving at the timeout boundary
            // deterministically blocks the swap (no slow-but-healthy device downgrade).
            if (hasLoggedFirstFrame || capturerObserver == null) return
            if (!fallbackTriggered.compareAndSet(false, true)) return
            isPipelineActive = false
            isUsingFallback = true
        }
        Log.e(TAG, "Effects fallback ($reason) — switching to standard camera")
        // SDK + camera work runs OUTSIDE the monitor — releasePipeline takes the manager lock
        // and must not nest under 'this' (preserves the no-SDK-calls-under-a-lock discipline).
        manager.releasePipeline()
        startFallbackCapturer(width, height, fps)
        manager.notifyEffectsUnavailable(reason)
    }

    // MARK: - Helpers

    private fun isFrontFacing(): Boolean {
        return try {
            enumerator.isFrontFacing(device)
        } catch (e: Exception) {
            device.contains("front", ignoreCase = true) || device == "1"
        }
    }

    /**
     * Returns a reusable NV21 byte array for the given dimensions.
     */
    private fun getNv21Buffer(width: Int, height: Int): ByteArray {
        if (nv21Buffer == null || nv21Width != width || nv21Height != height) {
            val size = width * height + 2 * (width / 2) * (height / 2)
            nv21Buffer = ByteArray(size)
            nv21Width = width
            nv21Height = height
        }
        return nv21Buffer!!
    }

    /**
     * Returns a reusable ARGB int array for the given dimensions.
     */
    private fun getArgbBuffer(width: Int, height: Int): IntArray {
        val needed = width * height
        if (argbBuffer == null || argbBuffer!!.size < needed) {
            argbBuffer = IntArray(needed)
        }
        return argbBuffer!!
    }

    /**
     * Converts pre-extracted ARGB pixels to NV21 (YUV420SP) format.
     * Handles horizontal flip inline (no separate Bitmap allocation).
     */
    private fun argbToNv21(argb: IntArray, nv21: ByteArray, width: Int, height: Int, flipH: Boolean) {
        val frameSize = width * height
        var yIndex = 0
        var uvIndex = frameSize

        for (j in 0 until height) {
            for (i in 0 until width) {
                val srcX = if (flipH) (width - 1 - i) else i
                val pixel = argb[j * width + srcX]
                val r = (pixel shr 16) and 0xFF
                val g = (pixel shr 8) and 0xFF
                val b = pixel and 0xFF

                val y = ((66 * r + 129 * g + 25 * b + 128) shr 8) + 16
                nv21[yIndex++] = y.coerceIn(0, 255).toByte()

                if (j % 2 == 0 && i % 2 == 0) {
                    val v = ((112 * r - 94 * g - 18 * b + 128) shr 8) + 128
                    val u = ((-38 * r - 74 * g + 112 * b + 128) shr 8) + 128
                    nv21[uvIndex++] = v.coerceIn(0, 255).toByte()
                    nv21[uvIndex++] = u.coerceIn(0, 255).toByte()
                }
            }
        }
    }
}
