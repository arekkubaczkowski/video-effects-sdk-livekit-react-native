import { NativeModules, Platform } from "react-native";
import { requireNativeModule } from "expo-modules-core";

import {
  InitializationResult,
  TsvbVideoEffectsConfig,
  VideoEffectsSdkReactNativeModule,
} from "./VideoEffectsSdkReactNativeModule.types";

const VideoEffectsSdkReactNativeModule = (
  Platform.OS === "android"
    ? {}
    : requireNativeModule("VideoEffectsSdkReactNativeModule")
) as VideoEffectsSdkReactNativeModule;

const { WebRTCModule } = NativeModules;

class TsvbVideoEffects {
  private config: TsvbVideoEffectsConfig | null = null;
  private initializationPromise: Promise<InitializationResult> | null = null;

  async initialize(
    config: TsvbVideoEffectsConfig
  ): Promise<InitializationResult> {
    this.config = config;

    try {
      if (Platform.OS === "android") {
        const status =
          await this.config?.mediaStreamTrack?.initializeEffectsSDK(
            this.config.customerID
          );
        return { success: true, status };
      }
      this.initializationPromise = VideoEffectsSdkReactNativeModule.initialize(
        config.customerID,
        config.mediaStreamTrack.id
      );
      const result = await this.initializationPromise;

      if (!result.success) {
        throw new Error(result.error || "Initialization failed");
      }

      if (Platform.OS === "ios" && WebRTCModule) {
        await WebRTCModule.mediaStreamTrackSetVideoEffects(
          config.mediaStreamTrack.id,
          ["tsvb"]
        );
      }

      return result;
    } catch (error) {
      throw new Error(`Failed to initialize TSVB SDK: ${error}`);
    }
  }

  async enableBlurBackground(power?: number) {
    this.ensureInitialized();

    try {
      const blurPower = power ?? this.config?.defaultBlurPower ?? 0.3;

      if (Platform.OS === "android") {
        this.config?.mediaStreamTrack?.setEffectsSdkPipelineMode(
          "PipelineMode.blur"
        );
      } else {
        await VideoEffectsSdkReactNativeModule.enableBlurBackground(blurPower);
      }
    } catch (error) {
      throw new Error(`Failed to enable blur: ${error}`);
    }
  }

  async disableBlurBackground() {
    this.ensureInitialized();

    try {
      if (Platform.OS === "android") {
        this.config?.mediaStreamTrack?.setEffectsSdkPipelineMode(
          "PipelineMode.no_effect"
        );
      } else {
        await VideoEffectsSdkReactNativeModule.disableBlurBackground();
      }
    } catch (error) {
      throw new Error(`Failed to disable blur: ${error}`);
    }
  }

  async enableReplaceBackground(imagePath?: string | null) {
    this.ensureInitialized();

    try {
      if (Platform.OS === "android") {
        this.config?.mediaStreamTrack?.setEffectsSdkPipelineMode(
          "PipelineMode.replace"
        );
      } else {
        await VideoEffectsSdkReactNativeModule.enableReplaceBackground(
          imagePath
        );
      }
    } catch (error) {
      throw new Error(`Failed to enable background replacement: ${error}`);
    }
  }

  async disableReplaceBackground() {
    this.ensureInitialized();

    try {
      if (Platform.OS === "android") {
        this.config?.mediaStreamTrack?.setEffectsSdkPipelineMode(
          "PipelineMode.no_effect"
        );
      } else {
        await VideoEffectsSdkReactNativeModule.disableReplaceBackground();
      }
    } catch (error) {
      throw new Error(`Failed to disable background replacement: ${error}`);
    }
  }

  isBlurEnabled(): boolean {
    if (Platform.OS === "android") {
      // TODO: Add implementation for Android
      return false;
    }
    return VideoEffectsSdkReactNativeModule.isBlurEnabled();
  }

  isVirtualBackgroundEnabled() {
    if (Platform.OS === "android") {
      // TODO: Add implementation for Android
      return false;
    }
    return VideoEffectsSdkReactNativeModule.hasVirtualBackground();
  }

  isInitialized(): boolean {
    if (Platform.OS === "android") {
      return true;
    }
    return VideoEffectsSdkReactNativeModule.isInitialized();
  }

  cleanup(): void {
    VideoEffectsSdkReactNativeModule.cleanup();
    this.config = null;
    this.initializationPromise = null;
  }

  getConfig(): TsvbVideoEffectsConfig | null {
    return this.config;
  }

  private ensureInitialized(): void {
    if (!this.isInitialized()) {
      throw new Error("TSVB SDK is not initialized. Call initialize() first.");
    }
  }
}

export const tsvbVideoEffects = new TsvbVideoEffects();

export * from "./VideoEffectsSdkReactNativeModule.types";
export { TsvbVideoEffects };
export { VideoEffectsSdkReactNativeModule as VideoEffectsSdkReactNativeModule };
