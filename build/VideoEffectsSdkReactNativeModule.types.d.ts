import { MediaStreamTrack } from "@livekit/react-native-webrtc";
export interface InitializationResult {
    success: boolean;
    status?: string;
    error?: string;
}
export type PipelineMode = "NONE" | "NO_EFFECT" | "BLUR" | "REPLACE";
export interface TsvbVideoEffectsModule {
    initialize(customerID: string): Promise<InitializationResult>;
    enableBlurBackground(power?: number): Promise<void>;
    disableBlurBackground(): Promise<void>;
    enableReplaceBackground(imagePath?: string | null): Promise<void>;
    disableReplaceBackground(): Promise<void>;
    isBlurEnabled(): boolean;
    hasVirtualBackground(): boolean;
    isInitialized(): boolean;
    cleanup(): void;
}
export interface CaptureControllerResult {
    success: boolean;
    error?: string;
    capturer?: any;
    controller?: any;
    cameraName?: string;
}
export interface TsvbVideoEffectsConfig {
    customerID: string;
    defaultBlurPower?: number;
    trackId: string;
    mediaStreamTrack: MediaStreamTrack;
}
//# sourceMappingURL=VideoEffectsSdkReactNativeModule.types.d.ts.map