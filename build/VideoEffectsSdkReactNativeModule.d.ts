import type { BlurOptions, DeviceOrientation, EffectsConfig, EffectsEvent, EffectsState, InitializationResult, NativeModuleInterface, ReplaceOptions, SegmentationPreset } from "./VideoEffectsSdkReactNativeModule.types";
declare const NativeModule: NativeModuleInterface;
declare class TsvbVideoEffects {
    private _state;
    private _subscribers;
    initialize(config: EffectsConfig): Promise<InitializationResult>;
    enableBlur(options?: BlurOptions): Promise<void>;
    enableReplaceBackground(options: ReplaceOptions): Promise<void>;
    disableEffects(): Promise<void>;
    getState(): EffectsState;
    subscribe(callback: (event: EffectsEvent) => void): () => void;
    setDeviceOrientation(orientation: DeviceOrientation): void;
    /** Set segmentation quality preset. Only effective on iOS — Android handles this internally. */
    setSegmentationPreset(preset: SegmentationPreset): void;
    cleanup(): void;
    /** Query native for fallback state and update local state. Returns true if effects are unavailable. */
    checkEffectsAvailability(): boolean;
    private ensureInitialized;
    private ensureEffectsAvailable;
    private updateState;
    private emitError;
    private emit;
}
export declare const tsvbVideoEffects: TsvbVideoEffects;
export * from "./VideoEffectsSdkReactNativeModule.types";
export { TsvbVideoEffects };
export { NativeModule as VideoEffectsSdkReactNativeModule };
//# sourceMappingURL=VideoEffectsSdkReactNativeModule.d.ts.map