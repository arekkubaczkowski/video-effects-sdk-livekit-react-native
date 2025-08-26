import * as React from 'react';

import { VideoEffectsSdkReactNativeViewProps } from './VideoEffectsSdkReactNative.types';

export default function VideoEffectsSdkReactNativeView(props: VideoEffectsSdkReactNativeViewProps) {
  return (
    <div>
      <iframe
        style={{ flex: 1 }}
        src={props.url}
        onLoad={() => props.onLoad({ nativeEvent: { url: props.url } })}
      />
    </div>
  );
}
