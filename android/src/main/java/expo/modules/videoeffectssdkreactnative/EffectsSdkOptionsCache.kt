package expo.modules.videoeffectssdkreactnative

import android.graphics.Bitmap
import com.effectssdk.tsvb.pipeline.ColorCorrectionMode
import com.effectssdk.tsvb.pipeline.PipelineMode
import com.effectssdk.tsvb.pipeline.SegmentationMode

/**
 * Preserves pipeline options across pipeline recreation (camera switch, resolution change).
 */
class EffectsSdkOptionsCache {
    var pipelineMode: PipelineMode = PipelineMode.NO_EFFECT
    var blurPower: Float = 0.5f
    var colorCorrectionMode: ColorCorrectionMode = ColorCorrectionMode.NO_FILTER_MODE
    var isBeautificationEnabled: Boolean = false
    var beautificationPower: Float = 0f
    var segmentationMode: SegmentationMode = SegmentationMode.QUALITY
    var segmentationGap: Int = 0
    var faceDetectionGap: Int = 0
    var backgroundBitmap: Bitmap? = null
    var colorGradingReference: Bitmap? = null

    fun reset() {
        pipelineMode = PipelineMode.NO_EFFECT
        blurPower = 0.5f
        colorCorrectionMode = ColorCorrectionMode.NO_FILTER_MODE
        isBeautificationEnabled = false
        beautificationPower = 0f
        segmentationMode = SegmentationMode.QUALITY
        segmentationGap = 0
        faceDetectionGap = 0
        backgroundBitmap = null
        colorGradingReference = null
    }
}
