import type { BlurOptions, EffectsConfig, EffectsEvent, EffectsState, InitializationResult, NativeModuleInterface, ReplaceOptions, TsvbVideoEffectsConfig } from "./VideoEffectsSdkReactNativeModule.types";
declare const NativeModule: NativeModuleInterface;
declare class TsvbVideoEffects {
    private _state;
    private _subscribers;
    initialize(config: EffectsConfig | TsvbVideoEffectsConfig): Promise<InitializationResult>;
    enableBlur(options?: BlurOptions): Promise<void>;
    enableReplaceBackground(options: ReplaceOptions): Promise<void>;
    disableEffects(): Promise<void>;
    getState(): EffectsState;
    subscribe(callback: (event: EffectsEvent) => void): () => void;
    cleanup(): void;
    /** @deprecated Use new EffectsConfig-based initialize instead */
    getConfig(): TsvbVideoEffectsConfig | null;
    /** @deprecated Use enableBlur instead */
    enableBlurBackground(power?: number): Promise<void>;
    /** @deprecated Use disableEffects instead */
    disableBlurBackground(): Promise<void>;
    /** @deprecated Use disableEffects instead */
    disableReplaceBackground(): Promise<void>;
    isBlurEnabled(): boolean;
    isVirtualBackgroundEnabled(): boolean;
    isInitialized(): Promise<boolean>;
    private ensureInitialized;
    private updateState;
    private emitError;
    private emit;
}
export declare const tsvbVideoEffects: TsvbVideoEffects;
export * from "./VideoEffectsSdkReactNativeModule.types";
export { TsvbVideoEffects };
export { NativeModule as VideoEffectsSdkReactNativeModule };
//# sourceMappingURL=VideoEffectsSdkReactNativeModule.d.ts.map