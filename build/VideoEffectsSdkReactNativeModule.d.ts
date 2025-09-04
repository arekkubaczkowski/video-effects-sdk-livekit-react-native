import { ImageResolvedAssetSource } from "react-native";
import { InitializationResult, TsvbVideoEffectsConfig, VideoEffectsSdkReactNativeModule } from "./VideoEffectsSdkReactNativeModule.types";
declare const VideoEffectsSdkReactNativeModule: VideoEffectsSdkReactNativeModule;
declare class TsvbVideoEffects {
    private config;
    initialize(config: TsvbVideoEffectsConfig): Promise<InitializationResult>;
    enableBlurBackground(power?: number): Promise<void>;
    disableBlurBackground(): Promise<void>;
    enableReplaceBackground(imagePath?: ImageResolvedAssetSource | null): Promise<void>;
    disableReplaceBackground(): Promise<void>;
    isBlurEnabled(): boolean;
    isVirtualBackgroundEnabled(): boolean;
    isInitialized(): Promise<boolean>;
    cleanup(): void;
    getConfig(): TsvbVideoEffectsConfig | null;
    private ensureInitialized;
}
export declare const tsvbVideoEffects: TsvbVideoEffects;
export * from "./VideoEffectsSdkReactNativeModule.types";
export { TsvbVideoEffects };
export { VideoEffectsSdkReactNativeModule as VideoEffectsSdkReactNativeModule };
//# sourceMappingURL=VideoEffectsSdkReactNativeModule.d.ts.map