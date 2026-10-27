import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:simple_live_app/app/log.dart';

/// 手动进入画中画的结果（用于 toast 提示）。
enum IosPipEnterResult { entered, unsupported, notReady, failed }

/// iOS 系统画中画（PiliPlus 路线）：原生被动帧泵 + AVSampleBufferDisplayLayer，
/// 不切换渲染管线。原生实现见 ios/Runner/PipPlugin.swift。
///
/// 用法：
/// - 播放器初始化时 [init] 一次，并挂好各回调；
/// - 开播后调用 [enterAutoEnter]（幂等）武装"退后台自动进入"；
/// - 菜单"小窗播放"调用 [enterNow]；
/// - 播放状态变化时调用 [update]（[needsUpdate] 为 true 才需要）；
/// - 离开页面时 [dispose]。
class IosPipHelper {
  IosPipHelper._();

  static const _channel = MethodChannel('simple_live/pip');

  static bool isAvailable = false;

  /// 小窗已显示或即将显示。
  static bool isActive = false;

  static bool _autoEnter = false;

  /// 原生侧是否需要播放状态更新（已武装或已激活）。
  static bool get needsUpdate => isActive || _autoEnter;

  /// 小窗激活状态变化（进入/退出）。
  static void Function(bool active)? onActiveChanged;

  /// 小窗内播放/暂停按钮。
  static void Function(bool playing)? onSetPlaying;

  /// 小窗快进/快退（直播语义下原生不会展示该按钮）。
  static void Function(Duration offset)? onSkip;

  /// 后台关闭小窗（调用方决定是否暂停播放）。
  static void Function()? onClosedInBackground;

  static Future<void> init() async {
    _channel.setMethodCallHandler(_onMethodCall);
    try {
      isAvailable = await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } catch (e) {
      Log.d('IosPipHelper init: $e');
    }
  }

  static Future<void> _onMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onStateChanged':
        final args = call.arguments as Map;
        final active = args['active'] as bool? ?? false;
        isActive = active;
        onActiveChanged?.call(active);
        final isResumed =
            WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
        if (args['error'] != null && isResumed) {
          Log.d('iOS PiP 启动失败: ${args['error']}');
        }
        // 后台关闭小窗：与 Android 行为一致，交调用方暂停播放。
        if (args['closed'] == true && !isResumed) {
          onClosedInBackground?.call();
        }
      case 'setPlaying':
        onSetPlaying?.call(call.arguments as bool);
      case 'skip':
        onSkip?.call(Duration(milliseconds: call.arguments as int));
    }
  }

  /// 进入画中画；[autoEnter] 为 true 时只武装"退后台自动进入"，
  /// false 时立即进入小窗并退到桌面（原生处理）。
  static void enter(
    int textureId, {
    required int? width,
    required int? height,
    required bool autoEnter,
    required Map<String, Object> state,
  }) {
    if (autoEnter) {
      _autoEnter = true;
    }
    _channel.invokeMethod('enter', {
      'textureId': textureId,
      if (width != null) 'width': width,
      if (height != null) 'height': height,
      'autoEnter': autoEnter,
      ...state,
    });
  }

  /// 同步最新播放状态（位置/播放/缓冲/倍速）。
  static void update(Map<String, Object> state) {
    _channel.invokeMethod('update', state);
  }

  /// 解除"退后台自动进入"武装。
  static void disableAutoEnter() {
    if (_autoEnter) {
      _autoEnter = false;
      _channel.invokeMethod('disableAutoEnter');
    }
  }

  /// 页面销毁时整段释放会话。
  static void dispose() {
    _autoEnter = false;
    _channel.invokeMethod('dispose');
  }
}
