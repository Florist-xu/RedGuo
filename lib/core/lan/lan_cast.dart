part of 'lan_controller.dart';

int _castNow() => DateTime.now().millisecondsSinceEpoch;

extension LanCast on LanController {
  bool get casting => _castTimer != null;

  void setCastReceiver(LanCastReceiver? receiver) {
    castReceiver = receiver;
    didChangeAppLifecycleState(
      WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed,
    );
    _notify();
  }

  void startCast({
    required LanCastState Function() source,
    required VoidCallback onEnded,
    Future<void> Function(Map<String, dynamic> body)? onControl,
  }) {
    _endCast('');
    _castSource = source;
    _castEnded = onEnded;
    _castControl = onControl;
    _castId = lanID();
    _castFailures = 0;
    _castOffsetMs = 0;
    _castSamples.clear();
    castMessage = '正在同步';
    _castTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_castTick()),
    );
    unawaited(_castTick());
    _notify();
  }

  /// 画面端（跟随端）把本机的播放、暂停、拖动操作转发给声音端。
  Future<void> sendCastControl(Map<String, dynamic> body) async {
    await _request('cast/control', body);
  }

  Future<void> stopCast() async {
    if (!casting) return;
    final id = _castId;
    final remote = connection;
    _endCast('已停止分屏播放');
    if (remote != null && receiving) {
      await _request('cast/stop', {
        'id': id,
      }).catchError((Object _) => <String, dynamic>{});
    }
  }

  void _endCast(String message) {
    final wasCasting = _castTimer != null;
    _castTimer?.cancel();
    _castTimer = null;
    _castSource = null;
    _castControl = null;
    final ended = _castEnded;
    _castEnded = null;
    if (message.isNotEmpty) castMessage = message;
    if (wasCasting) {
      ended?.call();
      didChangeAppLifecycleState(
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed,
      );
      _notify();
    }
  }

  Future<void> _castTick() async {
    final source = _castSource;
    if (source == null || _castBusy) return;
    _castBusy = true;
    try {
      final state = source();
      final sentAt = _castNow();
      final reply = await _request('cast/sync', {
        'id': _castId,
        'episode': state.episode,
        'position': state.position,
        'playing': state.playing,
        'rate': state.rate,
        'sentAt': sentAt,
        'offsetMs': _castOffsetMs,
      });
      final receivedAt = _castNow();
      final recvAt = reply['recvAt'];
      final replyAt = reply['replyAt'];
      if (recvAt is num && replyAt is num) {
        final rtt =
            (receivedAt - sentAt) - (replyAt.toDouble() - recvAt.toDouble());
        final offset =
            ((recvAt - sentAt) + (replyAt - receivedAt)) / 2;
        _castSamples.add((rtt: rtt, offset: offset));
        if (_castSamples.length > 8) _castSamples.removeAt(0);
        final best = _castSamples.reduce((a, b) => a.rtt <= b.rtt ? a : b);
        _castOffsetMs = best.offset;
        castMessage = '同步中 · 网络延迟 ${max(0, rtt).round()} ms';
      }
      _castFailures = 0;
      _notify();
    } catch (failure) {
      if (_castSource == null) return;
      _castFailures++;
      castMessage = '同步异常（$_castFailures）';
      if (_castFailures >= 6) {
        _endCast('与对方失去连接，已停止分屏播放');
      } else {
        _notify();
      }
    } finally {
      _castBusy = false;
    }
  }

  Future<Map<String, dynamic>> _receiveCast(
    String path,
    Map<String, dynamic> body,
  ) async {
    final receivedAt = _castNow();
    final receiver = castReceiver;
    if (path == 'cast/stop') {
      await receiver?.stop();
      return {};
    }
    if (path == 'cast/control') {
      final control = _castControl;
      if (control == null || !casting) throw StateError('对方未在分屏播放');
      await control(body);
      return {};
    }
    if (path != 'cast/sync') throw StateError('不支持此分屏操作');
    if (receiver == null) throw StateError('对方未开启分屏播放');
    final result = receiver.apply(body, receivedAt);
    return {...result, 'recvAt': receivedAt, 'replyAt': _castNow()};
  }
}
