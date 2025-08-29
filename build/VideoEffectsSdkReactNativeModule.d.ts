import { InitializationResult, TsvbVideoEffectsConfig, VideoEffectsSdkReactNativeModule } from "./VideoEffectsSdkReactNativeModule.types";
declare const VideoEffectsSdkReactNativeModule: VideoEffectsSdkReactNativeModule;
declare class TsvbVideoEffects {
    private config;
    private initializationPromise;
    initialize(config: TsvbVideoEffectsConfig): Promise<InitializationResult>;
    enableBlurBackground(power?: number): Promise<void>;
    disableBlurBackground(): Promise<void>;
    enableReplaceBackground(imagePath?: string | null): Promise<void>;
    disableReplaceBackground(): Promise<void>;
    isBlurEnabled(): boolean;
    isVirtualBackgroundEnabled(): boolean;
    isInitialized(): boolean;
    cleanup(): void;
    getConfig(): TsvbVideoEffectsConfig | null;
    private ensureInitialized;
}
export declare const tsvbVideoEffects: TsvbVideoEffects;
export * from "./VideoEffectsSdkReactNativeModule.types";
export { TsvbVideoEffects };
export { VideoEffectsSdkReactNativeModule };
//# sourceMappingURL=VideoEffectsSdkReactNativeModule.d.ts.map