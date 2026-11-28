import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:THLRedLook/utils/diary/diary_service.dart';

/// 后台保活：手机作为分屏「声音端」被暂停后，iOS 会很快把 App 挂起，
/// 局域网服务随之停摆（表现为：电脑端再点播放没声音、连接断开）。
/// 暂停期间循环播放一段静音，让系统认为 App 仍在播放音频，从而保持后台存活。
class KeepAliveAudio {
  Player? _player;
  bool _running = false;
  int _ticket = 0;

  bool get running => _running;

  Future<String> _silentFile() async {
    final dir = await getTemporaryDirectory();
    final file = File(p.join(dir.path, 'zgj_silence.wav'));
    if (await file.exists() && await file.length() > 44) return file.path;
    const sampleRate = 8000;
    const seconds = 2;
    const dataBytes = sampleRate * seconds * 2;
    final bytes = ByteData(44 + dataBytes);
    void ascii(int offset, String text) {
      for (var i = 0; i < text.length; i++) {
        bytes.setUint8(offset + i, text.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    bytes.setUint32(4, 36 + dataBytes, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    bytes.setUint32(16, 16, Endian.little);
    bytes.setUint16(20, 1, Endian.little);
    bytes.setUint16(22, 1, Endian.little);
    bytes.setUint32(24, sampleRate, Endian.little);
    bytes.setUint32(28, sampleRate * 2, Endian.little);
    bytes.setUint16(32, 2, Endian.little);
    bytes.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    bytes.setUint32(40, dataBytes, Endian.little);
    await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
    return file.path;
  }

  Future<void> start() async {
    if (_running) return;
    _running = true;
    final ticket = ++_ticket;
    try {
      final path = await _silentFile();
      if (!_running || ticket != _ticket) return;
      final player = _player ??= Player();
      await player.setPlaylistMode(PlaylistMode.loop);
      await player.setVolume(100);
      await player.open(Media(Uri.file(path).toString()), play: true);
      if (!_running || ticket != _ticket) {
        await player.pause();
        return;
      }
      DiaryService.add('[保活] 暂停期间循环静音，保持手机后台连接');
    } catch (error) {
      _running = false;
      DiaryService.add('[保活] 启动失败（忽略）: $error');
    }
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _ticket++;
    try {
      await _player?.pause();
    } catch (_) {}
    DiaryService.add('[保活] 已停止静音保活');
  }

  Future<void> dispose() async {
    _running = false;
    _ticket++;
    final player = _player;
    _player = null;
    try {
      await player?.dispose();
    } catch (_) {}
  }
}
