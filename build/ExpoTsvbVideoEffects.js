import { NativeModules, Platform } from "react-native";
import { requireNativeModule } from "expo-modules-core";
const ExpoTsvbVideoEffectsModule = (Platform.OS === "android" ? {} : requireNativeModule("ExpoTsvbVideoEffects"));
const { WebRTCModule } = NativeModules;
class TsvbVideoEffects {
    config = null;
    initializationPromise = null;
    async initialize(config) {
        if (this.initializationPromise) {
            return this.initializationPromise;
        }
        if (this.isInitialized()) {
            return { success: true };
        }
        this.config = config;
        try {
            if (Platform.OS === "android") {
                return { success: true };
            }
            this.initializationPromise = ExpoTsvbVideoEffectsModule.initialize(config.customerID);
            const result = await this.initializationPromise;
            if (!result.success) {
                throw new Error(result.error || "Initialization failed");
            }
            // After successful initialization, set video effects on the track
            if (Platform.OS === "ios" && WebRTCModule) {
                await WebRTCModule.mediaStreamTrackSetVideoEffects(this.config.trackId, ["tsvb"]);
            }
            return result;
        }
        catch (error) {
            throw new Error(`Failed to initialize TSVB SDK: ${error}`);
        }
    }
    async enableBlurBackground(power) {
        this.ensureInitialized();
        try {
            const blurPower = power ?? this.config?.defaultBlurPower ?? 0.3;
            if (Platform.OS === "android") {
                this.config?.mediaStreamTrack?.setEffectsSdkPipelineMode("PipelineMode.blur");
            }
            else {
                await ExpoTsvbVideoEffectsModule.enableBlurBackground(blurPower);
            }
        }
        catch (error) {
            throw new Error(`Failed to enable blur: ${error}`);
        }
    }
    async disableBlurBackground() {
        this.ensureInitialized();
        try {
            if (Platform.OS === "android") {
                this.config?.mediaStreamTrack?.setEffectsSdkPipelineMode("PipelineMode.none");
            }
            else {
                await ExpoTsvbVideoEffectsModule.disableBlurBackground();
            }
        }
        catch (error) {
            throw new Error(`Failed to disable blur: ${error}`);
        }
    }
    async enableReplaceBackground(imagePath) {
        this.ensureInitialized();
        try {
            if (Platform.OS === "android") {
                this.config?.mediaStreamTrack?.setEffectsSdkPipelineMode("PipelineMode.replace");
            }
            else {
                ExpoTsvbVideoEffectsModule.enableReplaceBackground(imagePath);
            }
        }
        catch (error) {
            throw new Error(`Failed to enable background replacement: ${error}`);
        }
    }
    async disableReplaceBackground() {
        this.ensureInitialized();
        try {
            if (Platform.OS === "android") {
                this.config?.mediaStreamTrack?.setEffectsSdkPipelineMode("PipelineMode.none");
            }
            else {
                await ExpoTsvbVideoEffectsModule.disableReplaceBackground();
            }
        }
        catch (error) {
            throw new Error(`Failed to disable background replacement: ${error}`);
        }
    }
    isBlurEnabled() {
        if (Platform.OS === "android") {
            // TODO: Add implementation for Android
            return false;
        }
        return ExpoTsvbVideoEffectsModule.isBlurEnabled();
    }
    isVirtualBackgroundEnabled() {
        if (Platform.OS === "android") {
            // TODO: Add implementation for Android
            return false;
        }
        return ExpoTsvbVideoEffectsModule.hasVirtualBackground();
    }
    isInitialized() {
        if (Platform.OS === "android") {
            return true;
        }
        return ExpoTsvbVideoEffectsModule.isInitialized();
    }
    cleanup() {
        ExpoTsvbVideoEffectsModule.cleanup();
        this.config = null;
        this.initializationPromise = null;
    }
    getConfig() {
        return this.config;
    }
    ensureInitialized() {
        if (!this.isInitialized()) {
            throw new Error("TSVB SDK is not initialized. Call initialize() first.");
        }
    }
}
export const tsvbVideoEffects = new TsvbVideoEffects();
export * from "./ExpoTsvbVideoEffects.types";
export { TsvbVideoEffects };
export { ExpoTsvbVideoEffectsModule };
//# sourceMappingURL=ExpoTsvbVideoEffects.js.map