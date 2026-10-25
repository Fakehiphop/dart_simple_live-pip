import 'dart:async';

import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:simple_live_app/app/log.dart';

/// iOS 系统画中画的 Dart 侧入口。
///
/// 对应原生 `ios/Runner/PipPlugin.swift`。播放内核是 media_kit（libmpv），
/// 视频经 `FlutterTexture` 暴露，原生侧 hook 纹理注册表取帧后喂给
/// `AVSampleBufferDisplayLayer`，再挂到
/// `AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:)`。
abstract final class IosPipService {
  static const MethodChannel _channel = MethodChannel('simple_live/ios_pip');

  static final _events = StreamController<IosPipEvent>.broadcast();
  static bool _handlerInstalled = false;

  /// 画中画事件流。
  ///
  /// 原生侧通过同一个 MethodChannel 反向调用推送事件：
  /// `onStateChanged{active, closed?, error?}` / `setPlaying` / `skip`。
  static Stream<IosPipEvent> get events {
    if (!_handlerInstalled) {
      _handlerInstalled = true;
      _channel.setMethodCallHandler((call) async {
        switch (call.method) {
          case 'onStateChanged':
            final args = (call.arguments as Map?)?.cast<String, Object?>() ?? {};
            final active = args['active'] == true;
            final closed = args['closed'] == true;
            final error = args['error'] as String?;
            if (error != null) {
              _events.add(IosPipEvent.failed);
            } else if (active) {
              _events.add(IosPipEvent.entered);
            } else if (closed) {
              _events.add(IosPipEvent.closed);
            } else {
              _events.add(IosPipEvent.exited);
            }
          case 'setPlaying':
            _events.add(
              (call.arguments as bool?) == true
                  ? IosPipEvent.resumed
                  : IosPipEvent.paused,
            );
          case 'skip':
            // 直播不可跳转，原生侧已忽略，这里只记录。
            Log.d("iOS 画中画忽略跳转请求: ${call.arguments}");
          default:
            Log.d("iOS 画中画未知事件: ${call.method}");
        }
      });
    }
    return _events.stream;
  }

  /// 当前设备是否支持系统画中画（iOS 15+）。
  static Future<bool> get isSupported async {
    try {
      return await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } catch (e) {
      Log.d("iOS 画中画能力探测失败: $e");
      return false;
    }
  }

  /// 进入画中画。
  ///
  /// [textureId] 是 media_kit 渲染视频所用的 Flutter 纹理 id，原生侧据此
  /// 取帧。[width] / [height] 为视频的显示宽高比来源。[autoEnter] 为 true
  /// 时表示退后台自动进入，由系统在 App 切入后台时触发。
  static Future<bool> enter({
    required int textureId,
    required double width,
    required double height,
    required Map<String, Object> state,
    bool autoEnter = false,
  }) async {
    try {
      await _channel.invokeMethod<void>('enter', {
        'textureId': textureId,
        'width': width,
        'height': height,
        'autoEnter': autoEnter,
        ...state,
      });
      return true;
    } catch (e) {
      Log.d("进入 iOS 画中画失败: $e");
      return false;
    }
  }

  /// 推送播放状态变化。
  static Future<void> update(Map<String, Object> state) async {
    try {
      await _channel.invokeMethod<void>('update', state);
    } catch (e) {
      Log.d("更新 iOS 画中画状态失败: $e");
    }
  }

  /// 取消退后台自动进入（保留会话）。
  static Future<void> disableAutoEnter() async {
    try {
      await _channel.invokeMethod<void>('disableAutoEnter');
    } catch (e) {
      Log.d("取消 iOS 自动画中画失败: $e");
    }
  }

  /// 结束画中画会话。
  static Future<void> dispose() async {
    try {
      await _channel.invokeMethod<void>('dispose');
    } catch (e) {
      Log.d("结束 iOS 画中画失败: $e");
    }
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

/// 画中画事件。
///
/// 原生侧只会上报四种：`onStateChanged{active:true}` → [entered]；
/// `onStateChanged{active:false, closed:false}` → [exited]（用户点恢复按钮）；
/// `onStateChanged{active:false, closed:true}` → [closed]（用户点关闭按钮）；
/// `onStateChanged{error}` → [failed]。另有 `setPlaying` / `skip` 两个
/// 播放控制回调。
enum IosPipEvent {
  /// 已进入画中画
  entered,

  /// 已退出画中画，界面回到 App 内联显示
  exited,

  /// 小窗被用户关闭
  closed,

  /// 小窗上点击了播放
  resumed,

  /// 小窗上点击了暂停
  paused,

  /// 启动或运行失败
  failed,
}
