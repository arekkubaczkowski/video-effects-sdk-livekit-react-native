package expo.modules.videoeffectssdkreactnative

import android.content.Context
import android.graphics.Bitmap
import android.util.Log
import android.util.Size
import com.effectssdk.tsvb.Camera
import com.effectssdk.tsvb.EffectsSDK
import com.effectssdk.tsvb.EffectsSDKStatus
import com.effectssdk.tsvb.pipeline.CameraPipeline
import com.effectssdk.tsvb.pipeline.ColorCorrectionMode
import com.effectssdk.tsvb.pipeline.PipelineMode
import com.effectssdk.tsvb.pipeline.SegmentationMode
import java.net.URL

/**
 * Manages the Effects SDK lifecycle and CameraPipeline.
 * All pipeline mutations are synchronized via [lock].
 */
class TsvbManager(private val context: Context) {

    companion object {
        private const val TAG = "TsvbManager"
    }

    // State
    @Volatile var isInitialized = false
        private set
    @Volatile var isBlurEnabled = false
        private set
    @Volatile var isReplaceBackgroundEnabled = false
        private set

    private val lock = Any()
    private var cameraPipeline: CameraPipeline? = null
    private var tsvbCapturer: TsvbCapturer? = null
    private val optionsCache = EffectsSdkOptionsCache()

    // MARK: - Initialization

    fun initialize(customerID: String, trackId: String, callback: (Map<String, Any>) -> Unit) {
        if (isInitialized) {
            callback(mapOf("success" to true, "status" to "already_initialized"))
            return
        }

        try {
            EffectsSDK.initialize(context, customerID) { status ->
                when (status) {
                    EffectsSDKStatus.ACTIVE -> {
                        synchronized(lock) {
                            isInitialized = true
                            registerCapturerFactory()
                        }
                        Log.d(TAG, "Effects SDK initialized successfully")
                        callback(mapOf("success" to true, "status" to "active"))
                    }
                    else -> {
                        Log.e(TAG, "Effects SDK initialization failed: $status")
                        callback(mapOf("success" to false, "error" to "SDK status: $status"))
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Effects SDK initialization error", e)
            callback(mapOf("success" to false, "error" to e.message.orEmpty()))
        }
    }

    // MARK: - Effects Control

    fun enableBlurBackground(power: Float, callback: (Map<String, Any>) -> Unit) {
        synchronized(lock) {
            val pipeline = cameraPipeline
            if (pipeline == null) {
                callback(mapOf("success" to false, "error" to "Pipeline not created yet"))
                return
            }

            try {
                pipeline.setMode(PipelineMode.BLUR)
                pipeline.setBlurPower(power)
                optionsCache.pipelineMode = PipelineMode.BLUR
                optionsCache.blurPower = power
                isBlurEnabled = true
                isReplaceBackgroundEnabled = false
                callback(mapOf("success" to true))
            } catch (e: Exception) {
                callback(mapOf("success" to false, "error" to e.message.orEmpty()))
            }
        }
    }

    fun disableBlurBackground(callback: (Map<String, Any>) -> Unit) {
        synchronized(lock) {
            val pipeline = cameraPipeline
            if (pipeline == null) {
                callback(mapOf("success" to true))
                return
            }

            try {
                pipeline.setMode(PipelineMode.NO_EFFECT)
                optionsCache.pipelineMode = PipelineMode.NO_EFFECT
                isBlurEnabled = false
                callback(mapOf("success" to true))
            } catch (e: Exception) {
                callback(mapOf("success" to false, "error" to e.message.orEmpty()))
            }
        }
    }

    fun enableReplaceBackground(assetSource: Map<String, Any>?, callback: (Map<String, Any>) -> Unit) {
        synchronized(lock) {
            val pipeline = cameraPipeline
            if (pipeline == null) {
                callback(mapOf("success" to false, "error" to "Pipeline not created yet"))
                return
            }

            try {
                pipeline.setMode(PipelineMode.REPLACE)
                optionsCache.pipelineMode = PipelineMode.REPLACE

                // Load background image if provided
                if (assetSource != null) {
                    val uri = assetSource["uri"] as? String
                    if (uri != null) {
                        Thread {
                            try {
                                val bitmap = loadBitmapFromUri(uri)
                                if (bitmap != null) {
                                    synchronized(lock) {
                                        cameraPipeline?.setBackground(bitmap)
                                        optionsCache.backgroundBitmap = bitmap
                                    }
                                }
                            } catch (e: Exception) {
                                Log.e(TAG, "Failed to load background image", e)
                            }
                        }.start()
                    }
                }

                isReplaceBackgroundEnabled = true
                isBlurEnabled = false
                callback(mapOf("success" to true))
            } catch (e: Exception) {
                callback(mapOf("success" to false, "error" to e.message.orEmpty()))
            }
        }
    }

    fun disableReplaceBackground(callback: (Map<String, Any>) -> Unit) {
        synchronized(lock) {
            val pipeline = cameraPipeline
            if (pipeline == null) {
                callback(mapOf("success" to true))
                return
            }

            try {
                pipeline.setMode(PipelineMode.NO_EFFECT)
                optionsCache.pipelineMode = PipelineMode.NO_EFFECT
                isReplaceBackgroundEnabled = false
                callback(mapOf("success" to true))
            } catch (e: Exception) {
                callback(mapOf("success" to false, "error" to e.message.orEmpty()))
            }
        }
    }

    // MARK: - Pipeline Lifecycle (called by TsvbCapturer)

    fun createPipeline(width: Int, height: Int, cameraName: String): CameraPipeline? {
        synchronized(lock) {
            try {
                val factory = EffectsSDK.createSDKFactory()
                val camera = detectCamera(cameraName)
                val emptyBitmap = Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888)
                val pipeline = factory.createCameraPipeline(
                    context,
                    optionsCache.pipelineMode,
                    SegmentationMode.AUTO,
                    optionsCache.colorCorrectionMode,
                    optionsCache.backgroundBitmap ?: emptyBitmap,
                    optionsCache.colorGradingReference ?: emptyBitmap,
                    0, // segmentationGap
                    0, // faceDetectionGap
                    optionsCache.blurPower,
                    optionsCache.beautificationPower,
                    optionsCache.isBeautificationEnabled,
                    null, // FPSListener
                    null, // OrientationChangeListener
                    Size(width, height),
                    camera
                )
                cameraPipeline = pipeline
                return pipeline
            } catch (e: Exception) {
                Log.e(TAG, "Failed to create pipeline", e)
                return null
            }
        }
    }

    fun releasePipeline() {
        synchronized(lock) {
            cameraPipeline?.release()
            cameraPipeline = null
        }
    }

    fun getCurrentPipeline(): CameraPipeline? {
        return cameraPipeline
    }

    // MARK: - Capturer Registration (via reflection to avoid compile-time dependency on fork)

    private fun registerCapturerFactory() {
        try {
            val providerClass = Class.forName("com.oney.WebRTCModule.videoEffects.CapturerProvider")
            val factoryInterface = Class.forName("com.oney.WebRTCModule.videoEffects.CapturerFactoryInterface")

            // Create a dynamic proxy implementing CapturerFactoryInterface
            val proxy = java.lang.reflect.Proxy.newProxyInstance(
                factoryInterface.classLoader,
                arrayOf(factoryInterface)
            ) { _, method, args ->
                if (method.name == "createCapturer" && args != null && args.size == 3) {
                    val cameraName = args[0] as String
                    @Suppress("UNCHECKED_CAST")
                    val eventsHandler = args[1] as org.webrtc.CameraVideoCapturer.CameraEventsHandler
                    val enumerator = args[2] as org.webrtc.CameraEnumerator
                    Log.d(TAG, "CapturerProvider creating TsvbCapturer for: $cameraName")
                    val capturer = TsvbCapturer(cameraName, eventsHandler, enumerator, this)
                    tsvbCapturer = capturer
                    capturer
                } else {
                    null
                }
            }

            val setFactoryMethod = providerClass.getMethod("setFactory", factoryInterface)
            setFactoryMethod.invoke(null, proxy)
            Log.d(TAG, "CapturerProvider factory registered")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to register capturer factory — react-native-webrtc fork may not have CapturerProvider", e)
        }
    }

    private fun unregisterCapturerFactory() {
        try {
            val providerClass = Class.forName("com.oney.WebRTCModule.videoEffects.CapturerProvider")
            val removeMethod = providerClass.getMethod("removeFactory")
            removeMethod.invoke(null)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to unregister capturer factory", e)
        }
    }

    // MARK: - Cleanup

    fun cleanup() {
        synchronized(lock) {
            unregisterCapturerFactory()
            tsvbCapturer = null
            releasePipeline()
            isInitialized = false
            isBlurEnabled = false
            isReplaceBackgroundEnabled = false
            optionsCache.reset()
        }
    }

    // MARK: - Helpers

    private fun detectCamera(deviceName: String): Camera {
        return try {
            if (deviceName.contains("front", ignoreCase = true) || deviceName == "1") {
                Camera.FRONT
            } else {
                Camera.BACK
            }
        } catch (e: Exception) {
            Camera.FRONT
        }
    }

    private fun loadBitmapFromUri(uri: String): Bitmap? {
        return try {
            if (uri.startsWith("http://") || uri.startsWith("https://")) {
                val connection = URL(uri).openConnection()
                connection.connect()
                val inputStream = connection.getInputStream()
                android.graphics.BitmapFactory.decodeStream(inputStream)
            } else if (uri.startsWith("file://")) {
                val path = uri.removePrefix("file://")
                android.graphics.BitmapFactory.decodeFile(path)
            } else {
                null
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to load bitmap from: $uri", e)
            null
        }
    }
}
