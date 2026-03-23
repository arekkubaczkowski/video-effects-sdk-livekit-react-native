package expo.modules.videoeffectssdkreactnative

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Matrix
import android.util.Log
import com.effectssdk.tsvb.pipeline.OnFrameAvailableListener
import org.webrtc.CameraEnumerator
import org.webrtc.CameraVideoCapturer
import org.webrtc.CapturerObserver
import org.webrtc.NV21Buffer
import org.webrtc.SurfaceTextureHelper
import org.webrtc.VideoFrame

/**
 * Custom VideoCapturer that uses Effects SDK's CameraPipeline.
 * CameraPipeline owns the camera and delivers processed Bitmap frames
 * via OnFrameAvailableListener.
 *
 * Threading:
 * - [capturerObserver] is set once during initialize() and never changes
 * - Pipeline callbacks arrive on the SDK's internal thread
 * - [isPipelineActive] is volatile for cross-thread visibility
 * - NV21 buffer is pre-allocated and reused (same resolution = same size)
 */
class TsvbCapturer(
    private var device: String,
    private val eventsHandler: CameraVideoCapturer.CameraEventsHandler,
    private val enumerator: CameraEnumerator,
    private val manager: TsvbManager
) : CameraVideoCapturer {

    companion object {
        private const val TAG = "TsvbCapturer"
    }

    private var capturerObserver: CapturerObserver? = null
    private var context: Context? = null

    @Volatile
    private var isPipelineActive = false

    private var currentWidth = 1280
    private var currentHeight = 720
    private var currentFps = 30

    // Pre-allocated NV21 buffer for frame conversion (reused across frames)
    private var nv21Buffer: ByteArray? = null
    private var nv21Width = 0
    private var nv21Height = 0

    // Frame listener for CameraPipeline output
    private val frameListener = OnFrameAvailableListener { bitmap, timestamp ->
        if (!isPipelineActive) return@OnFrameAvailableListener

        val observer = capturerObserver ?: return@OnFrameAvailableListener

        try {
            // Flip horizontally for front camera
            val processedBitmap = if (isFrontFacing()) {
                flipBitmapHorizontally(bitmap)
            } else {
                bitmap
            }

            val width = processedBitmap.width
            val height = processedBitmap.height

            // Reuse or allocate NV21 buffer
            val nv21 = getNv21Buffer(width, height)
            bitmapToNv21(processedBitmap, nv21, width, height)

            val buffer = NV21Buffer(nv21, width, height) {
                if (processedBitmap !== bitmap) {
                    processedBitmap.recycle()
                }
            }

            val frame = VideoFrame(buffer, 0, timestamp * 1_000_000)
            observer.onFrameCaptured(frame)
            frame.release()
        } catch (e: Exception) {
            Log.e(TAG, "Error processing frame", e)
        }
    }

    // MARK: - CameraVideoCapturer implementation

    override fun initialize(
        surfaceTextureHelper: SurfaceTextureHelper?,
        context: Context?,
        observer: CapturerObserver?
    ) {
        this.context = context
        this.capturerObserver = observer
        Log.d(TAG, "Initialized with device: $device")
    }

    override fun startCapture(width: Int, height: Int, fps: Int) {
        currentWidth = width
        currentHeight = height
        currentFps = fps

        Log.d(TAG, "startCapture: ${width}x${height}@${fps}fps, device=$device")

        val pipeline = manager.createPipeline(width, height, device)
        if (pipeline != null) {
            pipeline.setOnFrameAvailableListener(frameListener)
            pipeline.startPipeline()
            isPipelineActive = true
            eventsHandler.onCameraOpening(device)
            Log.d(TAG, "Pipeline started")
        } else {
            Log.e(TAG, "Failed to create pipeline")
        }
    }

    override fun stopCapture() {
        Log.d(TAG, "stopCapture")
        isPipelineActive = false
        manager.releasePipeline()
    }

    override fun changeCaptureFormat(width: Int, height: Int, fps: Int) {
        Log.d(TAG, "changeCaptureFormat: ${width}x${height}@${fps}fps")
        stopCapture()
        startCapture(width, height, fps)
    }

    override fun dispose() {
        Log.d(TAG, "dispose")
        isPipelineActive = false
        manager.releasePipeline()
        capturerObserver = null
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

        Log.d(TAG, "switchCamera to: $deviceName")

        isPipelineActive = false
        manager.releasePipeline()

        device = deviceName

        val pipeline = manager.createPipeline(currentWidth, currentHeight, device)
        if (pipeline != null) {
            pipeline.setOnFrameAvailableListener(frameListener)
            pipeline.startPipeline()
            isPipelineActive = true
            handler?.onCameraSwitchDone(isFrontFacing())
            Log.d(TAG, "Camera switched to: $deviceName")
        } else {
            handler?.onCameraSwitchError("Failed to create pipeline for $deviceName")
        }
    }

    fun getCurrentDevice(): String = device

    // MARK: - Helpers

    private fun isFrontFacing(): Boolean {
        return try {
            enumerator.isFrontFacing(device)
        } catch (e: Exception) {
            device.contains("front", ignoreCase = true) || device == "1"
        }
    }

    private fun flipBitmapHorizontally(source: Bitmap): Bitmap {
        val matrix = Matrix().apply { preScale(-1f, 1f) }
        return Bitmap.createBitmap(source, 0, 0, source.width, source.height, matrix, false)
    }

    /**
     * Returns a reusable NV21 byte array for the given dimensions.
     * Allocates a new one only if dimensions changed.
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
     * Converts ARGB Bitmap to NV21 (YUV420SP) format.
     * Writes directly into the provided byte array.
     */
    private fun bitmapToNv21(bitmap: Bitmap, nv21: ByteArray, width: Int, height: Int) {
        val argb = IntArray(width * height)
        bitmap.getPixels(argb, 0, width, 0, 0, width, height)

        val frameSize = width * height
        var yIndex = 0
        var uvIndex = frameSize

        for (j in 0 until height) {
            for (i in 0 until width) {
                val pixel = argb[j * width + i]
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
