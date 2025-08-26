import { NativeModule, requireNativeModule } from 'expo';

import { VideoEffectsSdkReactNativeModuleEvents } from './VideoEffectsSdkReactNative.types';

declare class VideoEffectsSdkReactNativeModule extends NativeModule<VideoEffectsSdkReactNativeModuleEvents> {
  PI: number;
  hello(): string;
  setValueAsync(value: string): Promise<void>;
}

// This call loads the native module object from the JSI.
export default requireNativeModule<VideoEffectsSdkReactNativeModule>('VideoEffectsSdkReactNative');
