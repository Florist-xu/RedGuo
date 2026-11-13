import 'dart:async';

/// 音频输出设备变化事件（由原生层通过 duanju/device 通道推送）。
class AudioRouteEvents {
  AudioRouteEvents._();

  static final StreamController<void> _unplugged =
      StreamController<void>.broadcast();

  /// 耳机（有线、蓝牙、USB）被摘除或断开。
  static Stream<void> get headphonesUnplugged => _unplugged.stream;

  static void notifyUnplugged() => _unplugged.add(null);
}
