package expo.modules.videoeffectssdkreactnative

import android.content.Context
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import expo.modules.kotlin.Promise

class VideoEffectsSdkReactNativeModule : Module() {

    private val tsvbManager by lazy {
        TsvbManager(context)
    }

    private val context: Context
        get() = appContext.reactContext ?: throw IllegalStateException("React context not available")

    override fun definition() = ModuleDefinition {
        Name("VideoEffectsSdkReactNativeModule")

        AsyncFunction("initialize") { customerID: String, trackId: String, promise: Promise ->
            tsvbManager.initialize(customerID, trackId) { result ->
                promise.resolve(result)
            }
        }

        AsyncFunction("enableBlurBackground") { power: Double?, promise: Promise ->
            val blurPower = power ?: 0.5
            tsvbManager.enableBlurBackground(blurPower.toFloat()) { result ->
                promise.resolve(result)
            }
        }

        AsyncFunction("disableBlurBackground") { promise: Promise ->
            tsvbManager.disableBlurBackground { result ->
                promise.resolve(result)
            }
        }

        AsyncFunction("enableReplaceBackground") { assetSource: Map<String, Any>?, promise: Promise ->
            tsvbManager.enableReplaceBackground(assetSource) { result ->
                promise.resolve(result)
            }
        }

        AsyncFunction("disableReplaceBackground") { promise: Promise ->
            tsvbManager.disableReplaceBackground { result ->
                promise.resolve(result)
            }
        }

        Function("isBlurEnabled") {
            tsvbManager.isBlurEnabled
        }

        Function("hasVirtualBackground") {
            tsvbManager.isReplaceBackgroundEnabled
        }

        Function("isInitialized") {
            tsvbManager.isInitialized
        }

        Function("cleanup") {
            tsvbManager.cleanup()
        }

        Function("setDeviceOrientation") { _: String ->
            // No-op on Android — orientation is handled by CameraPipeline internally
        }
    }
}
