import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:media_kit/media_kit.dart';

/// iOS 画中画（原生实现见 `ios/Runner/PipPlugin.swift`，移植自 PiliPlus）。
///
/// mpv 把帧渲染进 media_kit_video 私有的 `FlutterTexture`，原生侧钩住引擎的
/// 纹理注册表取帧，再喂给 `AVSampleBufferDisplayLayer`（iOS 15+）。
abstract final class IosPipService {
  static const _channel = MethodChannel('simple_live/ios_pip');

  static bool isAvailable = false;

  /// 画中画窗口是否正在（或即将）显示。
  static bool isActive = false;

  static bool _autoEnter = false;

  /// 原生侧是否需要播放状态更新。
  static bool get needsUpdate => isActive || _autoEnter;

  /// 播放状态回调，由播放控制器注册。
  static Future<void> Function(bool playing)? onSetPlaying;
  static void Function(Duration position)? onSkip;
  static void Function(bool active, bool closedInBackground)? onStateChanged;

  /// 进入画中画失败时回调（仅在前台提示，后台失败静默）。
  static void Function(String message)? onError;

  static Future<void> init() async {
    if (!Platform.isIOS) {
      return;
    }
    _channel.setMethodCallHandler(_onMethodCall);
    try {
      isAvailable = await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } catch (e) {
      if (kDebugMode) debugPrint('IosPipService init: $e');
    }
  }

  static Future<void> _onMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onStateChanged':
        final args = call.arguments as Map;
        final active = args['active'] == true;
        isActive = active;
        final error = args['error'];
        if (error != null && kDebugMode) {
          debugPrint('IosPipService: $error');
        }
        final isResumed =
            WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
        onStateChanged?.call(active, args['closed'] == true && !isResumed);
        if (error != null && isResumed) {
          onError?.call("画中画启动失败");
        }
        break;
      case 'setPlaying':
        onSetPlaying?.call(call.arguments as bool);
        break;
      case 'skip':
        final delta = Duration(milliseconds: call.arguments as int);
        onSkip?.call(delta);
        break;
    }
  }

  /// 进入画中画；[autoEnter] 为 true 时改为"退到后台自动进入"。
  static void enter(
    int textureId, {
    required int? width,
    required int? height,
    required bool autoEnter,
    required Map<String, Object> state,
  }) {
    if (!Platform.isIOS) {
      return;
    }
    if (autoEnter) _autoEnter = true;
    final arguments = <String, Object>{'textureId': textureId};
    if (width != null && width > 0) arguments['width'] = width;
    if (height != null && height > 0) arguments['height'] = height;
    arguments['autoEnter'] = autoEnter;
    arguments.addAll(state);
    _channel.invokeMethod('enter', arguments);
  }

  static void update(Map<String, Object> state) {
    if (!Platform.isIOS || !needsUpdate) {
      return;
    }
    _channel.invokeMethod('update', state);
  }

  static void disableAutoEnter() {
    if (!Platform.isIOS) {
      return;
    }
    if (_autoEnter) {
      _autoEnter = false;
      _channel.invokeMethod('disableAutoEnter');
    }
  }

  static void dispose() {
    if (!Platform.isIOS) {
      return;
    }
    _autoEnter = false;
    isActive = false;
    _channel.invokeMethod('dispose');
  }

  /// 把 media_kit 的播放状态打包成原生侧需要的字段（毫秒）。
  ///
  /// [isLive] 必须由调用方显式给出。直播流经 mpv 解析后 `duration` 未必是 0
  /// （部分 flv/hls 会给一个有限值），靠时长反推会把直播当成点播，小窗就会
  /// 出现进度条和快进/快退按钮。
  static Map<String, Object> stateOf(Player player, {bool? isLive}) {
    final state = player.state;
    return {
      'isPlaying': state.playing,
      'isBuffering': state.buffering,
      'position': state.position.inMilliseconds,
      'duration': state.duration.inMilliseconds,
      'speed': state.rate,
      'isLive': isLive ?? !(state.duration.inMilliseconds > 0),
    };
  }
}
