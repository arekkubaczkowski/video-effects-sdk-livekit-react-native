import type { ImageResolvedAssetSource } from "react-native";
export type EffectType = "blur" | "replace" | "none";
export interface EffectsConfig {
    customerID: string;
    trackId: string;
}
export interface BlurOptions {
    /** Blur intensity 0.0 - 1.0. Default: 0.5 */
    power?: number;
}
export interface ReplaceOptions {
    /** Image source: require() asset, {uri: 'https://...'}, or {uri: 'file://...'} */
    image: ImageResolvedAssetSource | {
        uri: string;
    };
}
export interface EffectsState {
    isInitialized: boolean;
    isReady: boolean;
    activeEffect: EffectType;
    error: string | null;
}
export type EffectsEvent = {
    type: "stateChange";
    state: EffectsState;
} | {
    type: "error";
    error: string;
    recoverable: boolean;
};
export interface InitializationResult {
    success: boolean;
    status?: string;
    error?: string;
}
export type DeviceOrientation = "portrait" | "landscape-left" | "landscape-right";
export interface NativeModuleInterface {
    initialize(customerID: string, trackId: string): Promise<InitializationResult>;
    enableBlurBackground(power?: number): Promise<void>;
    disableBlurBackground(): Promise<void>;
    enableReplaceBackground(imagePath?: ImageResolvedAssetSource | {
        uri: string;
    } | null): Promise<void>;
    disableReplaceBackground(): Promise<void>;
    isBlurEnabled(): boolean;
    hasVirtualBackground(): boolean;
    isInitialized(): boolean;
    setDeviceOrientation(orientation: DeviceOrientation): void;
    cleanup(): void;
}
//# sourceMappingURL=VideoEffectsSdkReactNativeModule.types.d.ts.map