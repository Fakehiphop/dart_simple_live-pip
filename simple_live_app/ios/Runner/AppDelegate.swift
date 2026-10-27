import UIKit
import Flutter
import UserNotifications
import AVFoundation
import MediaPlayer

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var audioChannel: FlutterMethodChannel?
  private var backgroundTasks: [Int: UIBackgroundTaskIdentifier] = [:]
  private var nextBackgroundTaskId = 1
  private var pipController: NSObject?
  private var pipPluginRegistry: PipPluginRegistry?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    configureAudioSession()
    setupNowPlaying()
    registerAudioObservers()

    if let controller = window?.rootViewController as? FlutterViewController {
      let notificationChannel = FlutterMethodChannel(
        name: "simple_live/live_notifications",
        binaryMessenger: controller.binaryMessenger
      )
      notificationChannel.setMethodCallHandler { call, result in
        if call.method == "showLiveStart" {
          let args = call.arguments as? [String: Any]
          let title = args?["title"] as? String ?? "特别关注开播了"
          let body = args?["body"] as? String ?? "点击回到 Simple Live"
          self.showLiveStartNotification(title: title, body: body)
          result(nil)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }

      let audio = FlutterMethodChannel(
        name: "simple_live/ios_audio",
        binaryMessenger: controller.binaryMessenger
      )
      audio.setMethodCallHandler { call, result in
        switch call.method {
        case "beginBackgroundTask":
          let args = call.arguments as? [String: Any]
          let label = args?["label"] as? String ?? "simple_live_task"
          result(self.beginBackgroundTask(label: label))
        case "endBackgroundTask":
          let args = call.arguments as? [String: Any]
          let id = args?["id"] as? Int ?? -1
          self.endBackgroundTask(id: id)
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
      audioChannel = audio
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // MARK: - Audio session

  private func configureAudioSession() {
    let session = AVAudioSession.sharedInstance()
    do {
      // .playback is required for background audio; do not mix with other apps.
      try session.setCategory(.playback, mode: .moviePlayback, options: [])
      try session.setActive(true)
    } catch {
      NSLog("Simple Live: failed to configure audio session: \(error)")
    }
  }

  private func registerAudioObservers() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleInterruption(_:)),
      name: AVAudioSession.interruptionNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleRouteChange(_:)),
      name: AVAudioSession.routeChangeNotification,
      object: nil
    )
  }

  // iOS 拒绝无 Now Playing 资格的后台 app 提交 Metal 命令
  // (kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted)。
  // 注册遥控命令是资格判定条件之一；handler 仅占位，实际控制仍走 PiP 窗口。
  private func setupNowPlaying() {
    let center = MPNowPlayingInfoCenter.default()
    var info = center.nowPlayingInfo ?? [String: Any]()
    info[MPMediaItemPropertyTitle] = "SimpleLive"
    info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0.0
    center.nowPlayingInfo = info
    if #available(iOS 13.0, *) {
      center.playbackState = .playing
    }

    let commandCenter = MPRemoteCommandCenter.shared()
    commandCenter.playCommand.addTarget { _ in return .success }
    commandCenter.pauseCommand.addTarget { _ in return .success }
    commandCenter.togglePlayPauseCommand.addTarget { _ in return .success }
    UIApplication.shared.beginReceivingRemoteControlEvents()
  }

  @objc private func handleInterruption(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
          let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
      return
    }

    switch type {
    case .began:
      audioChannel?.invokeMethod("interruptionBegan", arguments: nil)
    case .ended:
      let optionValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
      let options = AVAudioSession.InterruptionOptions(rawValue: optionValue)
      let shouldResume = options.contains(.shouldResume)
      // AudioUnit-based playback must reactivate the session itself.
      do {
        try AVAudioSession.sharedInstance().setActive(true)
      } catch {
        NSLog("Simple Live: reactivate audio session failed: \(error)")
      }
      audioChannel?.invokeMethod(
        "interruptionEnded",
        arguments: ["shouldResume": shouldResume]
      )
    @unknown default:
      break
    }
  }

  @objc private func handleRouteChange(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
          let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
          let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
      return
    }
    // Old device unavailable, e.g. headphones unplugged.
    if reason == .oldDeviceUnavailable {
      audioChannel?.invokeMethod(
        "routeChange",
        arguments: ["shouldPause": true]
      )
    }
  }

  // MARK: - Background tasks

  private func beginBackgroundTask(label: String) -> Int {
    let id = nextBackgroundTaskId
    nextBackgroundTaskId += 1
    let taskIdentifier = UIApplication.shared.beginBackgroundTask(withName: label) {
      // Expiration handler.
      self.endBackgroundTask(id: id)
    }
    if taskIdentifier == .invalid {
      return -1
    }
    backgroundTasks[id] = taskIdentifier
    return id
  }

  private func endBackgroundTask(id: Int) {
    guard let taskIdentifier = backgroundTasks.removeValue(forKey: id) else {
      return
    }
    UIApplication.shared.endBackgroundTask(taskIdentifier)
  }

  // MARK: - Notifications

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    if #available(iOS 15.0, *) {
      // iOS 画中画：包装插件注册表截获 media-kit 的纹理帧，交给原生
      // PiP 控制器喂给 AVSampleBufferDisplayLayer。渲染后端全程恒定，
      // 不再接线软件渲染切换（PiliPlus 同构）。
      let pip = IosPictureInPictureController(messenger: engineBridge.applicationRegistrar.messenger())
      let registry = PipPluginRegistry(registry: engineBridge.pluginRegistry) {
        [weak pip] buffer, textureId in
        pip?.noteFramePush()
        pip?.onVideoFrame(buffer, textureId: textureId)
      }
      pip.copyPixelBuffer = { [weak registry] textureId in
        registry?.copyPixelBuffer(forTexture: textureId)
      }
      pipController = pip
      pipPluginRegistry = registry
      GeneratedPluginRegistrant.register(with: registry)
    } else {
      GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
      // iOS < 15 无画中画能力，Dart 侧按 unsupported 处理。
      let pipChannel = FlutterMethodChannel(
        name: "simple_live/ios_pip",
        binaryMessenger: engineBridge.applicationRegistrar.messenger()
      )
      pipChannel.setMethodCallHandler { _, result in result(false) }
    }
  }

  private func showLiveStartNotification(title: String, body: String) {
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
      guard granted else { return }
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      content.sound = .default
      let request = UNNotificationRequest(
        identifier: "simple_live_live_start_\(UUID().uuidString)",
        content: content,
        trigger: nil
      )
      center.add(request, withCompletionHandler: nil)
    }
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if #available(iOS 14.0, *) {
      completionHandler([.banner, .list, .sound])
    } else {
      completionHandler([.alert, .sound])
    }
  }

}
