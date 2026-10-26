import 'package:flutter/services.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/services/async_single_flight.dart';

/// iOS 系统画中画通道客户端。
/// （移植自 Kazumi PR #2646 的 IosPipController，通道名改为 simple_live/ios_pip）
enum IosPipEntryResult { entered, unsupported, notReady, failed }

class IosPipPlaybackState {
  const IosPipPlaybackState({
    required this.textureId,
    required this.playing,
    required this.position,
    required this.duration,
    required this.rate,
    required this.sourceRect,
  });

  final int? textureId;
  final bool playing;
  final Duration position;
  final Duration duration;
  final double rate;
  // UIKit 使用逻辑坐标（points），而不是 Android 的物理像素。
  final Rect? sourceRect;

  Map<String, Object> toArguments() => {
        if (textureId != null) 'textureId': textureId!,
        'playing': playing,
        'positionMillis': position.inMilliseconds,
        'durationMillis': duration.inMilliseconds,
        'rate': rate,
        if (sourceRect != null)
          'sourceRect': {
            'left': sourceRect!.left,
            'top': sourceRect!.top,
            'width': sourceRect!.width,
            'height': sourceRect!.height,
          },
      };
}

/// 持有一个播放器页面的原生画中画会话。
/// 页面保留原有的 media-kit 播放器；原生代码只负责显示其帧并转发控制。
class IosPipController {
  static Future<bool> isSupported({
    MethodChannel channel = const MethodChannel('simple_live/ios_pip'),
  }) async {
    try {
      return await channel.invokeMethod<bool>('isSupported') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  IosPipController({
    required this.playbackState,
    required this.playerHandle,
    required this.suspendVideo,
    required this.resumeVideo,
    required this.onPlay,
    required this.onPause,
    required this.onSeek,
    required this.onModeChanged,
    required this.canRestore,
    MethodChannel channel = const MethodChannel('simple_live/ios_pip'),
  }) : _channel = channel {
    _bridge = _IosPipChannelBridge.attach(this, channel);
  }

  final IosPipPlaybackState Function() playbackState;
  final Future<int?> Function() playerHandle;
  final Future<bool> Function(int handle) suspendVideo;
  final Future<bool> Function(int handle, {required bool waitForTexture})
      resumeVideo;
  final Future<void> Function() onPlay;
  final Future<void> Function() onPause;
  final Future<void> Function(Duration position) onSeek;
  final void Function(bool active, bool restored) onModeChanged;
  final bool Function() canRestore;
  final MethodChannel _channel;
  late final _IosPipChannelBridge _bridge;
  final AsyncSingleFlight<IosPipEntryResult> _entry = AsyncSingleFlight();
  final AsyncSingleFlight<bool> _armFlight = AsyncSingleFlight<bool>();
  Future<void>? _disposeFuture;
  bool _active = false;
  bool _disposed = false;

  bool get _ownsPage => !_disposed && _bridge.isCurrent(this);
  bool get isActive => _ownsPage && _active;
  bool get keepPlaybackInBackground =>
      _ownsPage && (_active || _entry.isRunning || _armFlight.isRunning);

  Future<IosPipEntryResult> enter() async {
    if (!_ownsPage) return IosPipEntryResult.failed;
    if (_active) return IosPipEntryResult.entered;
    if (_entry.isRunning) return IosPipEntryResult.notReady;
    final state = playbackState();
    if (state.textureId == null || state.sourceRect?.isEmpty != false) {
      return IosPipEntryResult.notReady;
    }
    return _entry.run(() => _enter(state));
  }

  /// 早武装：开播即建立会话并打开系统自动启动开关。
  /// canStartPictureInPictureAutomaticallyFromInline 必须在退后台前就绪，
  /// 系统才会在上滑/退桌面的瞬间替应用拉起画中画——整条武装链不能压在
  /// inactive 阶段的几百毫秒里（此前三轮失败的原因）。
  /// v3 帧管线全程温热，无重操作。幂等，返回是否就绪。
  Future<bool> ensurePrepared() async {
    if (!_ownsPage) return false;
    if (_active) return true;
    final state = playbackState();
    if (state.textureId == null || state.sourceRect?.isEmpty != false) {
      return false;
    }
    return _armFlight.run(() => _attach(state));
  }

  Future<bool> _attach(IosPipPlaybackState state) async {
    try {
      final supported = await _channel.invokeMethod<bool>('isSupported');
      if (!_ownsPage) return false;
      if (supported != true) return false;
      if (!await _bridge.acquireNative(this) || !_ownsPage) {
        return false;
      }
      final attached =
          await _channel.invokeMethod<bool>('attach', state.toArguments());
      if (!_ownsPage || attached != true) return false;
      final armed = await _channel.invokeMethod<bool>(
        'setAutoStartEnabled',
        {'enabled': true},
      );
      return armed == true;
    } on PlatformException catch (error) {
      Log.w('iOS PiP: 会话建立失败: $error');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 退后台收尾（inactive 阶段调用）。v3 全程保持 GPU 渲染管线，
  /// 无需切换软件渲染（帧管线未进小窗时也以 4fps 保温），这里只在
  /// 进入后台前同步一次最新播放状态。
  Future<bool> prepareForBackground() async {
    if (!_ownsPage) return false;
    if (_active) return true;
    if (!await ensurePrepared()) return false;
    if (!_ownsPage) return false;
    try {
      await _channel.invokeMethod<void>(
        'updatePlaybackState',
        playbackState().toArguments(),
      );
      return true;
    } on PlatformException catch (error) {
      Log.w('iOS PiP: 退后台状态同步失败: $error');
      return false;
    } on MissingPluginException {
      return true;
    }
  }

  Future<IosPipEntryResult> _enter(IosPipPlaybackState state) async {
    try {
      final supported = await _channel.invokeMethod<bool>('isSupported');
      if (!_ownsPage) return IosPipEntryResult.failed;
      if (supported != true) return IosPipEntryResult.unsupported;
      if (!await _bridge.acquireNative(this) || !_ownsPage) {
        return IosPipEntryResult.failed;
      }
      final attached =
          await _channel.invokeMethod<bool>('attach', state.toArguments());
      if (!_ownsPage) return IosPipEntryResult.failed;
      if (attached != true) return IosPipEntryResult.notReady;
      // v3：不再切换软件渲染，直接进入——管线全程温热，启动近乎即时。
      final entered = await _channel.invokeMethod<bool>('enter');
      if (!_ownsPage) return IosPipEntryResult.failed;
      _active = entered == true;
      return _active ? IosPipEntryResult.entered : IosPipEntryResult.failed;
    } on PlatformException catch (error) {
      Log.w('iOS PiP: entry failed: $error');
      return error.code == 'pip_not_ready'
          ? IosPipEntryResult.notReady
          : IosPipEntryResult.failed;
    } on MissingPluginException {
      return IosPipEntryResult.unsupported;
    }
  }

  Future<void> synchronize() async {
    if (!keepPlaybackInBackground || !_bridge.ownsNative(this)) return;
    try {
      await _channel.invokeMethod<void>(
        'updatePlaybackState',
        playbackState().toArguments(),
      );
    } on PlatformException catch (error) {
      Log.w('iOS PiP: state synchronization failed: $error');
    } on MissingPluginException {
      // 原生桥不可用时无法建立会话。
    }
  }

  Future<Object?> _handleMethodCall(MethodCall call) async {
    final args = call.arguments is Map ? call.arguments as Map : const {};
    switch (call.method) {
      case 'onVideoOutputWillChange':
        final handle = args['handle'];
        return handle is int ? await suspendVideo(handle) : false;
      case 'onVideoOutputDidChange':
        final handle = args['handle'];
        return handle is int
            ? await resumeVideo(
                handle,
                waitForTexture: args['waitForTexture'] != false,
              )
            : false;
      case 'onModeChanged':
        if (!_ownsPage) return null;
        if (args['isInPipMode'] == true && !keepPlaybackInBackground) {
          return null;
        }
        _active = args['isInPipMode'] == true;
        onModeChanged(_active, args['restored'] == true);
      case 'onRestore':
        return _ownsPage && canRestore();
      case 'onAction':
        if (!keepPlaybackInBackground) return null;
        switch (args['action']) {
          case 'play':
            await onPlay();
          case 'pause':
            await onPause();
          case 'seek':
            final position = args['positionMillis'];
            if (position is num && position.isFinite) {
              final duration = playbackState().duration.inMilliseconds;
              final target = position.toInt();
              await onSeek(
                Duration(
                  milliseconds: duration > 0
                      ? target.clamp(0, duration)
                      : target < 0
                          ? 0
                          : target,
                ),
              );
            }
        }
        await synchronize();
    }
    return null;
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    _active = false;
    try {
      if (_bridge.shouldDisposeNative(this)) {
        // 原生侧只在进行中的输出变更排空后才确认。
        // 它们的 Will/Did 回调仍需到达本页面捕获的播放器。
        await _channel.invokeMethod<void>('dispose');
      }
    } on PlatformException catch (error) {
      Log.w('iOS PiP: disposal failed: $error');
    } on MissingPluginException {
      // 没有 sample-buffer 画中画能力的 iOS 版本不存在活动的原生会话。
    } finally {
      _bridge.detach(this);
    }
  }
}

/// MethodChannel 的处理器按通道名共享，即使跨 MethodChannel 实例也一样。
/// 在旧页面排空、新页面接入时保持稳定。
class _IosPipChannelBridge {
  _IosPipChannelBridge(this.channel);

  static final _bridges = <(BinaryMessenger, String), _IosPipChannelBridge>{};

  static _IosPipChannelBridge attach(
    IosPipController owner,
    MethodChannel channel,
  ) {
    final key = (channel.binaryMessenger, channel.name);
    final bridge = _bridges.putIfAbsent(key, () {
      final value = _IosPipChannelBridge(channel);
      channel.setMethodCallHandler(value.handleMethodCall);
      return value;
    });
    bridge._owners.add(owner);
    return bridge;
  }

  final MethodChannel channel;
  final List<IosPipController> _owners = [];
  IosPipController? _nativeOwner;

  IosPipController? get _current => _owners.isEmpty ? null : _owners.last;
  bool isCurrent(IosPipController owner) => identical(_current, owner);
  bool ownsNative(IosPipController owner) => identical(_nativeOwner, owner);

  Future<bool> acquireNative(IosPipController owner) async {
    final previous = _nativeOwner;
    if (previous != null && !identical(previous, owner)) {
      await previous.dispose();
    }
    if (!owner._ownsPage) return false;
    _nativeOwner = owner;
    return true;
  }

  bool shouldDisposeNative(IosPipController owner) =>
      identical(_nativeOwner, owner) ||
      (_nativeOwner == null && isCurrent(owner));

  Future<Object?> handleMethodCall(MethodCall call) async {
    final outputChange =
        call.method == 'onVideoOutputWillChange' ||
        call.method == 'onVideoOutputDidChange';
    final owner = outputChange ? (_nativeOwner ?? _current) : _current;
    if (owner == null) return false;
    // 排空中的原生会话发出的播放命令不能到达正在等待获取会话的新页面。
    if (!outputChange &&
        (_nativeOwner != null && !identical(_nativeOwner, owner))) {
      return false;
    }
    return owner._handleMethodCall(call);
  }

  void detach(IosPipController owner) {
    _owners.remove(owner);
    if (identical(_nativeOwner, owner)) _nativeOwner = null;
    if (_owners.isEmpty) {
      channel.setMethodCallHandler(null);
      _bridges.remove((channel.binaryMessenger, channel.name));
    }
  }
}
