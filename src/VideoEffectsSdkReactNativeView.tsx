import { requireNativeView } from 'expo';
import * as React from 'react';

import { VideoEffectsSdkReactNativeViewProps } from './VideoEffectsSdkReactNative.types';

const NativeView: React.ComponentType<VideoEffectsSdkReactNativeViewProps> =
  requireNativeView('VideoEffectsSdkReactNative');

export default function VideoEffectsSdkReactNativeView(props: VideoEffectsSdkReactNativeViewProps) {
  return <NativeView {...props} />;
}
