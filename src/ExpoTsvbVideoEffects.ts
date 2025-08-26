import { NativeModules, Platform } from 'react-native';
import { MediaStreamTrack } from '@livekit/react-native-webrtc';
import { requireNativeModule } from 'expo-modules-core';
import { LocalVideoTrack } from 'livekit-client';

import {
  InitializationResult,
  TsvbVideoEffectsConfig,
  TsvbVideoEffectsModule,
} from './ExpoTsvbVideoEffects.types';

export const unwrapMediaStreamTrack = (
  track: LocalVideoTrack | undefined,
): MediaStreamTrack | undefined => {
  return track?.mediaStreamTrack as MediaStreamTrack | undefined;
};

const ExpoTsvbVideoEffectsModule = (
  Platform.OS === 'android' ? {} : requireNativeModule('ExpoTsvbVideoEffects')
) as TsvbVideoEffectsModule;

const { WebRTCModule } = NativeModules;

class TsvbVideoEffects {
  private config: TsvbVideoEffectsConfig | null = null;
  private initializationPromise: Promise<InitializationResult> | null = null;

  async initialize(
    config: TsvbVideoEffectsConfig,
  ): Promise<InitializationResult> {
    if (this.initializationPromise) {
      return this.initializationPromise;
    }

    if (this.isInitialized()) {
      return { success: true };
    }

    this.config = config;

    try {
      this.initializationPromise = ExpoTsvbVideoEffectsModule.initialize(
        config.customerID,
      );
      const result = await this.initializationPromise;

      if (!result.success) {
        throw new Error(result.error || 'Initialization failed');
      }

      // After successful initialization, set video effects on the track
      if (Platform.OS === 'ios' && WebRTCModule) {
        await WebRTCModule.mediaStreamTrackSetVideoEffects(
          this.config.trackId,
          ['tsvb'],
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

      if (Platform.OS === 'android') {
        await this.config?.mediaStreamTrack?._setEffectsSdkPipelineMode(
          'PipelineMode.blur',
        );
      } else {
        await ExpoTsvbVideoEffectsModule.enableBlurBackground(blurPower);
      }
    } catch (error) {
      throw new Error(`Failed to enable blur: ${error}`);
    }
  }

  async disableBlurBackground() {
    this.ensureInitialized();

    try {
      if (Platform.OS === 'android') {
        await this.config?.mediaStreamTrack?._setEffectsSdkPipelineMode(
          'PipelineMode.none',
        );
      } else {
        await ExpoTsvbVideoEffectsModule.disableBlurBackground();
      }
    } catch (error) {
      throw new Error(`Failed to disable blur: ${error}`);
    }
  }

  async enableReplaceBackground(imagePath?: string | null) {
    this.ensureInitialized();

    try {
      if (Platform.OS === 'android') {
        await this.config?.mediaStreamTrack?._setEffectsSdkPipelineMode(
          'PipelineMode.replace',
        );
      } else {
        ExpoTsvbVideoEffectsModule.enableReplaceBackground(imagePath);
      }
    } catch (error) {
      throw new Error(`Failed to enable background replacement: ${error}`);
    }
  }

  async disableReplaceBackground() {
    this.ensureInitialized();

    try {
      if (Platform.OS === 'android') {
        await this.config?.mediaStreamTrack?._setEffectsSdkPipelineMode(
          'PipelineMode.none',
        );
      } else {
        await ExpoTsvbVideoEffectsModule.disableReplaceBackground();
      }
    } catch (error) {
      throw new Error(`Failed to disable background replacement: ${error}`);
    }
  }

  isBlurEnabled(): boolean {
    return ExpoTsvbVideoEffectsModule.isBlurEnabled();
  }

  isInitialized(): boolean {
    return ExpoTsvbVideoEffectsModule.isInitialized();
  }

  cleanup(): void {
    ExpoTsvbVideoEffectsModule.cleanup();
    this.config = null;
    this.initializationPromise = null;
  }

  getConfig(): TsvbVideoEffectsConfig | null {
    return this.config;
  }

  private ensureInitialized(): void {
    if (!this.isInitialized()) {
      throw new Error('TSVB SDK is not initialized. Call initialize() first.');
    }
  }
}

export const tsvbVideoEffects = new TsvbVideoEffects();

export * from './ExpoTsvbVideoEffects.types';
export { TsvbVideoEffects };
export { ExpoTsvbVideoEffectsModule };
