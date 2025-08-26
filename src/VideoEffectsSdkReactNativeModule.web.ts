import { registerWebModule, NativeModule } from 'expo';

import { VideoEffectsSdkReactNativeModuleEvents } from './VideoEffectsSdkReactNative.types';

class VideoEffectsSdkReactNativeModule extends NativeModule<VideoEffectsSdkReactNativeModuleEvents> {
  PI = Math.PI;
  async setValueAsync(value: string): Promise<void> {
    this.emit('onChange', { value });
  }
  hello() {
    return 'Hello world! 👋';
  }
}

export default registerWebModule(VideoEffectsSdkReactNativeModule, 'VideoEffectsSdkReactNativeModule');
