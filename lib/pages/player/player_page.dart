import '../../views/account/hongguo_social_dialog.dart';
import 'dart:async';
import '../../core/account/hongguo_account_session.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'package:THLRedLook/core/player/audio_route.dart';
import 'package:THLRedLook/utils/theme/app_colors.dart';
import 'package:THLRedLook/utils/screen/app_layout.dart';
import 'package:THLRedLook/utils/screen/app_orientation.dart';
import 'package:THLRedLook/utils/theme/app_theme.dart';
import 'package:THLRedLook/core/bridge/core_bridge.dart';
import 'package:THLRedLook/utils/diary/diary_service.dart';
import 'package:THLRedLook/core/player/keep_alive_audio.dart';
import 'package:THLRedLook/core/player/luna_exo_player.dart';
import 'package:THLRedLook/core/player/encrypted_playback.dart';
import 'package:THLRedLook/core/player/pip_manager.dart';
import 'package:THLRedLook/core/danmaku/danmaku_controller.dart';
import 'package:THLRedLook/views/download/download_picker.dart';
import 'package:THLRedLook/pages/downloads/downloads_page.dart';
import 'package:THLRedLook/core/store/follow_state.dart';
import 'package:THLRedLook/core/series/hongguo_series.dart';
import 'package:THLRedLook/core/store/local_store.dart';
import 'package:THLRedLook/models/catalog/models.dart';
import 'package:THLRedLook/models/danmaku/danmaku_models.dart';
import 'package:THLRedLook/views/common/widgets.dart';
import 'package:THLRedLook/core/player/playback_loader.dart';
import 'package:THLRedLook/core/player/playback_preloader.dart';
import 'package:THLRedLook/core/player/playback_recovery.dart';
import 'package:THLRedLook/core/player/playback_diagnostics.dart';
import 'package:THLRedLook/core/player/playback_preferences.dart';
import 'package:THLRedLook/core/player/player_interactions.dart';
import 'package:THLRedLook/views/player/player_menu.dart';
import 'package:THLRedLook/views/television/television_controls.dart';
import 'package:THLRedLook/core/lan/lan_controller.dart';
import 'package:THLRedLook/pages/lan/lan_page.dart';
import 'package:THLRedLook/core/enhancement/video_enhancement.dart';
import 'package:THLRedLook/utils/media/video_output_size.dart';
import 'package:THLRedLook/views/player/player_mobile_panel_view.dart';
import 'package:THLRedLook/views/player/player_desktop_panel_view.dart';
import 'package:THLRedLook/views/player/player_viewport_view.dart';
import 'package:THLRedLook/views/player/player_quality_sheet_view.dart';
import 'package:THLRedLook/views/player/player_speed_sheet_view.dart';
import 'package:THLRedLook/views/player/player_danmaku_sheet_view.dart';
import 'package:THLRedLook/utils/player/player_dialog_helper.dart';
import 'package:THLRedLook/core/player/playback_lease.dart';
import 'package:THLRedLook/views/feed/feed_player_overlay.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.detail,
    required this.initialIndex,
    required this.repository,
    required this.store,
    this.initialPosition = 0,
    this.localOnly = false,
    this.allowOnlineFallback = true,
    this.mediaId,
    this.playerFactory,
    this.videoBuilder,
    this.handoff,
    this.initialSeriesEntries,
    this.onSeasonChanged,
    this.feed = false,
    this.playbackQueue,
    this.onOpenDetail,
    this.resumeCast = false,
  });
  final DramaDetail detail;
  final int initialIndex;
  final double initialPosition;
  final bool localOnly;
  final bool allowOnlineFallback;
  final String? mediaId;
  final AppRepository repository;
  final LocalStore store;
  final LanIncomingPlayback? handoff;
  final List<HongguoSeriesEntry>? initialSeriesEntries;
  final ValueChanged<DramaDetail>? onSeasonChanged;
  final bool feed;
  final PlaybackLeaseQueue? playbackQueue;
  final VoidCallback? onOpenDetail;
  /// 换季重建页面后，自动把新一季重新分屏推送给原来的电脑。
  final bool resumeCast;
  @visibleForTesting
  final Player Function()? playerFactory;
  @visibleForTesting
  final Widget Function(Widget controls)? videoBuilder;
  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver {
  late final Player _player;
  PlaybackLease? _playbackLease;
  late final VideoController? _video;
  late final VideoEnhancementController _enhancement;
  late final PlaybackLoader _loader;
  late final PlaybackPreloader _preloader;
  bool _preloadEnabled = true;
  late final DanmakuController _danmaku;
  int _seekSequence = 0;
  bool _danmakuEnabled = true;
  DanmakuStyle _danmakuStyle = const DanmakuStyle();
  late final PlayerInteractions _interactions;
  final _playerFocus = FocusNode(debugLabel: 'player-surface');
  final _videoPaneKey = GlobalKey();
  final _menuRevision = ValueNotifier<int>(0);
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final _recovery = PlaybackRecovery();
  var _encryptedPlayback = EncryptedPlayback();
  // 下一集备用解密流 + 已预热的原生控制器（仅 iOS）
  EncryptedPlayback? _standbyEncrypted;
  PlaybackPlan? _standbyPlan;
  String? _standbyRawUrl;
  bool _standbyBusy = false;
  int _standbyTag = 0;
  Object _lanIdentity = Object();
  bool _handoffOwned = true;
  bool _castFollower = false;
  String? _castAudioTarget;
  DateTime _castSeekedAt = DateTime(2000);
  double _castError = 0;
  DateTime _castHoldUntil = DateTime(2000);
  DateTime _castSwitchedAt = DateTime(2000);
  DateTime _castLastSyncAt = DateTime.now();
  bool _castStalled = false;
  Timer? _castWatch;
  bool _recasting = false;
  final _keepAlive = KeepAliveAudio();
  // iOS：本机播放时切后台/锁屏，改为只解码声音继续播放（像音乐 App），回到前台恢复画面
  bool _bgAudio = false;
  Timer? _keepAliveTimer;
  double? _lanFirstPosition;
  String? _savedProgressKey;
  final _health = PlaybackHealth();
  Timer? _saveTimer;
  Timer? _healthTimer;
  Timer? _errorTimer;
  Timer? _pictureInPictureExitTimer;
  Timer? _diagnosticsTimer;
  Future<void> _operations = Future<void>.value();
  late int _index;
  late final int _profileEpoch;
  int _openedIndex = -1;
  int _generation = 0;
  int _seasonSwitchTicket = 0;
  int _requestedQuality = 0;
  PlaybackDecoderMode _decoderMode = PlaybackDecoderMode.hardware;
  bool _loading = true;
  bool _forceOnline = false;
  bool _localFailure = false;
  bool _fullscreen = false;
  bool _automaticFullscreenSuppressed = false;
  bool _panelOpen = false;
  bool _autoAdvance = true;
  bool? _systemFullscreen;
  Orientation? _lastOrientation;
  bool _closed = false;
  bool _acceptErrors = false;
  bool _foreground = true;
  bool _playIntent = true;
  bool _lifecyclePaused = false;
  bool _resumeAfterInterruption = false;
  bool _showControlsOnPlaybackReady = true;
  bool _pendingError = false;
  bool _requireRecovery = false;
  bool _encryptedVideoOutputFailed = false;
  bool _pictureInPictureSupported = false;
  bool _pictureInPictureActive = false;
  bool _pictureInPictureRequested = false;
  bool _deskMini = false;
  // 小窗跟随端被新的投屏页面替换（断线重连）时，把小窗状态交给新页面，窗口不还原。
  static bool _carryMini = false;
  static Rect? _carryMiniRestore;
  static Timer? _carryMiniTimer;
  static _PlayerScreenState? _miniOwner;
  bool _miniHandedOver = false;

  static Future<void> _restoreWindowFrom(Rect? bounds) async {
    try {
      await windowManager.setAspectRatio(0);
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setTitleBarStyle(TitleBarStyle.normal);
      await windowManager.setMinimumSize(
        Platform.isMacOS ? const Size(960, 540) : const Size(0, 0),
      );
      if (bounds != null) await windowManager.setBounds(bounds);
    } catch (_) {}
  }
  double? _immersiveSeek;
  bool _immersiveClean = false;
  StreamSubscription<void>? _routeSub;
  StreamSubscription<Map<String, dynamic>>? _remoteSub;
  Timer? _nowPlayingTimer;
  bool _deskMiniHover = false;
  double? _deskMiniSeek;
  Rect? _deskMiniRestore;
  bool _pictureInPictureHandlerInstalled = false;
  bool _lastNativePipAutoEnter = false;
  int _lastNativePipWidth = 0;
  int _lastNativePipHeight = 0;
  int? _pipOriginalIndex;
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;
  String _loadingMessage = '正在准备播放';
  String? _error;
  String? _saveWarning;
  PlaybackPlan? _plan;
  double _speed = 1;
  double _aspectRatio = 9 / 16;
  double _resumePosition = 0;
  bool _rotating = false;
  bool _television = false;
  AppOrientationController? _orientationController;
  bool get _pictureInPictureVisible =>
      _pictureInPictureActive ||
      (defaultTargetPlatform == TargetPlatform.android &&
          _pictureInPictureRequested);
  /// 前台，或本机正在作为分屏的声音端（锁屏后仍需自动下一集、续播与错误恢复）。
  bool get _active =>
      _foreground ||
      _bgAudio ||
      _castFollower ||
      (LanController.current?.casting ?? false);
  bool get _deskMiniAvailable =>
      !_television &&
      !widget.feed &&
      (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
  Future<void> _toggleDeskMini() async {
    if (_closed || !_deskMiniAvailable) return;
    try {
      if (!_deskMini) {
        if (_fullscreen) await _rotate();
        _deskMiniRestore = await windowManager.getBounds();
        if (await windowManager.isMaximized()) await windowManager.unmaximize();
        await windowManager.setTitleBarStyle(
          TitleBarStyle.hidden,
          windowButtonVisibility: false,
        );
        await windowManager.setMinimumSize(const Size(90, 90));
        await windowManager.setAlwaysOnTop(true);
        await _fitDeskMini();
        if (!await _restoreMiniPosition()) {
          await windowManager.setAlignment(Alignment.bottomRight);
        }
        _miniOwner = this;
        if (mounted) setState(() => _deskMini = true);
      } else {
        await _restoreDeskMini();
      }
    } catch (error) {
      _notice('小窗切换失败：$error');
    }
  }

  /// 小窗尺寸跟随画面方向：横屏视频宽 480，竖屏视频高 480（窗口比例等于视频比例）。
  Future<void> _fitDeskMini() async {
    final raw = _aspectRatio.isFinite && _aspectRatio > 0 ? _aspectRatio : 16 / 9;
    final ratio = raw.clamp(0.4, 2.39).toDouble();
    final size = ratio >= 1 ? Size(480, 480 / ratio) : Size(480 * ratio, 480);
    await windowManager.setAspectRatio(ratio);
    await windowManager.setSize(size);
  }

  /// 记住小窗上次被拖到的位置，下次直接回到那里。
  Future<void> _saveMiniPosition() async {
    try {
      final pos = await windowManager.getPosition();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('desk_mini_x', pos.dx);
      await prefs.setDouble('desk_mini_y', pos.dy);
    } catch (_) {}
  }

  Future<bool> _restoreMiniPosition() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final x = prefs.getDouble('desk_mini_x');
      final y = prefs.getDouble('desk_mini_y');
      if (x == null || y == null || x < -50 || y < -50) return false;
      await windowManager.setPosition(Offset(x, y));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _restoreDeskMini() async {
    if (_miniOwner == this) _miniOwner = null;
    await _saveMiniPosition();
    final bounds = _deskMiniRestore;
    _deskMiniRestore = null;
    await windowManager.setAspectRatio(0);
    await windowManager.setAlwaysOnTop(false);
    await windowManager.setTitleBarStyle(TitleBarStyle.normal);
    await windowManager.setMinimumSize(
      Platform.isMacOS ? const Size(960, 540) : const Size(0, 0),
    );
    if (bounds != null) await windowManager.setBounds(bounds);
    if (mounted && _deskMini) setState(() => _deskMini = false);
  }

  bool get _canUsePictureInPicture =>
      !_television &&
      widget.store.playbackPreferences.pictureInPicture &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS) &&
      _pictureInPictureSupported;
  bool get _mobile =>
      !_television &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  VideoEnhancementController? get _enhancementForUi =>
      _enhancement.supported ? _enhancement : null;
  PlaybackPreferences get _preferences => PlaybackPreferences(
    speed: _speed,
    quality: _requestedQuality,
    autoAdvance: _autoAdvance,
    pictureInPicture: widget.store.playbackPreferences.pictureInPicture,
    decoderMode: _decoderMode,
    danmaku: _danmakuEnabled,
    danmakuStyle: _danmakuStyle,
    preload: _preloadEnabled,
    enhancement: _enhancement.preferences,
  );
  String get _qualityLabel {
    if (_plan?.offline == true) return '本地原画';
    final q = _plan?.quality ?? 0;
    if (q > 0) return '${q}P';
    return _requestedQuality > 0 ? '${_requestedQuality}P' : '自动';
  }

  String get _session => _plan?.session ?? '';
  double get _currentPosition =>
      _openedIndex == _index && _player.state.position.inMilliseconds > 0
      ? _player.state.position.inMilliseconds / 1000
      : _resumePosition;

  @override
  void initState() {
    super.initState();
    _playbackLease = widget.playbackQueue?.acquire();
    WidgetsBinding.instance.addObserver(this);
    _index = widget.initialIndex;
    _profileEpoch = widget.handoff?.profileEpoch ?? widget.store.profileEpoch;
    final preferences = widget.store.playbackPreferences;
    _speed = preferences.speed;
    _requestedQuality = preferences.quality;
    _decoderMode = preferences.decoderMode;
    _autoAdvance = preferences.autoAdvance;
    _danmakuEnabled = preferences.danmaku;
    _danmakuStyle = preferences.danmakuStyle;
    _preloadEnabled = preferences.preload;
    _loader = PlaybackLoader(widget.repository);
    _preloader = PlaybackPreloader(widget.repository);
    _preloader.addListener(_warmStandby);
    _danmaku = DanmakuController(widget.repository)
      ..setEnabled(_danmakuEnabled);
    widget.store.addListener(_accessChanged);
    _player =
        widget.playerFactory?.call() ??
        ((Platform.isAndroid || Platform.isIOS)
            ? LunaExoPlayer()
            : Player(
                configuration: PlayerConfiguration(
                  bufferSize: 32 * 1024 * 1024,
                  logLevel: Platform.isWindows
                      ? MPVLogLevel.v
                      : MPVLogLevel.error,
                ),
              ));
    if (_player is LunaExoPlayer) {
      _player.setDecoderMode(preferences.decoderMode);
    }
    _routeSub = AudioRouteEvents.headphonesUnplugged.listen(
      (_) => _onHeadphonesUnplugged(),
    );
    _player.stream.playing.listen((playing) {
      if (_castFollower || (LanController.current?.casting ?? false)) {
        DiaryService.add(
          '[分屏] 播放器状态 playing=$playing 生命周期=${_lifecycleState.name} '
          '位置=${_currentPosition.toStringAsFixed(1)}s',
        );
      }
    });
    if (!widget.feed && defaultTargetPlatform == TargetPlatform.iOS) {
      _remoteSub = AudioRouteEvents.remoteCommands.listen(_onRemoteCommand);
      _nowPlayingTimer = Timer.periodic(
        const Duration(seconds: 3),
        (_) => _publishNowPlaying(),
      );
    }
    _castFollower = widget.handoff?.intent.cast == true;
    if (widget.resumeCast) unawaited(_resumeCastPush());
    final miniOwner = _miniOwner;
    if (_castFollower &&
        _deskMiniAvailable &&
        miniOwner != null &&
        miniOwner != this &&
        miniOwner._deskMini) {
      // 新页面在旧页面销毁前就已创建：直接从旧页面接手小窗
      _deskMini = true;
      _deskMiniRestore = miniOwner._deskMiniRestore;
      miniOwner._miniHandedOver = true;
      _miniOwner = this;
      DiaryService.add('[分屏] 重新投屏，沿用电脑小窗');
      unawaited(_fitDeskMini().catchError((Object _) {}));
    } else if (_carryMini) {
      final restore = _carryMiniRestore;
      _carryMini = false;
      _carryMiniRestore = null;
      _carryMiniTimer?.cancel();
      if (_castFollower && _deskMiniAvailable) {
        _deskMini = true;
        _deskMiniRestore = restore;
        _miniOwner = this;
        DiaryService.add('[分屏] 重新投屏，沿用电脑小窗');
        unawaited(_fitDeskMini().catchError((Object _) {}));
      } else if (restore != null) {
        unawaited(
          windowManager.setAspectRatio(0).then((_) async {
            await windowManager.setAlwaysOnTop(false);
            await windowManager.setTitleBarStyle(TitleBarStyle.normal);
            await windowManager.setBounds(restore);
          }).catchError((Object _) {}),
        );
      }
    }
    if (_castFollower) {
      _castWatch = Timer.periodic(const Duration(seconds: 3), (_) {
        if (_closed || !_castFollower) return;
        final stalled =
            DateTime.now().difference(_castLastSyncAt) >
            const Duration(seconds: 9);
        if (stalled && !_castStalled) {
          _castStalled = true;
          _notice('与手机失去连接，等待手机重新投屏…');
        }
      });
      if (widget.handoff?.intent.castAudio == true) {
        _castAudioTarget =
            LanController.current?.connection?.peer.name ?? '电脑';
        unawaited(_setVideoDecode(false));
      } else {
        unawaited(_player.setVolume(0));
      }
      LanController.current?.setCastReceiver(
        LanCastReceiver(apply: _applyCastSync, stop: _stopCastFollower),
      );
    }
    _video = widget.videoBuilder == null && _player is! LunaExoPlayer
        ? VideoController(
            _player,
            configuration: VideoControllerConfiguration(
              enableHardwareAcceleration:
                  !Platform.isIOS &&
                  preferences.decoderMode == PlaybackDecoderMode.hardware,
              hwdec: preferences.decoderMode == PlaybackDecoderMode.hardware
                  ? (Platform.isWindows ? 'auto-copy-safe' : 'auto-safe')
                  : 'no',
            ),
          )
        : null;
    _enhancement = VideoEnhancementController(
      player: _player,
      video: _video,
      preferences: preferences.enhancement,
      category: widget.detail.drama.category,
      tags: widget.detail.drama.tags,
    );
    _interactions = PlayerInteractions(
      player: _player,
      available: () =>
          !_closed &&
          widget.store.profileEpoch == _profileEpoch &&
          !_loading &&
          _error == null &&
          _foreground &&
          !_panelOpen,
      baseSpeed: () => _speed,
      onTogglePlayback: _togglePlayback,
      onSeek: _seekTo,
      onFullscreen: _rotate,
      onEpisode: (direction) {
        final next = _index + direction;
        if (next < 0) return '已经是第一集';
        if (next >= widget.detail.episodes.length) return '已经是最后一集';
        unawaited(_play(next));
        return '第 ${widget.detail.episodes[next].number} 集';
      },
    );
    _playerFocus.addListener(() {
      if (!_playerFocus.hasPrimaryFocus && !_closed) _interactions.cancel();
    });
    _configurePictureInPicture();
    _subscriptions.add(
      _player.stream.error.listen((error) {
        if (_enhancement.handlePlaybackError(error)) return;
        if (!_closed && _acceptErrors && mounted && error.trim().isNotEmpty) {
          if (!_pendingError) {
            DiaryService.add(
              '[Play] 原生播放错误: 剧=${widget.detail.drama.cleanSourceId}, 集=${widget.detail.episodes[_index].number}, ${playbackFailureSummary(AppFailure(error, code: 'native_stream'))}',
            );
          }
          final videoOutputFailed = PlaybackRecovery.videoOutputFailed(error);
          if (Platform.isAndroid && videoOutputFailed) {
            _encryptedVideoOutputFailed = true;
          }
          _queueRecovery(
            force:
                videoOutputFailed || PlaybackRecovery.audioOutputFailed(error),
          );
        }
      }),
    );
    _subscriptions.add(
      _player.stream.completed.listen((completed) {
        if (completed &&
            !_loading &&
            !_closed &&
            _acceptErrors &&
            _error == null) {
          final duration = _player.state.duration;
          final currentPosition = _player.state.position > Duration.zero
              ? _player.state.position
              : Duration(milliseconds: (_resumePosition * 1000).round());
          if (duration <= Duration.zero ||
              currentPosition < duration - const Duration(seconds: 2)) {
            _queueRecovery();
          } else if (_autoAdvance &&
              !_castFollower &&
              _active &&
              !_panelOpen &&
              _index + 1 < widget.detail.episodes.length) {
            _play(_index + 1, showControlsOnReady: false);
          } else if (_autoAdvance &&
              !_castFollower &&
              _active &&
              !_panelOpen &&
              !widget.feed &&
              widget.mediaId == null &&
              _nextSeasonDrama() != null) {
            DiaryService.add('[换集] 本季播完，自动进入下一季');
            unawaited(_switchSeason(_nextSeasonDrama()!));
          } else {
            setState(() => _playIntent = false);
            _interactions.cancel();
            unawaited(_player.pause());
            unawaited(_saveProgress(flush: true));
          }
        }
      }),
    );
    _subscriptions.add(
      _player.stream.position.listen((position) {
        if (!_closed && _openedIndex == _index && position > Duration.zero) {
          _resumePosition = position.inMilliseconds / 1000;
        }
        _syncDanmaku();
        _syncPreload();
        _acknowledgeHandoff();
      }),
    );
    for (final stream in [
      _player.stream.duration,
      _player.stream.buffer,
      _player.stream.playing,
      _player.stream.buffering,
      _player.stream.rate,
      _player.stream.completed,
    ]) {
      _subscriptions.add(
        stream.listen((_) {
          _syncKeepAlive();
          _publishNowPlaying();
          _syncDanmaku();
          _syncPreload();
          _acknowledgeHandoff();
        }),
      );
    }
    _subscriptions.add(
      _player.stream.videoParams.listen((parameters) {
        final size = videoDisplaySize(parameters);
        if (size != null && mounted && !_closed) {
          final before = _aspectRatio;
          setState(() {
            _aspectRatio = size.width / size.height;
          });
          if (_deskMini && (before >= 1) != (_aspectRatio >= 1)) {
            unawaited(_fitDeskMini().catchError((_) {}));
          }
          _scheduleSystemUi();
          _syncNativePictureInPictureConfig();
        }
      }),
    );
    _saveTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _saveProgress(),
    );
    _healthTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_closed &&
          _acceptErrors &&
          !_loading &&
          _error == null &&
          _health.stalled(
            position: _player.state.position,
            playing: _player.state.playing && _playIntent,
            buffering: _player.state.buffering && _playIntent,
            foreground: _foreground,
            now: DateTime.now(),
          )) {
        unawaited(_recover());
      }
    });
    final handoff = widget.handoff;
    if (handoff != null) {
      handoff.consumed = true;
      handoff.stop = () async {
        if (_handoffOwned && !_closed) await _stopForLan();
      };
    }
    if (_profileEpoch != widget.store.profileEpoch ||
        handoff?.cancelled == true) {
      handoff?.fail('接收用户已变更，推送已取消');
      if (handoff != null) {
        unawaited(widget.repository.release(handoff.plan.session));
      }
      _loading = false;
      _error = '播放接收已取消';
    } else {
      _play(
        _index,
        position: widget.initialPosition,
        handoffPlan: handoff?.plan,
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_closed) {
        widget.repository.catalogUpdates.publish(
          widget.repository.catalogUpdates.current(widget.detail.drama),
          retryCover: true,
        );
      }
    });
    _seriesEntries = widget.initialSeriesEntries;
    _discoverSeasons();
  }

  List<HongguoSeriesEntry>? _seriesEntries;

  List<HongguoSeriesEntry> get _currentSeriesEntries {
    if (_seriesEntries != null && _seriesEntries!.isNotEmpty) {
      return _seriesEntries!;
    }
    return hongguoSeriesEntries(
      widget.detail.drama,
      widget.store.seriesDramasFor(widget.detail.drama),
    );
  }

  Future<void> _discoverSeasons() async {
    try {
      final entries = await discoverSeriesSeasons(
        anchor: widget.detail.drama,
        repository: widget.repository,
        store: widget.store,
        existingEntries: _seriesEntries,
      );
      if (mounted && !_closed && entries.isNotEmpty) {
        setState(() {
          _seriesEntries = entries;
        });
      }
    } catch (_) {}
  }

  /// 当前季之后第一个可播放的季（用于整季播完自动接下一季）。
  Drama? _nextSeasonDrama() {
    final entries = _currentSeriesEntries;
    final index = entries.indexWhere(
      (entry) => entry.drama.id == widget.detail.drama.id,
    );
    if (index < 0) return null;
    final season = entries[index].season;
    HongguoSeriesEntry? best;
    for (final entry in entries) {
      if (entry.season > season &&
          entry.playable &&
          (best == null || entry.season < best.season)) {
        best = entry;
      }
    }
    return best?.drama;
  }

  /// 换季后新页面就绪，自动把画面重新推给电脑（小窗由电脑端沿用）。
  Future<void> _resumeCastPush() async {
    final link = LanController.current;
    if (link == null) return;
    for (var i = 0; i < 80; i++) {
      if (_closed || !mounted) return;
      if (!_loading && _error == null && _openedIndex == _index) break;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    if (_closed || !mounted || _loading || _error != null) return;
    final generation = _generation;
    final index = _index;
    bool current() =>
        mounted &&
        !_closed &&
        generation == _generation &&
        index == _index &&
        widget.store.profileEpoch == _profileEpoch;
    final videoHere = link.kind == 'computer';
    try {
      await link.pushPlayback(
        snapshot: () => LanPlaybackIntent(
          drama: widget.detail.drama,
          episodeID: widget.detail.episodes[index].id,
          episode: widget.detail.episodes[index].number,
          position: _currentPosition,
        ).asCast(audio: videoHere),
        stillCurrent: current,
        onAccepted: () async {
          if (!current()) throw StateError('本机播放内容已变更');
          _beginCastAudio(link);
        },
        confirmReplace: (_) async => true,
      );
      DiaryService.add('[分屏] 换季后已重新投屏');
    } catch (error) {
      DiaryService.add('[分屏] 换季后重新投屏失败: $error');
    }
  }

  /// 意外断线后，每隔几秒尝试重新投屏，最多约 2 分钟；成功、用户自己重投或页面关闭即停。
  Future<void> _autoRecast(LanController link) async {
    if (_recasting) return;
    _recasting = true;
    try {
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(seconds: 4));
        if (_closed || !mounted || link.casting) return;
        if (_loading || _error != null || link.pushing) continue;
        final generation = _generation;
        final index = _index;
        bool current() =>
            mounted &&
            !_closed &&
            generation == _generation &&
            index == _index &&
            widget.store.profileEpoch == _profileEpoch;
        try {
          await link.pushPlayback(
            snapshot: () => LanPlaybackIntent(
              drama: widget.detail.drama,
              episodeID: widget.detail.episodes[index].id,
              episode: widget.detail.episodes[index].number,
              position: _currentPosition,
            ).asCast(audio: link.kind == 'computer'),
            stillCurrent: current,
            onAccepted: () async {
              if (!current()) throw StateError('本机播放内容已变更');
              _beginCastAudio(link);
            },
            confirmReplace: (_) async => true,
          );
          DiaryService.add('[分屏] 断线后自动重新投屏成功');
          _notice('已自动重新投屏');
          return;
        } catch (error) {
          if (i == 0) DiaryService.add('[分屏] 自动重投未成功，继续重试: $error');
        }
      }
      DiaryService.add('[分屏] 自动重投超时，请手动重新投屏');
      _notice('自动重新投屏失败，请手动重新投屏');
    } finally {
      _recasting = false;
    }
  }

  /// 分屏跟随端点上一集/下一集：转发给声音端，由它换集后同步回来。
  void _stepEpisode(int target) {
    if (target < 0 || target >= widget.detail.episodes.length) return;
    if (_castFollower) {
      _sendCastControl({
        'action': 'episode',
        'number': widget.detail.episodes[target].number,
      });
    }
    unawaited(_play(target, showControlsOnReady: false));
  }

  Future<void> _switchSeason(Drama seasonDrama) async {
    if (_closed || !mounted) return;
    if (seasonDrama.id == widget.detail.drama.id) return;
    if (_currentSeriesEntries.any(
      (entry) => entry.drama.id == seasonDrama.id && !entry.playable,
    )) {
      return;
    }

    final ticket = ++_seasonSwitchTicket;

    final anchor = widget.detail.drama;
    if (widget.store
            .following(anchor.id)
            ?.seriesSeasons[seasonDrama.id]
            ?.read ==
        false) {
      await saveUserChange(
        context,
        () => widget.store.markSeriesSeasonRead(anchor.id, seasonDrama.id),
      );
      if (!mounted) return;
    }

    _notice(
      '正在切换至 ${seasonDrama.title}...',
      duration: const Duration(milliseconds: 700),
    );

    try {
      seasonDrama = await resolveHongguoSeriesIdentity(
        drama: seasonDrama,
        repository: widget.repository,
        store: widget.store,
      );
      if (!mounted || _closed || ticket != _seasonSwitchTicket) return;
      final safeDrama =
          seasonDrama.sourceId.isEmpty || seasonDrama.sourceId.contains(':')
          ? Drama(
              id: seasonDrama.id,
              source: seasonDrama.source,
              sourceId: seasonDrama.cleanSourceId,
              title: seasonDrama.title,
              description: seasonDrama.description,
              cover: seasonDrama.cover,
              episodes: seasonDrama.episodes,
              category: seasonDrama.category,
              heat: seasonDrama.heat,
              views: seasonDrama.views,
              onlineDate: seasonDrama.onlineDate,
              tags: seasonDrama.tags,
              releaseStatus: seasonDrama.releaseStatus,
            )
          : seasonDrama;
      var nextDetail = await widget.repository.detail(safeDrama);
      if (!mounted || _closed || ticket != _seasonSwitchTicket) return;
      if (nextDetail.episodes.isEmpty && safeDrama.episodes > 0) {
        nextDetail = DramaDetail(
          safeDrama,
          List.generate(
            safeDrama.episodes,
            (index) => Episode({
              'id': '${safeDrama.cleanSourceId}_${index + 1}',
              'title': '第 ${index + 1} 集',
              'currentEpisode': index + 1,
            }, index + 1),
          ),
        );
      }
      if (nextDetail.episodes.isEmpty) {
        if (ticket == _seasonSwitchTicket) {
          _notice('该季暂无可用集数');
        }
        return;
      }

      final watched = widget.store.watched(seasonDrama.id);
      final initialIndex = resumeEpisodeIndex(nextDetail.episodes, watched);
      final initialPosition = (watched != null && watched.position > 0)
          ? watched.position.toDouble()
          : 0.0;

      if (ticket != _seasonSwitchTicket || !mounted || _closed) return;

      ScaffoldMessenger.maybeOf(context)?.clearSnackBars();
      ScaffoldMessenger.maybeOf(context)?.removeCurrentSnackBar();

      widget.onSeasonChanged?.call(nextDetail);
      if (widget.feed) return;
      final recast = LanController.current?.casting ?? false;
      if (recast) DiaryService.add('[分屏] 换季，稍后自动重新投屏到电脑');
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => PlayerScreen(
            detail: nextDetail,
            initialIndex: initialIndex,
            initialPosition: initialPosition,
            repository: widget.repository,
            store: widget.store,
            localOnly: widget.localOnly,
            allowOnlineFallback: widget.allowOnlineFallback,
            playerFactory: widget.playerFactory,
            videoBuilder: widget.videoBuilder,
            initialSeriesEntries: hongguoSeriesEntries(nextDetail.drama, [
              ..._currentSeriesEntries.map((entry) => entry.drama),
              ...widget.store.seriesDramasFor(nextDetail.drama),
            ], lockedEntries: _currentSeriesEntries),
            onSeasonChanged: widget.onSeasonChanged,
            resumeCast: recast,
          ),
        ),
      );
    } catch (e) {
      if (mounted && ticket == _seasonSwitchTicket) {
        _notice('切换失败: $e');
      }
    }
  }

  void _accessChanged() {
    if (!_closed &&
        (widget.store.profileEpoch != _profileEpoch || widget.store.locked)) {
      _preloader.clear();
      _enhancement.suspend();
      _handoffOwned = false;
      _playIntent = false;
      widget.handoff?.fail('接收端用户已变更');
      unawaited(_player.pause());
    }
    if (!_closed &&
        (widget.store.profileEpoch != _profileEpoch ||
            widget.store.locked ||
            !widget.store.allowsSource('hongguo'))) {
      _danmaku.setPlan(null);
    }
    if (!_closed && mounted) {
      setState(() {});
    }
    _syncNativePictureInPictureConfig();
  }

  void _syncPictureInPictureSession() {
    _pictureInPictureHandlerInstalled = true;
    _pipOriginalIndex ??= _index;
    PipManager.instance.registerPictureInPictureSession(
      detail: widget.detail,
      episodeIndex: _index,
      positionMs: _player.state.position.inMilliseconds,
      quality: _requestedQuality,
      speed: _speed,
      localOnly: widget.localOnly,
      onEpisodeAdvanced: (nextIndex) {
        if (mounted && !_closed) {
          setState(() {
            _index = nextIndex;
            _openedIndex = nextIndex;
          });
          _menuRevision.value++;
          unawaited(_saveProgress(flush: true));
        }
      },
      onRestoreCurrentPlayer: (positionMs) {
        if (mounted && !_closed) {
          final advanced =
              _pipOriginalIndex != null && _pipOriginalIndex != _index;
          _pipOriginalIndex = null;
          _setPictureInPictureStatus(active: false);
          if (advanced) {
            unawaited(
              _play(
                _index,
                position: positionMs > 0 ? positionMs / 1000.0 : 0.0,
              ),
            );
          } else {
            if (positionMs > 0) {
              unawaited(_seekTo(Duration(milliseconds: positionMs)));
            }
            if (_playIntent && !_loading && _error == null) {
              unawaited(_player.play());
            }
          }
        }
      },
      onPictureInPictureStatusChanged: (active, error, position) {
        if (mounted && !_closed) {
          if (active) {
            _dismissOverlaysForPictureInPicture();
          }
          if (error != null && error.isNotEmpty) {
            _notice('画中画提示: ${_localizePipError(error)}');
          }
          if (active) {
            _pipOriginalIndex = _index;
            if (Platform.isIOS && _player.state.playing) {
              unawaited(_player.pause());
            }
          } else {
            final advanced =
                _pipOriginalIndex != null && _pipOriginalIndex != _index;
            _pipOriginalIndex = null;
            if (advanced) {
              unawaited(
                _play(
                  _index,
                  position: position != null && position > 0
                      ? position / 1000.0
                      : 0.0,
                ),
              );
            } else {
              if (position != null && position > 0) {
                unawaited(_seekTo(Duration(milliseconds: position)));
              }
              if (_playIntent && !_loading && _error == null) {
                unawaited(_player.play());
              }
            }
          }
          _setPictureInPictureStatus(
            active: active,
            requested: false,
            delayHiddenPause: !active,
          );
          _syncNativePictureInPictureConfig();
        }
      },
    );
  }

  void _configurePictureInPicture() {
    if (widget.feed) return;
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }
    _syncPictureInPictureSession();
    unawaited(_refreshPictureInPictureStatus());
  }

  Future<void> _refreshPictureInPictureStatus() async {
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }
    try {
      final status = await AppDevice.channel.invokeMapMethod<String, dynamic>(
        'pictureInPictureStatus',
      );
      if (!mounted || _closed) return;
      _setPictureInPictureStatus(
        supported: status?['supported'] == true,
        active: status?['active'] == true,
      );
    } on PlatformException {
      if (mounted && !_closed) {
        _setPictureInPictureStatus(supported: false, active: false);
      }
    } on MissingPluginException {
      if (mounted && !_closed) {
        _setPictureInPictureStatus(supported: false, active: false);
      }
    }
  }

  void _setPictureInPictureStatus({
    bool? supported,
    bool? active,
    bool? requested,
    bool delayHiddenPause = false,
  }) {
    final nextSupported = supported ?? _pictureInPictureSupported;
    final nextActive = active ?? _pictureInPictureActive;
    final nextRequested =
        requested ?? (nextActive ? false : _pictureInPictureRequested);
    void assign() {
      _pictureInPictureSupported = nextSupported;
      _pictureInPictureActive = nextActive;
      _pictureInPictureRequested = nextRequested;
    }

    if (mounted && !_closed) {
      setState(assign);
    } else {
      assign();
    }
    _syncNativePictureInPictureConfig();
    if (_pictureInPictureVisible ||
        _lifecycleState == AppLifecycleState.resumed ||
        _lifecycleState == AppLifecycleState.inactive) {
      _pictureInPictureExitTimer?.cancel();
      _applyLifecycleVisibility(pauseWhenHidden: false);
      return;
    }
    _pictureInPictureExitTimer?.cancel();
    _applyLifecycleVisibility(pauseWhenHidden: !delayHiddenPause);
    if (delayHiddenPause) {
      _pictureInPictureExitTimer = Timer(const Duration(milliseconds: 700), () {
        if (!_closed &&
            !_pictureInPictureVisible &&
            _lifecycleState != AppLifecycleState.resumed &&
            _lifecycleState != AppLifecycleState.inactive) {
          _applyLifecycleVisibility();
        }
      });
    }
  }

  void _dismissOverlaysForPictureInPicture() {
    _interactions.cancel();
    if (!mounted || _closed) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.clearSnackBars();
    messenger?.removeCurrentSnackBar();
    final route = ModalRoute.of(context);
    if (route != null && route.isActive && !route.isCurrent) {
      Navigator.of(context).popUntil((item) => item == route);
    }
    if (_panelOpen) {
      setState(() => _panelOpen = false);
    }
  }

  (int, int) _pictureInPictureAspectDimensions() {
    final rawRatio = _aspectRatio.isFinite && _aspectRatio > 0
        ? _aspectRatio
        : 16 / 9;
    final ratio = rawRatio.clamp(1 / 2.39, 2.39).toDouble();
    final width = ratio >= 1 ? (1000 * ratio).round() : 1000;
    final height = ratio >= 1 ? 1000 : (1000 / ratio).round();
    return (width, height);
  }

  bool get _shouldAutoEnterPictureInPicture =>
      defaultTargetPlatform == TargetPlatform.android &&
      !widget.feed &&
      !_closed &&
      _canUsePictureInPicture &&
      !_loading &&
      _error == null &&
      _openedIndex == _index &&
      _playIntent;

  void _syncNativePictureInPictureConfig({bool force = false}) {
    if (defaultTargetPlatform != TargetPlatform.android || widget.feed) {
      return;
    }
    final autoEnter = _shouldAutoEnterPictureInPicture;
    final dimensions = _pictureInPictureAspectDimensions();
    final width = dimensions.$1;
    final height = dimensions.$2;
    if (!force &&
        autoEnter == _lastNativePipAutoEnter &&
        width == _lastNativePipWidth &&
        height == _lastNativePipHeight) {
      return;
    }
    _lastNativePipAutoEnter = autoEnter;
    _lastNativePipWidth = width;
    _lastNativePipHeight = height;
    final sourceRect = autoEnter ? _pictureInPictureSourceRect() : null;
    final arguments = <String, dynamic>{
      'autoEnter': autoEnter,
      'width': width,
      'height': height,
      if (sourceRect != null) ...sourceRect,
    };
    unawaited(
      AppDevice.channel
          .invokeMethod<dynamic>('updatePictureInPictureConfig', arguments)
          .catchError((Object _) => null),
    );
  }

  void _applyLifecycleVisibility({bool pauseWhenHidden = true}) {
    if (_closed) return;
    final visible =
        _lifecycleState == AppLifecycleState.resumed ||
        _lifecycleState == AppLifecycleState.inactive ||
        _pictureInPictureVisible;
    _foreground = visible;
    _enhancement.setForeground(_foreground);
    _syncDanmaku();
    _syncPreload();
    _health.reset();
    if (!visible) _interactions.cancel();
    final casting = _castFollower || (LanController.current?.casting ?? false);
    final hiddenNow =
        _lifecycleState == AppLifecycleState.paused ||
        _lifecycleState == AppLifecycleState.hidden;
    // 非小窗、非分屏时，锁屏/切后台一律暂停（不再改为仅播放声音）
    if (visible && _bgAudio) {
      _bgAudio = false;
      DiaryService.add('[后台] 回到前台，恢复画面');
      unawaited(_setVideoDecode(true));
    }
    // 分屏播放时，出声的一端锁屏/切后台也要继续播放并保持对齐
    final keepAudio = casting || _bgAudio;
    if (pauseWhenHidden &&
        !visible &&
        !keepAudio &&
        (_lifecycleState == AppLifecycleState.paused ||
            _lifecycleState == AppLifecycleState.hidden)) {
      if (!_lifecyclePaused) {
        _resumeAfterInterruption = _playIntent;
        _lifecyclePaused = true;
      }
      setState(() => _playIntent = false);
      unawaited(_player.pause());
      unawaited(_saveProgress(flush: true));
    }
    if (visible && _lifecyclePaused) {
      _lifecyclePaused = false;
      final resume = _resumeAfterInterruption;
      _resumeAfterInterruption = false;
      setState(() => _playIntent = resume);
      if (resume && !_loading && _error == null && _openedIndex == _index) {
        unawaited(_player.play());
      }
    }
    if (visible && _pendingError) {
      _queueRecovery();
    }
  }

  String _localizePipError(String? error) {
    if (error == null || error.trim().isEmpty) {
      return '无法启动画中画，请检查系统画中画设置或稍后重试';
    }
    final lower = error.toLowerCase();
    if (lower.contains('cannot be completed') ||
        lower.contains('could not be completed') ||
        lower.contains('couldn’t be completed')) {
      return '系统画中画启动未就绪，请稍后重试';
    }
    return error;
  }

  Future<void> _enterPictureInPicture() async {
    if (_closed) return;
    if (!_canUsePictureInPicture) {
      _notice('画中画未开启或当前设备暂不支持');
      return;
    }
    if (_loading) {
      _notice('正在加载视频，请稍候开启画中画');
      return;
    }
    if (_error != null) {
      _notice('视频播放出错，无法开启画中画');
      return;
    }
    if (_pictureInPictureRequested) {
      if (defaultTargetPlatform != TargetPlatform.android) {
        _notice('正在启动画中画，请稍候...');
      }
      return;
    }
    _dismissOverlaysForPictureInPicture();
    final wasPlaying = _player.state.playing;
    if (Platform.isIOS && wasPlaying) {
      await _player.pause();
    }
    final (width, height) = _pictureInPictureAspectDimensions();
    if (defaultTargetPlatform != TargetPlatform.android) {
      _notice('正在启动画中画...');
    }
    _setPictureInPictureStatus(requested: true);

    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || _closed) return;

    final mediaUrl = _plan?.url.isNotEmpty == true
        ? _plan!.url
        : (_player is LunaExoPlayer ? _player.mediaUri : '');
    final headers = _plan?.headers ?? const <String, String>{};

    String targetUrl = mediaUrl;
    Map<String, String> targetHeaders = headers;
    final isEncryptedStream =
        Platform.isIOS &&
        _plan != null &&
        _plan!.decryptionKey.isNotEmpty &&
        !_plan!.local;

    if (isEncryptedStream) {
      _notice('正在准备画中画视频...');
      try {
        final prepared = await _encryptedPlayback.prepare(
          _plan!,
          forceCache: true,
          progress: (val) {
            if (mounted && !_closed) {
              _notice('正在准备画中画 ${(val * 100).round()}%');
            }
          },
        );
        if (_closed || !mounted) return;
        targetUrl = prepared.url;
        targetHeaders = prepared.headers;
      } catch (e) {
        debugPrint('[PiP-Dart] 准备画中画加密视频失败: $e');
        _notice('准备画中画视频失败: $e');
        _setPictureInPictureStatus(requested: false);
        if (Platform.isIOS && wasPlaying && !_closed) {
          unawaited(_player.play());
        }
        return;
      }
    }

    _pictureInPictureExitTimer?.cancel();
    _pictureInPictureExitTimer = Timer(const Duration(seconds: 8), () {
      if (!_closed && _pictureInPictureRequested && !_pictureInPictureActive) {
        _setPictureInPictureStatus(requested: false);
        _notice('无法进入画中画，请检查系统设置');
        if (Platform.isIOS && wasPlaying && !_closed) {
          unawaited(_player.play());
        }
      }
    });

    final sourceRect = _pictureInPictureSourceRect();
    final arguments = <String, dynamic>{
      'width': width,
      'height': height,
      if (targetUrl.isNotEmpty) 'url': targetUrl,
      if (targetHeaders.isNotEmpty) 'headers': targetHeaders,
      'title': widget.detail.drama.title,
      'dramaId': widget.detail.drama.id,
      'episodeIndex': _index,
      'detail': widget.detail.toJson(),
      'position': _player.state.position.inMilliseconds,
      'speed': _speed,
    };
    if (sourceRect != null) arguments.addAll(sourceRect);
    _syncPictureInPictureSession();
    debugPrint(
      '[PiP-Dart] enterPictureInPicture args: url=$targetUrl, pos=${arguments['position']}, sourceRect=$sourceRect',
    );
    try {
      final status = await AppDevice.channel.invokeMapMethod<String, dynamic>(
        'enterPictureInPicture',
        arguments,
      );
      debugPrint('[PiP-Dart] enterPictureInPicture return: $status');
      if (!mounted || _closed) return;
      final supported = status?['supported'] == true;
      final active = status?['active'] == true;
      final requested = status?['requested'] == true;
      final error = status?['error'] as String?;
      _setPictureInPictureStatus(
        supported: supported,
        active: active,
        requested: requested && !active,
      );
      if (!supported) {
        _pictureInPictureExitTimer?.cancel();
        _notice('当前系统或设备不支持画中画');
        if (Platform.isIOS && wasPlaying && !_closed) {
          unawaited(_player.play());
        }
      } else if (!active && !requested) {
        _pictureInPictureExitTimer?.cancel();
        _notice(_localizePipError(error));
        if (Platform.isIOS && wasPlaying && !_closed) {
          unawaited(_player.play());
        }
      }
    } on PlatformException catch (e) {
      _pictureInPictureExitTimer?.cancel();
      _setPictureInPictureStatus(requested: false);
      _notice(_localizePipError(e.message));
      if (Platform.isIOS && wasPlaying && !_closed) {
        unawaited(_player.play());
      }
    } on MissingPluginException {
      _pictureInPictureExitTimer?.cancel();
      _setPictureInPictureStatus(supported: false, requested: false);
      _notice('当前平台不支持画中画');
      if (Platform.isIOS && wasPlaying && !_closed) {
        unawaited(_player.play());
      }
    } catch (e) {
      _pictureInPictureExitTimer?.cancel();
      _setPictureInPictureStatus(requested: false);
      _notice('启动画中画异常: $e');
      if (Platform.isIOS && wasPlaying && !_closed) {
        unawaited(_player.play());
      }
    }
  }

  Future<void> _restoreFromPictureInPicture() async {
    try {
      final status = await AppDevice.channel.invokeMapMethod<String, dynamic>(
        'stopPictureInPicture',
      );
      final position = (status?['position'] as num?)?.toInt();
      if (position != null && position > 0) {
        await _seekTo(Duration(milliseconds: position));
      }
    } catch (_) {}
    _setPictureInPictureStatus(active: false, requested: false);
    if (_playIntent && !_loading && _error == null) {
      unawaited(_player.play());
    }
  }

  Map<String, int>? _pictureInPictureSourceRect() {
    final paneContext = _videoPaneKey.currentContext;
    final renderObject = paneContext?.findRenderObject();
    if (paneContext == null ||
        renderObject is! RenderBox ||
        !renderObject.hasSize) {
      return null;
    }
    final topLeft = renderObject.localToGlobal(Offset.zero);
    final size = renderObject.size;
    if (size.width <= 0 || size.height <= 0) return null;
    final rawRatio = _aspectRatio.isFinite && _aspectRatio > 0
        ? _aspectRatio
        : size.width / size.height;
    final targetRatio = rawRatio.clamp(1 / 2.39, 2.39).toDouble();
    final containerRatio = size.width / size.height;
    late final double dx;
    late final double dy;
    late final double videoWidth;
    late final double videoHeight;
    if (containerRatio > targetRatio) {
      videoHeight = size.height;
      videoWidth = size.height * targetRatio;
      dx = (size.width - videoWidth) / 2;
      dy = 0;
    } else {
      videoWidth = size.width;
      videoHeight = size.width / targetRatio;
      dx = 0;
      dy = (size.height - videoHeight) / 2;
    }
    final ratio =
        MediaQuery.maybeOf(paneContext)?.devicePixelRatio ??
        View.of(paneContext).devicePixelRatio;
    final left = ((topLeft.dx + dx) * ratio).round().clamp(0, 100000);
    final top = ((topLeft.dy + dy) * ratio).round().clamp(0, 100000);
    final right = ((topLeft.dx + dx + videoWidth) * ratio).round().clamp(
      0,
      100000,
    );
    final bottom = ((topLeft.dy + dy + videoHeight) * ratio).round().clamp(
      0,
      100000,
    );
    if (right <= left || bottom <= top) return null;
    return {'left': left, 'top': top, 'right': right, 'bottom': bottom};
  }

  void _attachLanPlayback() {
    LanController.current?.attachPlayback(
      LanPlaybackHost(
        identity: _lanIdentity,
        title:
            '${widget.detail.drama.title} · 第 ${widget.detail.episodes[_index].number} 集',
        stop: _stopForLan,
      ),
    );
  }

  void _acknowledgeHandoff() {
    final handoff = widget.handoff;
    if (!_handoffOwned ||
        handoff == null ||
        handoff.cancelled ||
        handoff.started.isCompleted ||
        _closed ||
        _loading ||
        _error != null ||
        _openedIndex != _index ||
        _index != widget.initialIndex ||
        widget.store.profileEpoch != _profileEpoch) {
      return;
    }
    final state = _player.state;
    final position = state.position.inMilliseconds / 1000;
    final duration = state.duration.inMilliseconds / 1000;
    if (duration > 0 && handoff.position > duration + 2) {
      handoff.fail('续播位置超过接收端分集时长');
      return;
    }
    if (!state.playing ||
        state.buffering ||
        (state.width ?? 0) <= 0 ||
        position < handoff.position - .5 ||
        position > handoff.position + 20) {
      return;
    }
    _lanFirstPosition ??= position;
    if (position >= _lanFirstPosition! + .15) handoff.acknowledge(position);
  }

  Future<void> _stopForLan() async {
    final generation = _generation;
    await _serialize(() async {
      if (_closed ||
          generation != _generation ||
          widget.store.profileEpoch != _profileEpoch) {
        return;
      }
      _playIntent = false;
      _interactions.cancel();
      _enhancement.suspend();
      _health.reset();
      await _player.pause();
      await _saveProgress(flush: true);
    });
  }

  Map<String, dynamic> _applyCastSync(Map<String, dynamic> body, int recvAtMs) {
    final episode = body['episode'];
    final position = body['position'];
    final playing = body['playing'];
    final rate = body['rate'];
    final sentAt = body['sentAt'];
    final offset = body['offsetMs'];
    if (episode is! int ||
        position is! num ||
        !position.isFinite ||
        position < 0 ||
        position > 604800 ||
        playing is! bool ||
        rate is! num ||
        !(rate > 0 && rate <= 8) ||
        sentAt is! num ||
        offset is! num) {
      throw const FormatException('分屏同步数据无效');
    }
    if (_closed || widget.store.profileEpoch != _profileEpoch) {
      throw StateError('接收端播放已关闭');
    }
    _castLastSyncAt = DateTime.now();
    if (_castStalled) {
      _castStalled = false;
      _notice('已恢复同步');
    }
    // 本机刚操作过播放/暂停/拖动，等声音端处理完再跟随，避免被旧状态拉回
    if (DateTime.now().isBefore(_castHoldUntil)) {
      return {'state': 'hold'};
    }
    if (episode != widget.detail.episodes[_index].number) {
      final next = widget.detail.episodes.indexWhere(
        (item) => item.number == episode,
      );
      if (next < 0) throw StateError('接收端没有第 $episode 集');
      if (!_loading) {
        // 自动连播时声音端换集瞬间会短暂上报「暂停」，跟随端保持播放，避免闪出控制按钮
        _castSwitchedAt = DateTime.now();
        unawaited(
          _play(
            next,
            position: position.toDouble(),
            playWhenReady: playing || _playIntent,
            showControlsOnReady: false,
          ),
        );
      }
      return {'state': 'switching'};
    }
    if (_loading || _error != null || _openedIndex != _index) {
      return {'state': 'loading'};
    }
    final transit = offset == 0
        ? 0.05
        : ((recvAtMs - sentAt.toDouble() - offset.toDouble()) / 1000).clamp(
            0.0,
            2.0,
          );
    final state = _player.state;
    final current = state.position.inMilliseconds / 1000;
    final target = position.toDouble() + (playing ? transit * rate : 0);
    if (!playing && _playIntent) {
      final durationSeconds = state.duration.inMilliseconds / 1000;
      final settling =
          DateTime.now().difference(_castSwitchedAt) <
          const Duration(seconds: 3);
      final atEnd = durationSeconds > 0 && position >= durationSeconds - 1.5;
      // 一集播完 / 刚换集时声音端的瞬时「暂停」不是用户操作，忽略
      if (settling || atEnd) return {'state': 'settling'};
    }
    _playIntent = playing;
    if (!playing) {
      if (state.playing) unawaited(_player.pause());
      if ((current - target).abs() > .3) {
        unawaited(_player.seek(Duration(milliseconds: (target * 1000).round())));
      }
      return {'state': 'paused', 'position': current};
    }
    if (!state.playing) unawaited(_player.play());
    final raw = target - current;
    _castError = (raw - _castError).abs() > 1.0
        ? raw
        : _castError * .6 + raw * .4;
    final error = _castError;
    final now = DateTime.now();
    var wanted = rate.toDouble();
    if (error.abs() > 1.5) {
      if (now.difference(_castSeekedAt) > const Duration(seconds: 4)) {
        _castSeekedAt = now;
        _castError = 0;
        unawaited(
          _player.seek(Duration(milliseconds: (target * 1000).round())),
        );
      }
    } else if (error.abs() > .15) {
      // 误差较大才轻微调速（最多 ±2%），调速幅度小到听不出变调
      wanted = rate * (1 + (error * .12).clamp(-.02, .02));
    }
    wanted = (wanted * 100).round() / 100;
    if ((state.rate - wanted).abs() > .005) {
      unawaited(_player.setRate(wanted));
    }
    return {'state': 'playing', 'position': current, 'error': error};
  }

  bool _nowPlayingLogged = false;

  void _publishNowPlaying() {
    if (_closed || widget.feed || _openedIndex != _index) return;
    if (!_nowPlayingLogged) {
      _nowPlayingLogged = true;
      DiaryService.add('[锁屏] 首次发布播放信息: 第${widget.detail.episodes[_index].number}集');
    }
    final episodes = widget.detail.episodes;
    unawaited(
      AppDevice.channel
          .invokeMethod<void>('nowPlayingUpdate', {
            'title':
                '${widget.detail.drama.title} 第${episodes[_index].number}集',
            'duration': _player.state.duration.inMilliseconds / 1000,
            'position': _currentPosition,
            'rate': _playIntent ? _player.state.rate : 0.0,
            'hasNext': _index + 1 < episodes.length,
            'hasPrevious': _index > 0,
          })
          .catchError((Object _) {}),
    );
  }

  void _onRemoteCommand(Map<String, dynamic> event) {
    if (_closed || widget.feed) return;
    final command = '${event['command']}';
    DiaryService.add('[遥控] 收到系统指令: $command');
    switch (command) {
      case 'pause':
        _onHeadphonesUnplugged();
      case 'play':
        if (!_playIntent && !_castFollower) _togglePlayback();
      case 'toggle':
        if (_castFollower) return;
        _togglePlayback();
      case 'next':
        if (_index + 1 < widget.detail.episodes.length && !_castFollower) {
          unawaited(_play(_index + 1));
        }
      case 'previous':
        if (_index > 0 && !_castFollower) unawaited(_play(_index - 1));
      case 'seek':
        final position = event['position'];
        if (position is num && position.isFinite && position >= 0) {
          unawaited(_seekTo(Duration(milliseconds: (position * 1000).round())));
        }
    }
    _publishNowPlaying();
  }

  void _onHeadphonesUnplugged() {
    if (_closed || widget.feed) return;
    DiaryService.add('[分屏] 耳机断开，暂停播放');
    if (_castFollower) {
      unawaited(_stopCastFollower());
      return;
    }
    if (!_playIntent) return;
    setState(() => _playIntent = false);
    unawaited(_player.pause());
    unawaited(_saveProgress(flush: true));
  }

  Future<void> _setVideoDecode(bool enabled) async {
    final player = _player;
    if (player is LunaExoPlayer) {
      await player.setAudioOnly(!enabled).catchError((Object error) {
        DiaryService.add('[分屏] 切换纯音频失败: $error');
      });
      return;
    }
    final native = _player.platform;
    if (native is NativePlayer) {
      await native
          .setProperty('vid', enabled ? 'auto' : 'no')
          .catchError((Object _) {});
    }
  }

  Future<void> _stopCastFollower() async {
    if (!_castFollower || _closed) return;
    DiaryService.add('[分屏] 对方停止分屏，本机停止跟随');
    _castFollower = false;
    await _player.pause().catchError((Object _) {});
    await _player.setVolume(100).catchError((Object _) {});
    await _setVideoDecode(true);
    if (mounted) {
      setState(() {
        _playIntent = false;
        _castAudioTarget = null;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('对方已停止分屏播放')));
    }
  }

  /// 声音端上报给电脑的倍速：以用户设定的倍速为准。
  /// 后台暂停/恢复后播放引擎可能把倍速重置成 1.0，这里发现不一致就立刻纠正。
  double _speedForCast() {
    final wanted = _speed.toDouble();
    if ((_player.state.rate - wanted).abs() > .01 && _openedIndex == _index) {
      unawaited(_player.setRate(wanted).catchError((Object _) {}));
    }
    return wanted;
  }

  /// 手机作为分屏声音端被暂停时，循环静音保活，避免 iOS 挂起 App 导致电脑再点播放没声音、连接断开。
  void _syncKeepAlive() {
    if (_closed) return;
    final need =
        Platform.isIOS &&
        _castAudioTarget != null &&
        !_playIntent &&
        !_player.state.playing;
    if (need) {
      _keepAliveTimer ??= Timer(const Duration(milliseconds: 1200), () {
        _keepAliveTimer = null;
        if (!_closed) unawaited(_keepAlive.start());
      });
    } else {
      _keepAliveTimer?.cancel();
      _keepAliveTimer = null;
      if (_keepAlive.running) unawaited(_keepAlive.stop());
    }
  }

  void _beginCastAudio(LanController link) {
    final peer = link.connection?.peer.name ?? '电脑';
    final videoHere = link.kind == 'computer';
    if (videoHere) {
      unawaited(_player.setVolume(0));
    } else {
      setState(() => _castAudioTarget = peer);
      unawaited(_setVideoDecode(false));
    }
    link.startCast(
      source: () => LanCastState(
        episode: widget.detail.episodes[_index].number,
        position: _currentPosition,
        playing: _player.state.playing && _playIntent,
        rate: _speedForCast(),
      ),
      onControl: _applyCastControl,
      onEnded: () {
        if (videoHere) {
          unawaited(_player.setVolume(100));
        } else {
          unawaited(_setVideoDecode(true));
        }
        if (mounted && !_closed) setState(() => _castAudioTarget = null);
        _syncKeepAlive();
        if (link.castMessage.contains('失去连接')) {
          _notice('与对方断开，正在尝试自动重新投屏…');
          unawaited(_autoRecast(link));
        }
      },
    );
  }

  Future<void> _pushToDevice() async {
    final link = LanController.current;
    if (link == null ||
        _panelOpen ||
        _closed ||
        _loading ||
        _error != null ||
        widget.mediaId != null) {
      return;
    }
    final generation = _generation;
    final index = _index;
    bool current() =>
        mounted &&
        !_closed &&
        generation == _generation &&
        index == _index &&
        widget.store.profileEpoch == _profileEpoch;
    _interactions.cancel();
    setState(() => _panelOpen = true);
    try {
      await showLanPush(
        context,
        link,
        snapshot: () => LanPlaybackIntent(
          drama: widget.detail.drama,
          episodeID: widget.detail.episodes[index].id,
          episode: widget.detail.episodes[index].number,
          position: _currentPosition,
        ),
        stillCurrent: current,
        onAccepted: () async {
          if (!current()) throw StateError('本机播放内容已变更');
          await _stopForLan();
          if (!current()) throw StateError('本机播放内容已变更');
        },
        onCastAccepted: () async {
          if (!current()) throw StateError('本机播放内容已变更');
          _beginCastAudio(link);
        },
      );
    } catch (error) {
      if (mounted && !_closed) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted && !_closed) setState(() => _panelOpen = false);
    }
  }

  void _syncPreload() {
    if (_closed) return;
    if (!_preloadEnabled ||
        !_active ||
        widget.localOnly ||
        _plan?.offline == true ||
        _loading ||
        _error != null ||
        _openedIndex != _index ||
        widget.store.profileEpoch != _profileEpoch ||
        widget.store.locked ||
        _index + 1 >= widget.detail.episodes.length) {
      _preloader.clear();
      if (_standbyRawUrl != null) unawaited(_dropStandby());
      return;
    }
    final state = _player.state;
    if (!state.playing || state.buffering || !_playIntent) {
      _preloader.pause();
      return;
    }
    if (!PlaybackPreloader.shouldPrepare(
      duration: state.duration,
      position: state.position,
      rate: _speed,
    )) {
      _preloader.pause();
      return;
    }
    _preloader.prepare(
      widget.detail.drama,
      widget.detail.episodes[_index + 1],
      quality: _requestedQuality,
    );
    _warmStandby();
  }

  /// iOS：下一集播放地址就绪后，提前建好解密流与原生控制器，换集时直接接管。
  void _warmStandby() {
    final player = _player;
    if (_closed ||
        !Platform.isIOS ||
        player is! LunaExoPlayer ||
        _standbyBusy ||
        _castFollower ||
        (LanController.current?.casting ?? false)) {
      return;
    }
    final raw = _preloader.ready;
    if (raw == null || raw.local || raw.url.isEmpty) return;
    if (_standbyRawUrl == raw.url) return;
    _standbyBusy = true;
    final tag = ++_standbyTag;
    unawaited(() async {
      final encrypted = EncryptedPlayback();
      var kept = false;
      try {
        final prepared = await encrypted.prepare(raw);
        if (_closed || tag != _standbyTag) return;
        final ok = await player.warmUp(
          Media(
            prepared.url,
            httpHeaders: prepared.headers,
            extras: {'decryptionKey': prepared.decryptionKey},
          ),
        );
        if (!ok || _closed || tag != _standbyTag) return;
        await _dropStandby(keepPlayer: true);
        _standbyEncrypted = encrypted;
        _standbyPlan = prepared;
        _standbyRawUrl = raw.url;
        kept = true;
      } catch (_) {
      } finally {
        if (!kept) await encrypted.close().catchError((Object _) {});
        _standbyBusy = false;
      }
    }());
  }

  Future<void> _dropStandby({bool keepPlayer = false}) async {
    _standbyTag++;
    final encrypted = _standbyEncrypted;
    _standbyEncrypted = null;
    _standbyPlan = null;
    _standbyRawUrl = null;
    if (!keepPlayer) {
      final player = _player;
      if (player is LunaExoPlayer) {
        unawaited(player.discardStandby().catchError((Object _) {}));
      }
    }
    if (encrypted != null) {
      unawaited(encrypted.close().catchError((Object _) {}));
    }
  }

  void _syncDanmaku({bool discontinuity = false}) {
    if (_closed) return;
    final state = _player.state;
    _danmaku.update(
      position: state.position,
      duration: state.duration,
      speed: state.rate,
      playing: state.playing && _playIntent && !state.completed,
      buffering: state.buffering,
      foreground: _foreground,
      available:
          !_loading &&
          _error == null &&
          _openedIndex == _index &&
          widget.store.profileEpoch == _profileEpoch &&
          !widget.store.locked &&
          widget.store.allowsSource('hongguo'),
      discontinuity: discontinuity,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final television = AppLayout.isTelevision(context);
    if (_television != television) {
      _fullscreen = false;
      _automaticFullscreenSuppressed = false;
      _interactions.cancel();
    }
    _television = television;
    _orientationController = AppOrientationScope.maybeOf(context);
    final orientation = MediaQuery.orientationOf(context);
    if (_lastOrientation != null && _lastOrientation != orientation) {
      _automaticFullscreenSuppressed = false;
      _interactions.cancel();
    }
    _lastOrientation = orientation;
    _scheduleSystemUi();
  }

  void _scheduleSystemUi() {
    if (widget.feed) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _closed || (!_mobile && !_television)) return;
      final fullscreen = _showFullscreen;
      if (_systemFullscreen == fullscreen) return;
      _systemFullscreen = fullscreen;
      unawaited(
        SystemChrome.setEnabledSystemUIMode(
          fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
        ),
      );
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    if (_castFollower || (LanController.current?.casting ?? false)) {
      DiaryService.add(
        '[分屏] 生命周期=${state.name} 角色=${_castFollower ? "跟随端" : "发送端"} '
        '播放中=${_player.state.playing} 位置=${_currentPosition.toStringAsFixed(1)}s',
      );
    }
    _applyLifecycleVisibility();
    _publishNowPlaying();
  }

  void _queueRecovery({bool force = false}) {
    if (_closed || !_acceptErrors || _error != null) {
      return;
    }
    _pendingError = true;
    _requireRecovery = _requireRecovery || force;
    if (!_active || (_errorTimer?.isActive ?? false)) {
      return;
    }
    final ticket = _generation;
    final position = _player.state.position;
    _errorTimer = Timer(const Duration(milliseconds: 900), () {
      if (_closed || ticket != _generation || !_active || !_acceptErrors) {
        return;
      }
      _pendingError = false;
      final required = _requireRecovery;
      _requireRecovery = false;
      final state = _player.state;
      if (!required &&
          state.playing &&
          !state.buffering &&
          (state.width ?? 0) > 0 &&
          state.position > position + const Duration(milliseconds: 300)) {
        return;
      }
      unawaited(_recover());
    });
  }

  Future<void> _recover() async {
    final current = _plan;
    if (_closed ||
        !_acceptErrors ||
        !_active ||
        current == null ||
        _error != null) {
      return;
    }
    _acceptErrors = false;
    _danmaku.setPlan(null);
    _errorTimer?.cancel();
    _pendingError = false;
    _requireRecovery = false;
    final position = _currentPosition;
    final action = current.offline
        ? PlaybackRecoveryAction.stop
        : _recovery.next(
            current,
            decryptedStream: _encryptedPlayback.isStreamPlan(current),
            allowCache:
                _player is LunaExoPlayer &&
                (Platform.isAndroid || Platform.isIOS),
          );
    if (action == PlaybackRecoveryAction.stop) {
      _resumePosition = position;
      final ticket = _generation;
      try {
        await _serialize(() async {
          if (_closed || ticket != _generation) {
            return;
          }
          try {
            await _saveProgress();
            _openedIndex = -1;
            await _player.stop();
          } finally {
            await widget.repository.release(current.session);
          }
        });
      } catch (_) {}
      if (mounted && !_closed && ticket == _generation) {
        setState(() {
          _loading = false;
          _localFailure = current.offline;
          _error = current.offline
              ? widget.allowOnlineFallback
                    ? '本地视频读取失败，请重试或重新下载；也可以手动改为在线播放。'
                    : '本地成品读取失败，请重试或重新生成。'
              : '自动恢复未成功，请检查网络后重试，也可换一集或选择其他清晰度。';
        });
      }
      return;
    }
    await _play(
      _index,
      position: position,
      recoveryAction: action,
      recoveryPlan: current,
    );
  }

  void _sendCastControl(Map<String, dynamic> body) {
    _castHoldUntil = DateTime.now().add(const Duration(milliseconds: 2500));
    final link = LanController.current;
    if (link == null) return;
    unawaited(
      link.sendCastControl(body).catchError((Object error) {
        DiaryService.add('[分屏] 控制指令发送失败: $error');
        _castHoldUntil = DateTime(2000);
      }),
    );
  }

  Future<void> _applyCastControl(Map<String, dynamic> body) async {
    if (_closed || _loading || _error != null) return;
    switch (body['action']) {
      case 'pause':
        if (_playIntent) _togglePlayback();
      case 'play':
        if (!_playIntent) _togglePlayback();
      case 'episode':
        final number = body['number'];
        final target = widget.detail.episodes.indexWhere(
          (item) => item.number == number,
        );
        if (target >= 0 && target != _index) {
          await _play(target, showControlsOnReady: false);
        }
      case 'seek':
        final position = body['position'];
        if (position is num && position.isFinite && position >= 0) {
          await _seekTo(Duration(milliseconds: (position * 1000).round()));
        }
    }
  }

  void _togglePlayback() {
    if (_closed || _loading || _error != null) return;
    if (_castFollower) {
      // 跟随端的操作转发给声音端，本机先行响应
      final play = !_playIntent;
      setState(() => _playIntent = play);
      unawaited(play ? _player.play() : _player.pause());
      _sendCastControl({'action': play ? 'play' : 'pause'});
      return;
    }
    _handoffOwned = false;
    widget.handoff?.fail('接收端已操作播放');
    _interactions.cancel();
    setState(() => _playIntent = !_playIntent);
    if (_playIntent) _enhancement.mediaReady();
    _health.reset();
    if (_playIntent && _player.state.completed) {
      unawaited(_play(_index));
      return;
    }
    unawaited(_playIntent ? _player.play() : _player.pause());
    if (!_playIntent) unawaited(_saveProgress(flush: true));
    _syncDanmaku();
    _syncNativePictureInPictureConfig();
  }

  final int _watchAccountRevision = HongguoAccountSession.shared.revision;

  Future<void> _saveProgress({bool flush = false}) async {
    if (_openedIndex < 0 ||
        widget.store.profileEpoch != _profileEpoch ||
        _watchAccountRevision != HongguoAccountSession.shared.revision) {
      return;
    }
    final position = _player.state.position.inMilliseconds / 1000;
    final duration = _player.state.duration.inMilliseconds / 1000;
    final canSaveZero =
        flush &&
        (_savedProgressKey?.startsWith(
              '${widget.mediaId ?? widget.detail.drama.id}:$_openedIndex:',
            ) ??
            false);
    if (!position.isFinite ||
        !duration.isFinite ||
        (position < .1 && !canSaveZero) ||
        duration <= 0) {
      return;
    }
    final store = widget.store;
    final progressKey =
        '${widget.mediaId ?? widget.detail.drama.id}:$_openedIndex:$position:$duration';
    if (_savedProgressKey == progressKey &&
        _saveWarning == null &&
        (!flush || !store.usesAccountLibrary(widget.detail.drama.id))) {
      if (flush && widget.mediaId == null) LanController.current?.flush();
      return;
    }
    final entry = WatchEntry(
      drama: widget.repository.catalogUpdates.current(widget.detail.drama),
      episode: widget.detail.episodes[_openedIndex].number,
      position: position,
      duration: duration,
      updatedAt: DateTime.now(),
    );
    final itemId =
        ((_plan?.danmakuId.isNotEmpty ?? false)
                ? _plan!.danmakuId
                : widget.detail.episodes[_openedIndex].id)
            .split(':')
            .last;
    try {
      await Future<void>.value();
      if (store.profileEpoch != _profileEpoch) return;
      if (widget.mediaId == null) {
        await store.saveWatch(entry, itemId: itemId, force: flush);
        if (flush) LanController.current?.flush();
      } else {
        await store.saveMediaWatch(widget.mediaId!, entry);
      }
      _savedProgressKey = progressKey;
      if (mounted && !_closed && _saveWarning != null) {
        setState(() => _saveWarning = null);
      }
    } catch (error) {
      if (mounted && !_closed && _saveWarning == null) {
        setState(
          () => _saveWarning = error is HongguoAccountFailure
              ? '账号观看进度尚未同步，请检查网络后重试。'
              : '观看进度尚未保存，请检查存储空间后重试。',
        );
      }
    }
  }

  Future<void> _serialize(Future<void> Function() operation) {
    final next = _operations.catchError((Object _) {}).then((_) => operation());
    _operations = next;
    return next;
  }

  Future<void> _play(
    int index, {
    double position = 0,
    PlaybackRecoveryAction? recoveryAction,
    PlaybackPlan? recoveryPlan,
    bool playWhenReady = true,
    PlaybackPlan? handoffPlan,
    bool showControlsOnReady = true,
  }) async {
    await _playbackLease?.ready;
    if (_closed ||
        widget.store.profileEpoch != _profileEpoch ||
        index < 0 ||
        index >= widget.detail.episodes.length) {
      return;
    }
    if (recoveryAction != null &&
        recoveryAction != PlaybackRecoveryAction.cache) {
      final previousGeneration = _generation;
      await Future<void>.delayed(_recovery.retryDelay);
      if (_closed || previousGeneration != _generation) return;
    }
    _interactions.cancel();
    if (widget.handoff != null &&
        handoffPlan == null &&
        recoveryAction == null) {
      _handoffOwned = false;
      widget.handoff?.fail('接收端已更换播放内容');
    }
    if (index != _index) _forceOnline = false;
    final forceEncryptedCache =
        _encryptedVideoOutputFailed ||
        (recoveryAction != null &&
            (_recovery.cacheAttempted ||
                (_plan?.decryptionKey.isNotEmpty ?? false)));
    final warmed =
        handoffPlan ??
        (recoveryAction == null && _preloadEnabled && !widget.localOnly
            ? _preloader.take(
                widget.detail.drama,
                widget.detail.episodes[index],
                quality: _requestedQuality,
                online: _forceOnline,
              )
            : null);
    _preloader.clear();
    final ticket = ++_generation;
    final switchWatch = Stopwatch()..start();
    var resolvedMs = 0;
    var openedMs = 0;
    _enhancement.suspend();
    _seekSequence++;
    _danmaku.setPlan(null);
    _acceptErrors = false;
    _pendingError = false;
    _requireRecovery = false;
    _errorTimer?.cancel();
    _health.reset();
    if (recoveryAction == null) {
      _recovery.reset();
      _playIntent = playWhenReady;
      if (_lifecyclePaused) {
        _resumeAfterInterruption = playWhenReady;
        _playIntent = false;
      }
    }
    _resumePosition = position;
    _showControlsOnPlaybackReady = showControlsOnReady;
    final isSeamlessAdvance =
        !showControlsOnReady &&
        recoveryAction == null &&
        (index == _index + 1 || warmed != null);
    setState(() {
      _index = index;
      _loading = !isSeamlessAdvance && warmed == null;
      _error = null;
      _localFailure = false;
      _loadingMessage = switch (recoveryAction) {
        PlaybackRecoveryAction.cache => '正在尝试本集缓存解密',
        PlaybackRecoveryAction.alternative => '正在切换备用线路',
        PlaybackRecoveryAction.refresh =>
          '正在重新获取播放地址（${_recovery.attempts}/${_recovery.attemptLimit}）',
        _ => '正在准备播放',
      };
    });
    LanController.current?.detachPlayback(_lanIdentity);
    _lanIdentity = Object();
    _attachLanPlayback();
    PlaybackPlan? prepared;
    PlaybackPlan? retained;
    PlaybackPlan? failedPlan;
    bool installed = false;
    var failureStage = 'resolve';
    try {
      await _serialize(() async {
        if (_closed || ticket != _generation) {
          return;
        }
        await _saveProgress(flush: true);
        await _enhancement.beforeMedia();
        if (_closed || ticket != _generation) return;
        _openedIndex = -1;
        final standbyHit =
            Platform.isIOS &&
            warmed != null &&
            !forceEncryptedCache &&
            _standbyEncrypted != null &&
            _standbyRawUrl == warmed.url;
        if (!isSeamlessAdvance || (_player is LunaExoPlayer && !standbyHit)) {
          await _player.stop();
        }
        await _encryptedPlayback.cancel();
        final previous = _plan ?? recoveryPlan;
        _plan = null;
        if (recoveryAction == PlaybackRecoveryAction.alternative ||
            recoveryAction == PlaybackRecoveryAction.cache) {
          retained = previous;
        } else if (previous != null) {
          if (recoveryAction == PlaybackRecoveryAction.refresh) {
            failedPlan = previous;
          }
          if (isSeamlessAdvance) {
            unawaited(
              widget.repository
                  .release(previous.session)
                  .catchError((Object _) {}),
            );
          } else {
            await widget.repository.release(previous.session);
          }
        }
      });
      if (_closed || ticket != _generation) {
        return;
      }
      prepared = retained != null
          ? recoveryAction == PlaybackRecoveryAction.cache
                ? await _loader.use(retained!)
                : await _loader.fallback(retained!)
          : failedPlan != null
          ? await _loader.refresh(
              widget.detail.drama,
              widget.detail.episodes[index],
              failedPlan!,
              quality: _requestedQuality,
            )
          : warmed != null
          ? await _loader.use(warmed)
          : await _loader.load(
              widget.detail.drama,
              widget.detail.episodes[index],
              quality: _requestedQuality,
              localOnly: widget.localOnly,
              online: _forceOnline,
            );
      resolvedMs = switchWatch.elapsedMilliseconds;
      if (prepared == null) {
        return;
      }
      if (Platform.isAndroid || Platform.isIOS) {
        failureStage = 'prepare';
        final standbyReady =
            Platform.isIOS &&
            warmed != null &&
            !forceEncryptedCache &&
            _standbyEncrypted != null &&
            _standbyPlan != null &&
            _standbyRawUrl == prepared.url;
        if (standbyReady) {
          // 接管已提前准备好的解密流（原控制器预热也会在 open 时被接管）
          final old = _encryptedPlayback;
          _encryptedPlayback = _standbyEncrypted!;
          prepared = _standbyPlan!;
          _standbyEncrypted = null;
          _standbyPlan = null;
          _standbyRawUrl = null;
          _standbyTag++;
          unawaited(old.close().catchError((Object _) {}));
        } else {
          if (_standbyRawUrl != null) unawaited(_dropStandby());
          prepared = await _encryptedPlayback.prepare(
            prepared,
            forceCache: forceEncryptedCache,
            progress: (value) {
              if (mounted && !_closed && ticket == _generation) {
                setState(() {
                  _loading = true;
                  _loadingMessage = '正在准备视频 ${(value * 100).round()}%';
                });
              }
            },
          );
        }
      }
      final plan = prepared;
      failureStage = 'open';
      await _serialize(() async {
        if (_closed || ticket != _generation) {
          await widget.repository.release(plan.session);
          return;
        }
        if (plan.url.isEmpty) {
          throw AppFailure('站源未返回播放地址，请重试');
        }
        final platform = _player.platform;
        if (_player is! LunaExoPlayer && platform is NativePlayer) {
          if (Platform.isAndroid) {
            if (_television) {
              await platform.setProperty('hwdec', 'mediacodec');
              await platform.setProperty('hwdec-codecs', 'all');
              await platform.setProperty('opengl-pbo', 'yes');
              await platform.setProperty('video-latency-hacks', 'no');
              await platform.setProperty('scale', 'spline36');
              await platform.setProperty('cscale', 'spline36');
              await platform.setProperty('dscale', 'mitchell');
              await platform.setProperty('correct-downscaling', 'yes');
              await platform.setProperty('sigmoid-upscaling', 'yes');
              await platform.setProperty('vd-lavc-skiploopfilter', 'none');
              await platform.setProperty('vd-lavc-skipidct', 'none');
              await platform.setProperty('vd-lavc-threads', '4');
              await platform.setProperty(
                'demuxer-max-bytes',
                '${32 * 1024 * 1024}',
              );
              await platform.setProperty(
                'demuxer-max-back-bytes',
                '${8 * 1024 * 1024}',
              );
              await platform.setProperty('demuxer-readahead-secs', '15');
            } else {
              await platform.setProperty('hwdec', 'auto-safe');
              await platform.setProperty('hwdec-codecs', 'all');
              await platform.setProperty('scale', 'spline36');
              await platform.setProperty('cscale', 'spline36');
              await platform.setProperty('dscale', 'mitchell');
              await platform.setProperty('correct-downscaling', 'yes');
              await platform.setProperty('sigmoid-upscaling', 'yes');
              await platform.setProperty('vd-lavc-skiploopfilter', 'none');
              await platform.setProperty('vd-lavc-threads', '4');
              await platform.setProperty(
                'demuxer-max-bytes',
                '${32 * 1024 * 1024}',
              );
            }
            await platform.setProperty('vd-lavc-fast', 'no');
            await platform.setProperty('video-sync', 'audio');
            await platform.setProperty('framedrop', 'vo');
          }
          await platform.setProperty(
            'demuxer-lavf-o',
            [
              'seg_max_retry=3',
              'strict=experimental',
              'allowed_extensions=ALL',
              plan.local
                  ? 'protocol_whitelist=[file,crypto,data]'
                  : 'protocol_whitelist=[http,https,tcp,tls,crypto,data,file]',
              if (plan.decryptionKey.isNotEmpty)
                'decryption_key=${plan.decryptionKey}',
            ].join(','),
          );
          await platform.setProperty('network-timeout', '20');
        }
        _plan = plan;
        installed = true;
        _acceptErrors = true;
        DiaryService.add(
          '[Play] 打开媒体: 剧=${widget.detail.drama.cleanSourceId}, 集=${widget.detail.episodes[index].number}, local=${plan.local}, encrypted=${plan.decryptionKey.isNotEmpty}, host=${Uri.tryParse(plan.url)?.host}',
        );
        await _player.open(
          Media(
            plan.url,
            httpHeaders: plan.headers,
            extras: {'decryptionKey': plan.decryptionKey},
            start: position > 0
                ? Duration(milliseconds: (position * 1000).round())
                : null,
          ),
          play: _active && _playIntent,
        );
        if (_closed || ticket != _generation) {
          return;
        }
        _openedIndex = index;
        openedMs = switchWatch.elapsedMilliseconds;
        DiaryService.add(
          '[Play] 清晰度判定: 请求=${_requestedQuality > 0 ? "${_requestedQuality}P" : "自动(优先高清)"}, '
          '源下发=${plan.quality > 0 ? "${plan.quality}P" : "未知"}, '
          '当前集可选=[${plan.qualities.map((q) => "${q}P").join('/')}], '
          '状态=${_requestedQuality > 0 && plan.quality > 0 && _requestedQuality != plan.quality ? "当前集无请求档位，自动回退/匹配" : "完全匹配"}',
        );
        _diagnosticsTimer?.cancel();
        _diagnosticsTimer = Timer(const Duration(seconds: 2), () async {
          if (_closed || ticket != _generation) return;
          final diag = await _getDiagnostics();
          if (diag != null) {
            DiaryService.add(diag.toDiaryLog());
          }
        });
        _enhancement.mediaReady();
        _attachLanPlayback();
        _health.reset();
        await _interactions.applySpeed();
        if (mounted && !_closed && ticket == _generation) {
          setState(() {
            _loading = false;
          });
          DiaryService.add(
            '[换集] 第${widget.detail.episodes[index].number}集 总耗时=${switchWatch.elapsedMilliseconds}ms '
            '取地址=${resolvedMs}ms 准备并打开=${openedMs - resolvedMs}ms '
            '预热=${warmed != null} 无缝=$isSeamlessAdvance',
          );
          _danmaku.setPlan(plan);
          _syncDanmaku();
          _acknowledgeHandoff();
          _menuRevision.value++;
          _syncNativePictureInPictureConfig();
          if (_pictureInPictureActive) {
            _syncPictureInPictureSession();
          }
        }
      });
    } catch (error) {
      DiaryService.add(
        '[Play] 播放失败: 剧=${widget.detail.drama.cleanSourceId}, 集=${widget.detail.episodes[index].number}, 阶段=$failureStage, 恢复=${_recovery.attempts}/${PlaybackRecovery.attemptLimitFor(error is AppFailure ? error.code : '')}, ${playbackFailureSummary(error)}',
      );
      if (!_closed && mounted && ticket == _generation) {
        if (prepared != null && identical(_plan, prepared)) {
          _acceptErrors = true;
          _queueRecovery();
        } else {
          if (prepared != null) {
            await widget.repository.release(prepared.session);
          }
          if (!widget.localOnly &&
              error is! FormatException &&
              error is! FileSystemException) {
            final failed = prepared ?? failedPlan ?? retained ?? recoveryPlan;
            final action = _recovery.next(
              failed,
              errorCode: error is AppFailure ? error.code : '',
            );
            if (action != PlaybackRecoveryAction.stop) {
              unawaited(
                _play(
                  index,
                  position: position,
                  recoveryAction: action,
                  recoveryPlan: failed,
                  playWhenReady: _playIntent,
                ),
              );
              return;
            }
          }
          if (mounted && !_closed && ticket == _generation) {
            setState(() {
              _loading = false;
              _localFailure =
                  (error is AppFailure && error.code == 'local_media') ||
                  (widget.localOnly && !_forceOnline);
              _error = error is AppFailure
                  ? error.message
                  : error is FileSystemException
                  ? '无法写入视频缓存，请检查剩余空间后重试。'
                  : '无法播放这一集，请重试或换一集。';
              widget.handoff?.fail(_error!);
            });
            _syncNativePictureInPictureConfig();
          }
        }
      } else if (prepared != null && !installed) {
        await widget.repository.release(prepared.session);
      }
    } finally {
      if (warmed != null && !installed) {
        await widget.repository.release(warmed.session);
      }
      if (retained != null &&
          (!installed || _plan?.session != retained!.session)) {
        await widget.repository.release(retained!.session);
      }
    }
  }

  Future<void> _switchOnline() async {
    _forceOnline = true;
    await _retry();
  }

  Future<void> _retry({int? quality}) async {
    final position = _currentPosition;
    if (quality != null) {
      _requestedQuality = quality;
    }
    await _play(
      _index,
      position: position,
      playWhenReady: quality == null || _error != null || _playIntent,
    );
  }

  bool get _showFullscreen =>
      !widget.feed &&
      (_television ||
          _fullscreen ||
          (_mobile &&
              !_automaticFullscreenSuppressed &&
              _aspectRatio >= 1 &&
              MediaQuery.orientationOf(context) == Orientation.landscape));

  Future<void> _rotate() async {
    if (_rotating || _television) {
      return;
    }
    final fullscreen = !_showFullscreen;
    final previous = _fullscreen;
    final previousSuppressed = _automaticFullscreenSuppressed;
    _interactions.cancel();
    _rotating = true;
    setState(() {
      _fullscreen = fullscreen;
      _automaticFullscreenSuppressed = !fullscreen;
    });
    try {
      if (Platform.isWindows) {
        await windowManager.setFullScreen(fullscreen);
      } else if (_mobile) {
        if (!AppDevice.isPadDevice) {
          await (_orientationController?.setPlayback(
                this,
                fullscreen: fullscreen,
                aspectRatio: _aspectRatio,
              ) ??
              SystemChrome.setPreferredOrientations(
                AppOrientationController.orientations(
                  television: _television,
                  fullscreen: fullscreen,
                  aspectRatio: _aspectRatio,
                ),
              ));
        }
      }
    } catch (_) {
      if (mounted && !_closed) {
        setState(() {
          _fullscreen = previous;
          _automaticFullscreenSuppressed = previousSuppressed;
        });
        _notice('无法切换全屏，请重试');
      }
    } finally {
      _rotating = false;
      if (mounted && !_closed) _scheduleSystemUi();
    }
  }

  void _notice(
    String message, {
    Duration duration = const Duration(milliseconds: 800),
  }) {
    if (!mounted || _closed) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.clearSnackBars();
    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: duration,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _setPreferences(PlaybackPreferences preferences) async {
    if (_closed || widget.store.profileEpoch != _profileEpoch) {
      throw StateError('当前用户已变更');
    }
    _interactions.cancel();
    final nextPreferences = preferences;
    await widget.store.setPlaybackPreferences(nextPreferences);
    if (!mounted || _closed || widget.store.profileEpoch != _profileEpoch) {
      return;
    }
    final qualityChanged = nextPreferences.quality != _requestedQuality;
    final decoderChanged =
        nextPreferences.decoderMode != _preferences.decoderMode;
    if (_player is LunaExoPlayer) {
      _player.setDecoderMode(nextPreferences.decoderMode);
    } else if (decoderChanged && Platform.isWindows) {
      final native = _player.platform;
      if (native is NativePlayer) {
        await native.setProperty(
          'hwdec',
          nextPreferences.decoderMode == PlaybackDecoderMode.hardware
              ? 'auto-copy-safe'
              : 'no',
        );
      }
    }
    _enhancement.setPreferences(nextPreferences.enhancement);
    setState(() {
      _speed = nextPreferences.speed;
      _requestedQuality = nextPreferences.quality;
      _decoderMode = nextPreferences.decoderMode;
      _autoAdvance = nextPreferences.autoAdvance;
      _danmakuEnabled = nextPreferences.danmaku;
      _danmakuStyle = nextPreferences.danmakuStyle;
      _preloadEnabled = nextPreferences.preload;
    });
    _danmaku.setEnabled(_danmakuEnabled);
    _syncDanmaku();
    if (qualityChanged) _preloader.clear();
    _syncPreload();
    _menuRevision.value++;
    await _interactions.applySpeed();
    if (qualityChanged && _plan?.offline != true) {
      await _retry(quality: nextPreferences.quality);
    } else if (decoderChanged && _plan != null) {
      DiaryService.add(
        '[Player] 解码模式改变为 ${nextPreferences.decoderMode.label}，重新挂载播放器',
      );
      await _retry();
    }
  }

  Future<void> _toggleFavorite() async {
    try {
      await widget.store.toggleFavorite(widget.detail.drama);
      if (mounted && !_closed) setState(() {});
    } catch (_) {
      _notice('追剧记录未能保存，请检查存储空间后重试');
    }
  }

  Future<void> _toggleDanmaku() async {
    if (widget.detail.drama.source != 'hongguo') return;
    try {
      await _setPreferences(_preferences.copyWith(danmaku: !_danmakuEnabled));
    } catch (_) {
      _notice('弹幕偏好未能保存，请重试');
    }
  }

  Future<void> _retryDanmakuFromControls() async {
    try {
      _danmaku.retry();
      _menuRevision.value++;
    } catch (_) {
      _notice('弹幕重试失败，请稍后再试');
    }
  }

  Future<void> _submitDownloadSelection(DownloadSelection selection) async {
    if (!widget.repository.supportsDownloads ||
        !widget.store.canDownload ||
        widget.store.profileEpoch != _profileEpoch ||
        widget.mediaId != null) {
      return;
    }
    final added = await widget.repository.enqueueDownloads(
      widget.detail,
      selection.episodes,
      quality: selection.quality,
    );
    if (!mounted || _closed) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(added == 0 ? '所选集数已在下载列表中' : '已加入 $added 集，已有任务自动跳过'),
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
        action: SnackBarAction(
          label: '查看',
          onPressed: () {
            ScaffoldMessenger.of(context).hideCurrentSnackBar();
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => DownloadsScreen(
                  repository: widget.repository,
                  store: widget.store,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _openPanel(PlayerMenuSection section) async {
    if (_panelOpen || _closed) return;
    _interactions.cancel();
    setState(() => _panelOpen = true);
    try {
      if (_mobile && section == PlayerMenuSection.quality) {
        final chosenQuality = await PlayerDialogHelper.openQualitySheet(
          context: context,
          qualities: _plan?.qualities ?? const [],
          selectedQuality: _requestedQuality,
          actualQuality: _plan?.quality ?? 0,
          isLocal: _plan?.offline == true,
        );
        if (chosenQuality != null && chosenQuality != _requestedQuality) {
          await _setPreferences(_preferences.copyWith(quality: chosenQuality));
          if (mounted) {
            _notice(
              '已切换清晰度为 ${PlayerQualitySheetView.qualityTitle(chosenQuality)}',
            );
          }
        }
      } else if (section == PlayerMenuSection.speed) {
        final chosenSpeed = await PlayerSpeedSheetView.show(
          context: context,
          currentSpeed: _preferences.speed,
          onSpeedSelected: (newSpeed) {
            unawaited(_setPreferences(_preferences.copyWith(speed: newSpeed)));
          },
        );
        if (chosenSpeed != null && chosenSpeed != _preferences.speed) {
          await _setPreferences(_preferences.copyWith(speed: chosenSpeed));
        }
      } else if (_mobile && section == PlayerMenuSection.episodes) {
        final chosenIndex = await PlayerDialogHelper.openEpisodesSheet(
          context: context,
          episodes: widget.detail.episodes,
          currentIndex: _index,
          dramaTitle: widget.detail.drama.title,
          seriesEntries: _currentSeriesEntries,
          currentDramaId: widget.detail.drama.id,
          onSeasonSelected: _switchSeason,
        );
        if (mounted &&
            !_closed &&
            chosenIndex != null &&
            chosenIndex != _index) {
          await _play(chosenIndex);
        }
      } else {
        final index = await PlayerDialogHelper.openMenuPanel(
          context: context,
          section: section,
          detail: widget.detail,
          currentIndex: _index,
          preferences: _preferences,
          plan: _plan,
          store: widget.store,
          danmaku: _danmaku,
          preloader: _preloader,
          enhancement: _enhancement,
          enhancementForUi: _enhancementForUi,
          fullscreen: _showFullscreen,
          mobile: _mobile,
          menuRevision: _menuRevision,
          onPreferences: _setPreferences,
          onDanmakuSettings: () {
            Navigator.pop(context);
            _openDanmakuSettings();
          },
        );
        if (mounted && !_closed && index != null && index != _index) {
          await _play(index);
        }
      }
    } finally {
      if (mounted && !_closed) {
        setState(() => _panelOpen = false);
        _playerFocus.requestFocus();
      }
    }
  }

  Future<void> _openDanmakuSettings() async {
    if (_panelOpen || _closed) return;
    _interactions.cancel();
    setState(() => _panelOpen = true);
    try {
      await PlayerDanmakuSheetView.show(
        context: context,
        enabled: _danmakuEnabled,
        style: _preferences.danmakuStyle,
        onEnabledChanged: (val) {
          unawaited(_setPreferences(_preferences.copyWith(danmaku: val)));
        },
        onStyleChanged: (newStyle) {
          unawaited(
            _setPreferences(_preferences.copyWith(danmakuStyle: newStyle)),
          );
        },
      );
    } finally {
      if (mounted && !_closed) {
        setState(() => _panelOpen = false);
        _playerFocus.requestFocus();
      }
    }
  }

  Future<void> _seekTo(Duration target) async {
    if (_closed || _loading || _error != null) return;
    if (_castFollower) {
      _sendCastControl({
        'action': 'seek',
        'position': target.inMilliseconds / 1000,
      });
      unawaited(_player.seek(target));
      return;
    }
    _handoffOwned = false;
    widget.handoff?.fail('接收端已调整播放位置');
    final ticket = ++_seekSequence;
    final generation = _generation;
    _danmaku.beginSeek();
    _enhancement.ignorePerformance();
    var succeeded = false;
    try {
      await _player.seek(target);
      succeeded = true;
    } catch (_) {
      _notice('跳转失败，请重试');
    } finally {
      if (!_closed && ticket == _seekSequence && generation == _generation) {
        _danmaku.endSeek(succeeded ? target : _player.state.position);
      }
    }
  }

  void _seek(int seconds) {
    final desired = _player.state.position + Duration(seconds: seconds);
    final maxDuration = _player.state.duration;
    final target = desired < Duration.zero
        ? Duration.zero
        : maxDuration > Duration.zero && desired > maxDuration
        ? maxDuration
        : desired;
    unawaited(_seekTo(target));
  }

  Future<void> _televisionEpisodes(BuildContext context) async {
    if (_panelOpen || _closed) return;
    setState(() => _panelOpen = true);
    int? index;
    try {
      index = await PlayerDialogHelper.openTelevisionEpisodes(
        context: context,
        episodes: widget.detail.episodes,
        currentIndex: _index,
      );
    } finally {
      if (mounted && !_closed) setState(() => _panelOpen = false);
    }
    if (index != null && mounted && !_closed && index != _index) {
      await _play(index);
    }
  }

  Future<PlaybackTechnicalDiagnostics?> _getDiagnostics() async {
    final player = _player;
    if (player is LunaExoPlayer) {
      return player.getDiagnostics(
        requestedQuality: _requestedQuality,
        actualQuality: _plan?.quality ?? 0,
        availableQualities: _plan?.qualities ?? const [],
        mediaHost: Uri.tryParse(_plan?.url ?? '')?.host,
      );
    }
    final state = _player.state;
    final w = state.videoParams.w;
    final h = state.videoParams.h;
    const codec = 'hevc';
    return PlaybackTechnicalDiagnostics(
      playerEngine: 'MediaKit (NativePlayer)',
      decoderName: codec,
      isHardwareAccelerated: _decoderMode == PlaybackDecoderMode.hardware,
      videoWidth: w,
      videoHeight: h,
      bufferDuration: state.buffer,
      bufferingEventsCount: 0,
      requestedQuality: _requestedQuality,
      actualQuality: _plan?.quality ?? 0,
      availableQualities: _plan?.qualities ?? const [],
      isEncrypted: _plan?.decryptionKey.isNotEmpty == true,
      mediaHost: Uri.tryParse(_plan?.url ?? '')?.host,
      timestamp: DateTime.now(),
    );
  }

  Future<void> _televisionSettings(BuildContext context) async {
    if (_panelOpen || _closed) return;
    setState(() => _panelOpen = true);
    TelevisionPlaybackSetting? selection;
    try {
      selection = await PlayerDialogHelper.openTelevisionSettings(
        context: context,
        speed: _speed,
        quality: _requestedQuality,
        qualities: _plan?.qualities ?? [],
        actualQuality: _plan?.quality ?? 0,
        favorite: widget.store.isFavorite(widget.detail.drama.id),
        onFavorite: _toggleFavorite,
        autoAdvance: _autoAdvance,
        danmaku: _danmakuEnabled,
        showDanmaku: widget.detail.drama.source == 'hongguo',
        danmakuStatus: _danmaku.status,
        onRetryDanmaku: _danmaku.canRetry ? _danmaku.retry : null,
        preload: _preloadEnabled,
        preloadStatus: _preloader.status,
        enhancement: _enhancement,
        enhancementForUi: _enhancementForUi,
        danmakuController: _danmaku,
        preloader: _preloader,
        decoderMode: _preferences.decoderMode,
      );
    } finally {
      if (mounted && !_closed) setState(() => _panelOpen = false);
    }
    if (selection == null || !mounted || _closed) return;
    try {
      await _setPreferences(
        _preferences.copyWith(
          speed: selection.speed,
          quality: selection.quality,
          autoAdvance: selection.autoAdvance ?? _autoAdvance,
          danmaku: selection.danmaku,
          preload: selection.preload ?? _preloadEnabled,
          enhancement: selection.enhancement,
          decoderMode: selection.decoderMode,
        ),
      );
    } catch (_) {
      _notice('播放偏好未能保存，请重试');
    }
  }

  void _back() {
    if (_showFullscreen && !_television) {
      _rotate();
    } else if (_television) {
      Navigator.of(context).pop();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  @override
  void dispose() {
    final retainStream =
        Platform.isIOS &&
        _pictureInPictureVisible &&
        _plan != null &&
        _encryptedPlayback.isStreamPlan(_plan!);
    if (retainStream) {
      PipManager.instance.retainPlaybackResource(_encryptedPlayback.close);
    }
    _closed = true;
    _keepAliveTimer?.cancel();
    unawaited(_keepAlive.dispose());
    unawaited(_dropStandby(keepPlayer: true));
    _syncNativePictureInPictureConfig(force: true);
    unawaited(_player.pause().catchError((Object _) {}));
    final enhancementClosed = _enhancement.close();
    _routeSub?.cancel();
    _remoteSub?.cancel();
    _nowPlayingTimer?.cancel();
    _castWatch?.cancel();
    if (!widget.feed && defaultTargetPlatform == TargetPlatform.iOS) {
      unawaited(
        AppDevice.channel
            .invokeMethod<void>('nowPlayingClear')
            .catchError((Object _) {}),
      );
    }
    LanController.current?.detachPlayback(_lanIdentity);
    final castLink = LanController.current;
    if (castLink != null) {
      if (castLink.casting) unawaited(castLink.stopCast());
      if (_castFollower) castLink.setCastReceiver(null);
    }
    widget.handoff?.fail('接收端已退出播放');
    widget.store.removeListener(_accessChanged);
    _danmaku.dispose();
    _preloader.dispose();
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    _saveTimer?.cancel();
    _healthTimer?.cancel();
    _errorTimer?.cancel();
    _pictureInPictureExitTimer?.cancel();
    _diagnosticsTimer?.cancel();
    if (_pictureInPictureHandlerInstalled) {
      PipManager.instance.notifyPlayerDisposed();
    }
    _interactions.dispose();
    _playerFocus.dispose();
    _menuRevision.dispose();
    unawaited(_saveProgress(flush: true));
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    unawaited(widget.repository.release(_session));
    unawaited(_loader.close().catchError((Object _) {}));
    if (!retainStream) {
      unawaited(_encryptedPlayback.cancel().catchError((Object _) {}));
    }
    final closing = _operations.catchError((Object _) {}).then((_) async {
      await _interactions.pendingRates.catchError((Object _) {});
      await enhancementClosed.catchError((Object _) {});
      await _player.dispose();
      if (!retainStream) await _encryptedPlayback.close();
    });
    unawaited(
      (_playbackLease?.releaseAfter(closing) ?? closing).catchError(
        (Object _) {},
      ),
    );
    if (_miniOwner == this) _miniOwner = null;
    if (_deskMini && _miniHandedOver) {
      _deskMini = false;
    } else if (_deskMini && (_castFollower || widget.handoff != null)) {
      _deskMini = false;
      _carryMini = true;
      final carried = _deskMiniRestore;
      _carryMiniRestore = carried;
      _carryMiniTimer?.cancel();
      // 3 秒内没有新的投屏页面接手，就把窗口还原，避免留下一个小窗口里的首页
      _carryMiniTimer = Timer(const Duration(seconds: 3), () {
        if (!_carryMini) return;
        _carryMini = false;
        _carryMiniRestore = null;
        unawaited(_restoreWindowFrom(carried));
      });
    } else if (_deskMini) {
      _deskMini = false;
      unawaited(
        windowManager.setAspectRatio(0).then((_) {
          windowManager.setAlwaysOnTop(false);
          windowManager.setTitleBarStyle(TitleBarStyle.normal);
          final b = _deskMiniRestore;
          if (b != null) windowManager.setBounds(b);
        }).catchError((Object _) {}),
      );
    }
    if (!widget.feed && Platform.isWindows) {
      unawaited(windowManager.setFullScreen(false));
    } else if (!widget.feed && (_mobile || _television && Platform.isAndroid)) {
      unawaited(
        (_orientationController?.releasePlayback(this) ??
                SystemChrome.setPreferredOrientations(
                  AppOrientationController.orientations(
                    television: _television,
                  ),
                ))
            .catchError((Object _) {}),
      );
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final inherited = Theme.of(context);
    final theme = _television ? televisionTheme(inherited) : inherited;
    return Theme(
      data: theme,
      child: Builder(
        builder: (context) {
          final fullscreen = _showFullscreen;
          final overlayBrightness = (fullscreen || _mobile)
              ? Brightness.dark
              : Theme.of(context).brightness;
          return AnnotatedRegion<SystemUiOverlayStyle>(
            value: AppTheme.systemBars(overlayBrightness),
            child: _buildPlayer(context),
          );
        },
      ),
    );
  }

  Widget _buildPlayer(BuildContext context) {
    if (widget.feed) return _videoPane(context);
    final theme = Theme.of(context);
    final title = widget.detail.drama.title;
    final fullscreen = _showFullscreen;
    final pictureInPicture = _pictureInPictureVisible || _deskMini;
    return PopScope(
      canPop: !_television && (pictureInPicture || !fullscreen),
      onPopInvokedWithResult: (didPop, result) {
        if (didPop && widget.store.usesAccountLibrary(widget.detail.drama.id)) {
          unawaited(_saveProgress(flush: true));
        }
        if (!didPop && fullscreen && !_television && !pictureInPicture) {
          _rotate();
        } else if (!didPop && pictureInPicture) {
          _back();
        }
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _back,
          const SingleActivator(LogicalKeyboardKey.goBack): _back,
        },
        child: Focus(
          focusNode: _playerFocus,
          onKeyEvent: (_, event) {
            if (_television ||
                _panelOpen ||
                !_playerFocus.hasPrimaryFocus ||
                !(ModalRoute.of(context)?.isCurrent ?? true)) {
              return KeyEventResult.ignored;
            }
            return _interactions.key(event);
          },
          autofocus: !_television,
          canRequestFocus: !_television,
          skipTraversal: _television,
          child: Scaffold(
            backgroundColor:
                fullscreen || pictureInPicture || _mobile
                ? AppColors.black
                : theme.scaffoldBackgroundColor,
            appBar: pictureInPicture || fullscreen || _mobile
                ? null
                : AppBar(
                    title: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    actions: [
                      IconButton(
                        tooltip: '旋转与全屏',
                        onPressed: _rotate,
                        icon: const Icon(Icons.screen_rotation_alt_rounded),
                      ),
                    ],
                  ),
            body: _deskMini
                ? _deskMiniView(context)
                : pictureInPicture
                ? _videoPane(context)
                : SafeArea(
                    top: false,
                    bottom: !fullscreen && !_mobile,
                    left: !fullscreen,
                    right: !fullscreen,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final desktop = constraints.maxWidth >= 840;
                        if (fullscreen) {
                          return _videoPane(context);
                        }
                        if (desktop ||
                            constraints.maxWidth >
                                constraints.maxHeight * 1.3) {
                          return Row(
                            children: [
                              Expanded(
                                child: Column(
                                  children: [
                                    Expanded(child: _videoPane(context)),
                                  ],
                                ),
                              ),
                              SizedBox(
                                width: desktop ? 340 : 220,
                                child: PlayerDesktopPanelView(
                                  episodes: widget.detail.episodes,
                                  currentIndex: _index,
                                  seriesEntries: _currentSeriesEntries,
                                  currentDramaId: widget.detail.drama.id,
                                  onSeasonSelected: _switchSeason,
                                  onSelectEpisode: (index) => _play(index),
                                ),
                              ),
                            ],
                          );
                        }
                        if (_mobile) {
                          return _immersiveLayout(context, constraints);
                        }
                        if (_mobile) {
                          final topPadding = fullscreen
                              ? 0.0
                              : MediaQuery.paddingOf(context).top;
                          final height = (constraints.maxWidth / _aspectRatio)
                              .clamp(0.0, constraints.maxHeight * .56);
                          return Column(
                            children: [
                              SizedBox(
                                height: height + topPadding,
                                width: double.infinity,
                                child: _videoPane(
                                  context,
                                  topPadding: topPadding,
                                ),
                              ),
                              Expanded(
                                child: PlayerMobilePanelView(
                                  detail: widget.detail,
                                  currentIndex: _index,
                                  store: widget.store,
                                  repository: widget.repository,
                                  seriesEntries: _currentSeriesEntries,
                                  onSeasonSelected: _switchSeason,
                                  onSelectEpisode: (index) => _play(index),
                                ),
                              ),
                            ],
                          );
                        }
                        final height = (constraints.maxWidth / _aspectRatio)
                            .clamp(0.0, constraints.maxHeight * .64);
                        return Column(
                          children: [
                            SizedBox(
                              height: height,
                              width: double.infinity,
                              child: _videoPane(context),
                            ),
                            Expanded(
                              child: PlayerDesktopPanelView(
                                episodes: widget.detail.episodes,
                                currentIndex: _index,
                                seriesEntries: _currentSeriesEntries,
                                currentDramaId: widget.detail.drama.id,
                                onSeasonSelected: _switchSeason,
                                onSelectEpisode: (index) => _play(index),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _feedControls() => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) => StreamBuilder<bool>(
      stream: _player.stream.playing,
      builder: (context, snapshot) => StreamBuilder<Duration>(
        stream: _player.stream.position,
        builder: (context, _) => FeedPlayerOverlay(
          title: widget.detail.drama.title,
          episodeText:
              '第 ${widget.detail.episodes[_index].number} 集 · 共 ${widget.detail.episodes.length} 集',
          description: widget.detail.drama.description,
          playing: _player.state.playing,
          enabled: !_loading && _error == null,
          following: widget.store.following(widget.detail.drama.id) != null,
          danmakuEnabled: _danmakuEnabled,
          position: _player.state.position,
          duration: _player.state.duration,
          onTogglePlayback: _togglePlayback,
          onSeek: (value) => unawaited(
            _seekTo(
              Duration(
                milliseconds: (_player.state.duration.inMilliseconds * value)
                    .round(),
              ),
            ),
          ),
          onSocial: widget.store.usesAccountLibrary(widget.detail.drama.id)
              ? () => unawaited(
                  showHongguoSocialDialog(
                    context,
                    widget.detail.drama,
                    widget.detail.episodes[_index].number,
                  ),
                )
              : null,
          onFavorite: () => unawaited(
            saveUserChange(
              context,
              () => widget.store.toggleFavorite(widget.detail.drama),
            ),
          ),
          onEpisodes: () => unawaited(_openPanel(PlayerMenuSection.episodes)),
          onDetail: widget.onOpenDetail ?? () {},
          onDanmaku: () => unawaited(_toggleDanmaku()),
          onSettings: () => unawaited(_openPanel(PlayerMenuSection.settings)),
        ),
      ),
    ),
  );

  Widget _miniIcon(
    IconData icon,
    String label,
    VoidCallback? onPressed, {
    double size = 36,
    double iconSize = 22,
  }) => IconButton(
    onPressed: onPressed,
    icon: Icon(icon),
    iconSize: iconSize,
    tooltip: label,
    color: Colors.white,
    disabledColor: Colors.white38,
    style: IconButton.styleFrom(
      fixedSize: Size.square(size),
      padding: EdgeInsets.zero,
    ),
  );

  Widget _miniEdge(
    ResizeEdge edge,
    MouseCursor cursor, {
    double? left,
    double? top,
    double? right,
    double? bottom,
    double? width,
    double? height,
  }) => Positioned(
    left: left,
    top: top,
    right: right,
    bottom: bottom,
    width: width,
    height: height,
    child: MouseRegion(
      cursor: cursor,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => unawaited(windowManager.startResizing(edge)),
      ),
    ),
  );

  Widget _deskMiniView(BuildContext context) {
    final video = _video;
    final playing = _playIntent;
    final visible = _deskMiniHover || !playing || _deskMiniSeek != null;
    const t = 6.0;
    const c = 12.0;
    return Material(
      color: Colors.black,
      child: MouseRegion(
        onEnter: (_) => setState(() => _deskMiniHover = true),
        onExit: (_) => setState(() => _deskMiniHover = false),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (video != null)
              Video(
                controller: video,
                fit: BoxFit.cover,
                controls: NoVideoControls,
              ),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => unawaited(windowManager.startDragging()),
              onDoubleTap: _toggleDeskMini,
            ),
            if (_loading)
              const IgnorePointer(
                child: Center(
                  child: SizedBox.square(
                    dimension: 28,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  ),
                ),
              ),
            IgnorePointer(
              ignoring: !visible,
              child: AnimatedOpacity(
                opacity: visible ? 1 : 0,
                duration: const Duration(milliseconds: 150),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    const IgnorePointer(
                      child: ColoredBox(color: Color(0x59000000)),
                    ),
                    Positioned(
                      top: 4,
                      right: 4,
                      child: Row(
                        children: [
                          _miniIcon(
                            Icons.open_in_full_rounded,
                            '还原',
                            _toggleDeskMini,
                          ),
                          _miniIcon(Icons.close_rounded, '关闭', () {
                            unawaited(_restoreDeskMini());
                            _back();
                          }),
                        ],
                      ),
                    ),
                    Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _miniIcon(
                            Icons.skip_previous_rounded,
                            '上一集',
                            _index > 0 ? () => _stepEpisode(_index - 1) : null,
                          ),
                          _miniIcon(
                            playing
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            playing ? '暂停' : '播放',
                            _togglePlayback,
                            size: 48,
                            iconSize: 32,
                          ),
                          _miniIcon(
                            Icons.skip_next_rounded,
                            '下一集',
                            _index + 1 < widget.detail.episodes.length
                                ? () => _stepEpisode(_index + 1)
                                : null,
                          ),
                        ],
                      ),
                    ),
                    Positioned(
                      left: 4,
                      right: 4,
                      bottom: 2,
                      height: 20,
                      child: StreamBuilder<Duration>(
                        stream: _player.stream.position,
                        initialData: _player.state.position,
                        builder: (context, snapshot) {
                          final duration = _player.state.duration.inMilliseconds;
                          final max = duration > 0 ? duration.toDouble() : 1.0;
                          final position = (snapshot.data ?? Duration.zero)
                              .inMilliseconds
                              .toDouble();
                          return SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 3,
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 5,
                              ),
                              overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 10,
                              ),
                            ),
                            child: Slider(
                              value: (_deskMiniSeek ?? position).clamp(0.0, max),
                              max: max,
                              onChanged: duration > 0
                                  ? (value) =>
                                        setState(() => _deskMiniSeek = value)
                                  : null,
                              onChangeEnd: (value) {
                                setState(() => _deskMiniSeek = null);
                                unawaited(
                                  _seekTo(Duration(milliseconds: value.round())),
                                );
                              },
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
            _miniEdge(
              ResizeEdge.top,
              SystemMouseCursors.resizeUpDown,
              left: c,
              right: c,
              top: 0,
              height: t,
            ),
            _miniEdge(
              ResizeEdge.bottom,
              SystemMouseCursors.resizeUpDown,
              left: c,
              right: c,
              bottom: 0,
              height: t,
            ),
            _miniEdge(
              ResizeEdge.left,
              SystemMouseCursors.resizeLeftRight,
              left: 0,
              top: c,
              bottom: c,
              width: t,
            ),
            _miniEdge(
              ResizeEdge.right,
              SystemMouseCursors.resizeLeftRight,
              right: 0,
              top: c,
              bottom: c,
              width: t,
            ),
            _miniEdge(
              ResizeEdge.topLeft,
              SystemMouseCursors.resizeUpLeftDownRight,
              left: 0,
              top: 0,
              width: c,
              height: c,
            ),
            _miniEdge(
              ResizeEdge.bottomRight,
              SystemMouseCursors.resizeUpLeftDownRight,
              right: 0,
              bottom: 0,
              width: c,
              height: c,
            ),
            _miniEdge(
              ResizeEdge.topRight,
              SystemMouseCursors.resizeUpRightDownLeft,
              right: 0,
              top: 0,
              width: c,
              height: c,
            ),
            _miniEdge(
              ResizeEdge.bottomLeft,
              SystemMouseCursors.resizeUpRightDownLeft,
              left: 0,
              bottom: 0,
              width: c,
              height: c,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showSynopsis() async {
    if (_panelOpen || _closed) return;
    final drama = widget.detail.drama;
    final text = drama.description.trim().isEmpty ? '暂无简介' : drama.description;
    setState(() => _panelOpen = true);
    try {
      await showModalBottomSheet<void>(
        context: context,
        backgroundColor: const Color(0xFF20262B),
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        builder: (context) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  drama.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: SingleChildScrollView(
                    child: Text(
                      text,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 14.5,
                        height: 1.6,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _panelOpen = false);
    }
  }

  Widget _immersivePill({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) => Material(
    color: Colors.white.withValues(alpha: .10),
    borderRadius: BorderRadius.circular(10),
    child: InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white70, size: 20),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(color: Colors.white70, fontSize: 15),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _immersiveTopBar(int number) => SizedBox(
    height: 52,
    child: Row(
      children: [
        IconButton(
          tooltip: '返回',
          onPressed: _back,
          icon: const Icon(
            Icons.chevron_left_rounded,
            color: Colors.white,
            size: 32,
          ),
        ),
        Expanded(
          child: _immersiveClean
              ? const SizedBox.shrink()
              : Text(
                  '第$number集',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 19,
                    fontWeight: FontWeight.w600,
                  ),
                ),
        ),
        if (!_immersiveClean)
        InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => unawaited(_openPanel(PlayerMenuSection.speed)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.speed_rounded, color: Colors.white, size: 22),
                const SizedBox(width: 4),
                Text(
                  '${_speed}x',
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                ),
              ],
            ),
          ),
        ),
        IconButton(
          tooltip: '更多',
          onPressed: () => unawaited(_showImmersiveMenu()),
          icon: const Icon(Icons.more_vert_rounded, color: Colors.white),
        ),
      ],
    ),
  );

  Widget _immersiveInfo(int number) {
    final drama = widget.detail.drama;
    final synopsis = drama.description.trim();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: _showSynopsis,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    drama.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, color: Colors.white70),
              ],
            ),
          ),
          const SizedBox(height: 6),
          GestureDetector(
            onTap: _showSynopsis,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    synopsis.isEmpty ? '第$number集' : '第$number集 | $synopsis',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  '展开',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _immersiveProgress() => SizedBox(
    height: 24,
    child: StreamBuilder<Duration>(
      stream: _player.stream.position,
      initialData: _player.state.position,
      builder: (context, snapshot) {
        final duration = _player.state.duration.inMilliseconds;
        final max = duration > 0 ? duration.toDouble() : 1.0;
        final position = (snapshot.data ?? Duration.zero).inMilliseconds
            .toDouble();
        return SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: _immersiveSeek != null ? 3 : 1,
            activeTrackColor: Colors.white.withValues(
              alpha: _immersiveSeek != null ? .95 : .22,
            ),
            inactiveTrackColor: Colors.white.withValues(
              alpha: _immersiveSeek != null ? .3 : .05,
            ),
            thumbColor: Colors.white,
            thumbShape: _immersiveSeek != null
                ? const RoundSliderThumbShape(enabledThumbRadius: 5)
                : SliderComponentShape.noThumb,
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
          ),
          child: Slider(
            value: (_immersiveSeek ?? position).clamp(0.0, max),
            max: max,
            onChanged: duration > 0
                ? (value) => setState(() => _immersiveSeek = value)
                : null,
            onChangeEnd: (value) {
              setState(() => _immersiveSeek = null);
              unawaited(_seekTo(Duration(milliseconds: value.round())));
            },
          ),
        );
      },
    ),
  );

  Widget _immersiveBottomBar(MediaQueryData media) => Padding(
    padding: EdgeInsets.fromLTRB(
      16,
      4,
      16,
      media.padding.bottom > 8 ? media.padding.bottom : 8.0,
    ),
    child: Row(
      children: [
        Expanded(
          child: Material(
            color: Colors.white.withValues(alpha: .10),
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => unawaited(_openPanel(PlayerMenuSection.episodes)),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 9,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '选集 · 全${widget.detail.episodes.length}集',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14.5,
                        ),
                      ),
                    ),
                    const Icon(
                      Icons.keyboard_arrow_up_rounded,
                      color: Colors.white70,
                      size: 20,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        IconButton(
          tooltip: _immersiveClean ? '显示信息' : '清屏',
          onPressed: () => setState(() => _immersiveClean = !_immersiveClean),
          icon: Icon(
            _immersiveClean
                ? Icons.fullscreen_exit_rounded
                : Icons.fullscreen_rounded,
            color: Colors.white,
            size: 26,
          ),
        ),
      ],
    ),
  );

  /// 手机竖屏的沉浸式布局。
  /// - 横屏视频：深色背景、视频居中，下方是「全屏观看」、标题简介、进度条。
  /// - 竖屏视频：视频铺满屏幕，顶部栏与标题简介、进度条叠在画面上。
  /// 选集收在底部一条按钮里，点开向上弹出。
  Widget _immersiveLayout(BuildContext context, BoxConstraints constraints) {
    final media = MediaQuery.of(context);
    final number = widget.detail.episodes[_index].number;
    if (_aspectRatio < 1) {
      return ColoredBox(
        color: const Color(0xFF14181B),
        child: Column(
          children: [
            Expanded(
              child: ClipRect(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    const ColoredBox(color: Colors.black),
                    _videoPane(context, immersive: true),
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 0,
                      child: DecoratedBox(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Color(0x99000000), Color(0x00000000)],
                          ),
                        ),
                        child: Padding(
                          padding: EdgeInsets.only(top: media.padding.top),
                          child: _immersiveTopBar(number),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: _immersiveClean
                              ? null
                              : const LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Color(0x00000000),
                                    Color(0xB3000000),
                                  ],
                                ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (!_immersiveClean) ...[
                              const SizedBox(height: 28),
                              _immersiveInfo(number),
                              const SizedBox(height: 4),
                            ],
                            _immersiveProgress(),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            _immersiveBottomBar(media),
          ],
        ),
      );
    }
    final videoHeight = (constraints.maxWidth / _aspectRatio).clamp(
      0.0,
      constraints.maxHeight * .5,
    );
    return ColoredBox(
      color: const Color(0xFF14181B),
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.only(top: media.padding.top),
            child: _immersiveTopBar(number),
          ),
          Expanded(
            child: Align(
              alignment: const Alignment(0, -0.25),
              child: SizedBox(
                height: videoHeight,
                width: double.infinity,
                child: _videoPane(context, immersive: true),
              ),
            ),
          ),
          // 清屏时只隐藏、不移除，保持占位，避免视频位置跳动
          Visibility(
            visible: !_immersiveClean,
            maintainSize: true,
            maintainAnimation: true,
            maintainState: true,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Center(
                  child: _immersivePill(
                    icon: Icons.screen_rotation_alt_rounded,
                    label: '全屏观看',
                    onTap: _rotate,
                  ),
                ),
                const SizedBox(height: 14),
                _immersiveInfo(number),
                const SizedBox(height: 8),
              ],
            ),
          ),
          _immersiveProgress(),
          _immersiveBottomBar(media),
        ],
      ),
    );
  }

  Widget _immersiveTapLayer() {
    final showPlay = !_playIntent && !_loading && _error == null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _togglePlayback,
      child: AnimatedOpacity(
        opacity: showPlay ? 1 : 0,
        duration: const Duration(milliseconds: 150),
        child: Center(
          child: Container(
            width: 68,
            height: 68,
            decoration: const BoxDecoration(
              color: Color(0x66000000),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.play_arrow_rounded,
              color: Colors.white,
              size: 46,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showImmersiveMenu() async {
    if (_panelOpen || _closed) return;
    final hongguo = widget.detail.drama.source == 'hongguo';
    final items = <({IconData icon, String label, VoidCallback run})>[
      (
        icon: Icons.high_quality_rounded,
        label: '清晰度',
        run: () => unawaited(_openPanel(PlayerMenuSection.quality)),
      ),
      if (hongguo)
        (
          icon: Icons.subtitles_rounded,
          label: _danmakuEnabled ? '关闭弹幕' : '开启弹幕',
          run: () => unawaited(Future<void>.sync(_toggleDanmaku)),
        ),
      if (_canUsePictureInPicture)
        (
          icon: Icons.picture_in_picture_alt_rounded,
          label: '小窗播放',
          run: () => unawaited(_enterPictureInPicture()),
        ),
      if (LanController.current != null && widget.mediaId == null)
        (
          icon: Icons.cast_connected_rounded,
          label: '推送 / 分屏播放',
          run: () => unawaited(_pushToDevice()),
        ),
      (
        icon: Icons.tune_rounded,
        label: '更多设置',
        run: () => unawaited(_openPanel(PlayerMenuSection.settings)),
      ),
    ];
    setState(() => _panelOpen = true);
    VoidCallback? chosen;
    try {
      chosen = await showModalBottomSheet<VoidCallback>(
        context: context,
        backgroundColor: const Color(0xFF20262B),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              for (final item in items)
                ListTile(
                  minTileHeight: 52,
                  leading: Icon(item.icon, color: Colors.white70),
                  title: Text(
                    item.label,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                  ),
                  onTap: () => Navigator.pop(context, item.run),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _panelOpen = false);
    }
    chosen?.call();
  }

  Widget _videoPane(
    BuildContext context, {
    double topPadding = 0.0,
    bool immersive = false,
  }) {
    return PlayerViewportView(
      topPadding: topPadding,
      television: _television,
      fullscreen: _showFullscreen,
      pictureInPictureVisible: _pictureInPictureVisible,
      mobile: _mobile,
      detail: widget.detail,
      index: _index,
      plan: _plan,
      loading: _loading,
      loadingMessage: _loadingMessage,
      error: _error,
      localFailure: _localFailure,
      saveWarning: _saveWarning,
      player: _player,
      playbackRequested: _playIntent,
      videoController: _video,
      danmaku: _danmaku,
      danmakuEnabled: _danmakuEnabled,
      danmakuStyle: _preferences.danmakuStyle,
      aspectRatio: _aspectRatio,
      interactions: _interactions,
      enhancement: _enhancement,
      enhancementForUi: _enhancementForUi,
      speed: _speed,
      qualityLabel: _qualityLabel,
      showControlsOnPlaybackReady: _showControlsOnPlaybackReady,
      panelOpen: _panelOpen,
      canUsePictureInPicture: _canUsePictureInPicture || _deskMiniAvailable,
      pictureInPictureRequested: _pictureInPictureRequested,
      playerFocus: _playerFocus,
      videoPaneKey: _videoPaneKey,
      allowOnlineFallback: widget.allowOnlineFallback,
      localOnly: widget.localOnly,
      isMediaIdNull: widget.mediaId == null,
      repository: widget.repository,
      store: widget.store,
      videoBuilder: widget.videoBuilder,
      fit: immersive && _aspectRatio < 1 ? BoxFit.cover : BoxFit.contain,
      controlsOverlay: widget.feed
          ? _feedControls()
          : (immersive ? _immersiveTapLayer() : null),
      onTogglePlayback: _togglePlayback,
      onSeek: _seek,
      onSeekTo: _seekTo,
      onPlay: _play,
      onRotate: _rotate,
      onBack: _back,
      onRetry: _retry,
      onSwitchOnline: _switchOnline,
      onSaveProgress: _saveProgress,
      onOpenPanel: _openPanel,
      onToggleDanmaku: _toggleDanmaku,
      onDanmakuSettings: _openDanmakuSettings,
      onRetryDanmaku: _retryDanmakuFromControls,
      onPushToDevice: _pushToDevice,
      audioOnlyTarget: _castAudioTarget,
      onEnterPictureInPicture:
          _deskMiniAvailable ? _toggleDeskMini : _enterPictureInPicture,
      onRestorePictureInPicture: _restoreFromPictureInPicture,
      onTelevisionEpisodes: _televisionEpisodes,
      onTelevisionSettings: _televisionSettings,
      onFetchDiagnostics: _getDiagnostics,
    );
  }
}
