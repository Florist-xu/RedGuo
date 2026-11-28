import 'dart:async';

/// 音频输出设备变化与系统遥控事件（由原生层通过 duanju/device 通道推送）。
class AudioRouteEvents {
  AudioRouteEvents._();

  static final StreamController<void> _unplugged =
      StreamController<void>.broadcast();
  static final StreamController<Map<String, dynamic>> _remote =
      StreamController<Map<String, dynamic>>.broadcast();

  /// 耳机（有线、蓝牙、USB）被摘除或断开。
  static Stream<void> get headphonesUnplugged => _unplugged.stream;

  /// 系统遥控指令：pause / play / toggle / next / previous / seek。
  /// AirPods 摘下入耳检测、耳机按键、锁屏控制都会走这里。
  static Stream<Map<String, dynamic>> get remoteCommands => _remote.stream;

  static void notifyUnplugged() => _unplugged.add(null);

  static void notifyRemote(Object? arguments) {
    if (arguments is Map) {
      _remote.add(Map<String, dynamic>.from(arguments));
    }
  }
}
