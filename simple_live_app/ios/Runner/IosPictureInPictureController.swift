import AVKit
import Accelerate
import Flutter
import UIKit
import MediaPlayer
import CoreImage

// PiliPlus 同构实现（本轮重写）：
//   1. 只用一个自动启动机制：`canStartPictureInPictureAutomaticallyFromInline`
//      = autoEnter && hasFrame，由 SpringBoard 在用户上滑/退桌面时自己拉起。
//      应用侧永远不在后台显式 startPictureInPicture（场景态 Background 一律被
//      拒，AVKitErrorDomain -1001）；也不做 OFF→ON 标志重推这类经验性 nudge。
//   2. 渲染后端全程恒定（保持 GPU / TextureHW）：不主动切软件渲染。后台持续
//      出帧靠 Info.plist 的 UIBackgroundModes=audio + 音频在播 → 进程不被挂起
//      → media-kit 的 render 调用照常发生。PiliPlus 实证可行，且不产生切换
//      纹理导致的 1-2 秒空白。
//   3. 镜像视图插在 keyWindow 的最底层（at: 0），按窗口 bounds 居中铺满并跟随
//      PiP 报告的实际 renderSize——不再是"1px 离屏 + 退后台临时摆回"的探针。
//      入参里若带有视频区域（sourceRect），则与之对齐，便于系统判定内联可见性。
//   4. 帧节流：PiP 激活 30fps；未激活仍以 0.25s 保温（层内恒有新鲜帧，系统
//      判定"可自动启动"才成立）。
//   5. 帧投递：CPU 缩放（vImage，不跟 mpv 抢 GPU 上下文）+ kCMSampleAttachmentKey_
//      DisplayImmediately（mpv 已按自己的节奏出帧，不再叠加 controlTimebase 采样节流）。
//   6. 会话常驻（武装期 PiP 停止不拆会话）；回前台自动关闭小窗；系统侧关闭
//      才整段清理。
@available(iOS 15.0, *)
private final class PipVideoView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

@available(iOS 15.0, *)
final class IosPictureInPictureController: NSObject,
    AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    private let channel: FlutterMethodChannel
    var copyPixelBuffer: ((Int64) -> CVPixelBuffer?)?
    private var sessionGeneration = 0
    private var videoView: PipVideoView?
    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private var renderingObservation: NSKeyValueObservation?
    private var readyForDisplayObserver: NSObjectProtocol?
    private var hasEnqueuedFrame = false
    private var entryTimeout: DispatchWorkItem?
    private var entryResult: FlutterResult?
    private var startRequested = false
    private var startRetries = 0
    private var willStartAt: Double = 0
    private var suspendOnStart = false
    private var restoring = false
    private var textureId: Int64?
    private var lastSourceRect: CGRect?
    private var playing = false
    private var lastRate = 1.0
    private var duration: Double = 0
    private var timebase: CMTimebase?
    private var pixelBufferPool: CVPixelBufferPool?
    private var pixelBufferPoolSize = CGSize.zero
    private var formatDescription: CMVideoFormatDescription?
    private var renderSize: CGSize = .zero

    // 帧泵纪律（PiliPlus 双速）：进小窗/进入中 30fps；未进小窗 0.25s 保温。
    private static let activeFrameInterval: Double = 1.0 / 30.0
    private static let idleFrameInterval: Double = 0.25
    // 输出上限：小窗物理尺寸有限，超采样无意义（SwiftPeek 长边 960px）。
    private static let maxLongEdge: Int = 960
    /// 画中画激活或正在进入时为真（提高采样速率）。
    private var activeFeed = false
    /// 武装标志：设置项打开且会话就绪。
    private var autoStartArmed = false
    private var enteredBackground = false
    private var stopRequested = false
    private var lastEnqueueAt = 0.0
    private var enqueuedFrames = 0
    private var sourceFrames = 0
    private var droppedFrames = 0
    private var dropNotReady = 0
    private var dropPool = 0
    private var mainHopDelaySum = 0.0
    private var mainHopCount = 0
    private var lastStatsAt = 0.0
    // 锁屏卡片标题：主播名 + 直播间标题，Dart 推送。
    private var nowPlayingTitle = "SimpleLive"
    private var nowPlayingArtist = ""
    /// 仅在播放状态翻转时重写 Now Playing（小窗激活期间禁用每秒整包
    /// Replace：高频 Replace 是资格翻 NOT 的诱因之一，11306 实测）。
    private var lastNowPlayingPlaying = false
    private var lastNowPlayingSynced = false
    private var lastAutoEnterWritten = false
    // 锁屏封面（11310 同款）：每会话一次性生成 320×320 JPEG（CI 走
    // software renderer，后台 Metal 会被 BackgroundExecutionNotPermitted 拒），
    // 不再周期性整包 Replace。
    private var lastArtworkBuffer: Data?
    private var lastArtworkRequested = false
    // 喂帧兜底泵：小窗期间即使 mpv 推送变稀也按 30Hz 主动拉帧。
    private var feedPump: DispatchSourceTimer?
    private let feedPumpQueue = DispatchQueue(label: "SimpleLive.PiP.feedPump")

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "simple_live/ios_pip", binaryMessenger: messenger)
        super.init()
        registerLifecycleObservers()
        registerNowPlaying()
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { result(false); return }
            let args = call.arguments as? [String: Any] ?? [:]
            switch call.method {
            case "isSupported":
                result(AVPictureInPictureController.isPictureInPictureSupported())
            case "attach":
                self.attachSession(args, result: result)
            case "softwareRendering":
                // 渲染后端全程恒定：旧 Dart 二进制的兼容调用只确认不做。
                NSLog("SimpleLive PiP: softwareRendering ignored (rendering backend is fixed)")
                result(nil)
            case "updatePlaybackState":
                self.updatePlaybackState(args)
                result(nil)
            case "enter":
                self.enter(result)
            case "enterAuto":
                // PiliPlus 同构：自动路径不在这里 startPictureInPicture，
                // 只保证"已武装 + 标志为真 + 有帧"，其余交给 SpringBoard。
                self.armAutoStartIfReady(result)
            case "setAutoStartEnabled":
                self.setAutoStartEnabled(args["enabled"] as? Bool == true, result: result)
            case "updateInfo":
                self.updateNowPlayingInfo(args)
                result(nil)
            case "dispose":
                // 换直播间/离开直播页不再销毁会话：SpringBoard 只对已注册的
                // Pegasus remote object 做自动起窗，每次重建 controller 都让
                // 下一轮上滑变成"新对象赌博"。只重置帧管线状态。
                self.finishEntry(false)
                self.softReset()
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    /// Now Playing 资格注册：mediaserverd 只把后台 GPU 提交权授予它认定为
    /// "Now Playing eligible" 的应用——仅有音频会话（.playback + setActive）
    /// 不够，还要求 MPNowPlayingInfoCenter 已注册且 MPRemoteCommandCenter
    /// 至少有一条启用的命令处理器，资格在音频 I/O 启动时评估。控制器随
    /// Flutter 引擎引导创建（早于任何直播流的 I/O），在此处注册即可。
    /// 缺资格的实测表现：PiP 层在后台持续收到
    /// kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted，
    /// 小窗停在最后两帧之间来回抖动（表现为 2 帧动图）。
    private func registerNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "SimpleLive",
            MPNowPlayingInfoPropertyIsLiveStream: NSNumber(value: true),
            MPNowPlayingInfoPropertyPlaybackRate: NSNumber(value: 0.0),
        ]
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.isEnabled = true
        commands.playCommand.addTarget { [weak self] _ in
            self?.forwardRemoteAction(play: true)
            return .success
        }
        commands.pauseCommand.isEnabled = true
        commands.pauseCommand.addTarget { [weak self] _ in
            self?.forwardRemoteAction(play: false)
            return .success
        }
        commands.togglePlayPauseCommand.isEnabled = true
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.forwardRemoteAction(play: !self.playing)
            return .success
        }
        NSLog("SimpleLive PiP: now playing registered at launch")
    }

    /// 锁屏/控制中心的播放命令 → 复用 Dart 侧既有的 onAction 通路
    /// （与小窗叠加层按钮同一条协议）。
    private func forwardRemoteAction(play: Bool) {
        channel.invokeMethod("onAction", arguments: ["action": play ? "play" : "pause"])
    }

    /// 锁屏卡片标题（主播名 + 直播间标题），Dart 在武装/房间信息就绪时推送。
    private func updateNowPlayingInfo(_ args: [String: Any]) {
        if let title = args["title"] as? String, !title.isEmpty {
            nowPlayingTitle = title
        }
        if let artist = args["artist"] as? String {
            nowPlayingArtist = artist
        }
        refreshNowPlayingInfo()
    }

    /// 喂帧兜底泵：对照实验里 mpv→textureFrameAvailable 推送链在后台实测
    /// 只有 ~4fps（PiliPlus 无泵且注释称"帧距由 mpv 决定"，其小窗流畅，
    /// 说明推送速率受环境影响）。泵按 30Hz 主动拉最新纹理帧，force 绕过
    /// 采样节流；内容未更新时拷到的是重复帧，无副作用。
    private func startFeedPump() {
        guard feedPump == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: feedPumpQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30.0)
        timer.setEventHandler { [weak self] in
            guard let self = self,
                  self.activeFeed || (self.autoStartArmed && self.hasEnqueuedFrame),
                  let id = self.textureId else { return }
            let scheduledAt = CACurrentMediaTime()
            DispatchQueue.main.async {
                let hopDelay = CACurrentMediaTime() - scheduledAt
                self.mainHopDelaySum += hopDelay
                self.mainHopCount += 1
                guard self.activeFeed || (self.autoStartArmed && self.hasEnqueuedFrame),
                      let buffer = self.copyPixelBuffer?(id) else { return }
                self.onVideoFrame(buffer, textureId: id, force: true)
            }
        }
        timer.resume()
        feedPump = timer
        NSLog("SimpleLive PiP: feed pump started (30Hz)")
    }

    private func stopFeedPump() {
        guard feedPump != nil else { return }
        feedPump?.cancel()
        feedPump = nil
        NSLog("SimpleLive PiP: feed pump stopped")
    }

    /// Now Playing 速率/进度跟随：控制中心卡片据此显示"在播"状态；
    /// mediaserverd 的资格评估同样参考（rate=0 视为未播放）。
    private func refreshNowPlayingInfo() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [String: Any]()
        info[MPNowPlayingInfoPropertyPlaybackRate] = NSNumber(value: playing ? lastRate : 0.0)
        info[MPMediaItemPropertyTitle] = nowPlayingTitle
        if !nowPlayingArtist.isEmpty {
            info[MPMediaItemPropertyArtist] = nowPlayingArtist
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] =
            NSNumber(value: timebase.map { CMTimeGetSeconds(CMTimebaseGetTime($0)) } ?? 0)
        // 封面回归（11310）：11306 实测资格 NOT 的诱因是"每 3s 大图整包
        // Replace + 768×768"。频率已收敛（只在状态翻转时触发刷新），每会话
        // 只生成一次 320×320 小图，资格不再翻 NOT（待真机回归）。
        if let data = lastArtworkBuffer, let img = UIImage(data: data) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// 建立画中画会话（内容源 + delegate + 时基）。开播即调用（早武装），
    /// 帧镜像持续（前台全速、未进小窗 0.25s 保温）。
    private func attachSession(_ args: [String: Any], result: @escaping FlutterResult) {
        let prepared = prepareSource(args)
        if prepared {
            NSLog("SimpleLive PiP: attach ok, texture %@, render %.0fx%.0f",
                  (args["textureId"] as? NSNumber)?.stringValue ?? "nil",
                  renderSize.width, renderSize.height)
        } else {
            NSLog("SimpleLive PiP: attach failed %@", entryDiagnostics().description)
        }
        result(prepared)
    }

    /// 应用级生命周期观察（控制器与 Flutter 引擎同生命周期，注册一次）。
    /// PiliPlus 注记：PiP 启动/停止也会广播前台场景通知，因此回前台分支必须
    /// 以 enteredBackground 为前提，避免自动启动瞬间被自己停掉。
    private func registerLifecycleObservers() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.handleDidEnterBackground() }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.handleDidBecomeActive() }
        NotificationCenter.default.addObserver(
            forName: UIScene.didActivateNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.handleDidBecomeActive() }
    }

    private func handleDidEnterBackground() {
        guard UIApplication.shared.applicationState == .background else { return }
        enteredBackground = true
        stopRequested = false
        guard let pip = controller else { return }
        NSLog("SimpleLive PiP: didEnterBackground, autoStart=%@ possible=%@ active=%@ playing=%@ hasFrame=%@ enq=%ld",
              pip.canStartPictureInPictureAutomaticallyFromInline ? "true" : "false",
              pip.isPictureInPicturePossible ? "true" : "false",
              pip.isPictureInPictureActive ? "true" : "false",
              playing ? "true" : "false",
              hasEnqueuedFrame ? "true" : "false",
              enqueuedFrames)

        // 不再程序化补 start（predidit8，对照 PiliPlus PipPlugin）：系统
        // 自动起窗的判定窗在 willResignActive 期，app 侧任何 inactive /
        // background 显式 start 一律 -1001（真机 11+ 次全败），且抢先占住
        // 远程对象会令该轮 Pegasus 判定缺席（053347 日志 4/4：resign start
        // -1001 之后系统零查询）。起窗完全交给系统自动路径，这里只留状态
        // 日志用于归因。
    }

    private func handleDidBecomeActive() {
        // 场景激活回声守卫：PiP 启动瞬间系统会广播 UIScene.didActivate，
        // 此刻 app 仍在 .background（真机日志：成功起窗 1 秒后被此回声
        // stop 掉 = 首滑成功率低的主因）。仅当 app 真正回到前台才处理返回。
        guard UIApplication.shared.applicationState == .active else { return }
        guard enteredBackground else { return }
        enteredBackground = false
        guard let pip = controller else { return }
        // 回 app 自动关闭小窗（PiP 关闭即回归行内，小窗不残留）。
        // PiP 启动瞬间也会广播 didBecomeActive，enteredBackground 前提已排除回声。
        if pip.isPictureInPictureActive && !restoring {
            NSLog("SimpleLive PiP: became active, stopPictureInPicture issued (auto stop on return)")
            stopRequested = true
            pip.stopPictureInPicture()
        }
    }

    private func setAutoStartEnabled(_ enabled: Bool, result: @escaping FlutterResult) {
        guard let controller = controller else {
            NSLog("SimpleLive PiP: autoStart \(enabled) ignored, no session")
            result(false)
            return
        }
        autoStartArmed = enabled
        updateAutoEnterFlag()
        NSLog("SimpleLive PiP: autoStart set to %@ (hasFrame=%@)",
              enabled ? "true" : "false", hasEnqueuedFrame ? "true" : "false")
        result(true)
    }

    /// 唯一的启动开关（PiliPlus 同构）：`autoEnter && hasFrame`。
    /// 帧到齐后重算一次即可，不需要 OFF→ON 反复重推。
    private func updateAutoEnterFlag() {
        let value = autoStartArmed && hasEnqueuedFrame
        // 边沿触发写：同值重写会在退后台过渡期惊动 Pegasus（860 日志：
        // ShouldAutoPiP YES x6 后随一次 Client Update，最终 request NO）。
        // PiliPlus 每周期只有一次 true 边沿，起窗判定全程安静。
        if value != lastAutoEnterWritten {
            lastAutoEnterWritten = value
            controller?.canStartPictureInPictureAutomaticallyFromInline = value
        }
        syncFeedPump()
    }

    /// 喂帧泵在场条件统一入口：PiP 活跃，或已武装且有帧。武装窗口内保持
    /// 30Hz 拉取，让退后台判定时刻图层始终有鲜活内容——自动启动成败与
    /// 该时刻图层新鲜度强相关（真机实测：enq=24 成功 vs enq=11/4 失败）。
    private func syncFeedPump() {
        if activeFeed || (autoStartArmed && hasEnqueuedFrame && controller != nil) {
            startFeedPump()
        } else {
            stopFeedPump()
        }
    }

    /// 自动路径入口：只保证开关就绪，不调用 startPictureInPicture。
    private func armAutoStartIfReady(_ result: @escaping FlutterResult) {
        guard let pip = controller else {
            NSLog("SimpleLive PiP: enterAuto ignored, no session")
            result(false); return
        }
        guard !pip.isPictureInPictureActive else {
            result(true); return
        }
        // 兜底：无帧时催一次纹理，保证 canStart... 的 hasFrame 前提成立。
        if !hasEnqueuedFrame, let id = textureId, let buffer = copyPixelBuffer?(id) {
            onVideoFrame(buffer, textureId: id)
        }
        guard hasEnqueuedFrame else {
            NSLog("SimpleLive PiP: enterAuto ignored, no frame yet")
            result(false); return
        }
        autoStartArmed = true
        updateAutoEnterFlag()
        NSLog("SimpleLive PiP: auto-start armed (system will enter PiP on background), possible=%@",
              pip.isPictureInPicturePossible ? "true" : "false")
        result(true)
    }

    private func prepareSource(_ args: [String: Any]) -> Bool {
        // 退后台过渡期静默窗：Dart 生命周期重武装会在退后台瞬间打进
        // attach+arm+updatePlaybackState 风暴，其远端交互与 SpringBoard
        // 正在收尾的自动起窗判定互踩（860 日志：判定 YES x6 后被 NO，
        // 场景弹回前台）。过渡期一律延后，回前台后 Dart 会重新武装。
        if UIApplication.shared.applicationState != .active, !activeFeed,
           controller?.isPictureInPictureActive != true {
            NSLog("SimpleLive PiP: attach deferred (background transition)")
            return false
        }
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              let id = args["textureId"] as? NSNumber,
              let window = Self.hostWindow() else { return false }

        if controller == nil {
            lastAutoEnterWritten = false
            let view = PipVideoView()
            view.isUserInteractionEnabled = false
            view.displayLayer.videoGravity = .resizeAspect
            CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                                           sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
            view.displayLayer.controlTimebase = timebase
            videoView = view
            let content = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: view.displayLayer, playbackDelegate: self)
            let pip = AVPictureInPictureController(contentSource: content)
            pip.delegate = self
            pip.canStartPictureInPictureAutomaticallyFromInline = false
            controller = pip
            lastArtworkBuffer = nil
            lastArtworkRequested = false
            lastNowPlayingPlaying = playing
            lastNowPlayingSynced = false
            NSLog("SimpleLive PiP: session created")
        }
        // 镜像层插在 window 最底层：必须在窗口内（系统据此判定内联可见性），
        // 但位于 Flutter 内容之下，所以既不遮挡 UI 也不会顶替真实画面。
        // PiliPlus 以此取代了"1px 离屏 + 退后台临时摆回"的探针路线。
        attachVideoViewToWindow()
        textureId = id.int64Value
        updatePlaybackState(args)
        if let buffer = copyPixelBuffer?(id.int64Value) {
            onVideoFrame(buffer, textureId: id.int64Value)
        }
        return true
    }

    private func attachVideoViewToWindow() {
        guard let view = videoView, let window = Self.hostWindow() else { return }
        if view.superview !== window {
            window.insertSubview(view, at: 0)
            NSLog("SimpleLive PiP: mirror view inserted below Flutter content")
        }
        layoutVideoView()
    }

    /// 镜像层尺寸：优先跟随 PiP 报告的实际 renderSize（PiliPlus 同款），
    /// 否则退化为按视频区域/窗口居中铺满。
    private func layoutVideoView() {
        guard let view = videoView, let window = view.superview ?? Self.hostWindow() else { return }
        let bounds = window.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        var target: CGRect
        let aspectSize: CGSize = {
            if renderSize.width > 0, renderSize.height > 0 { return renderSize }
            return lastSourceRect?.size ?? .zero
        }()
        if aspectSize.width > 0, aspectSize.height > 0 {
            let scale = min(bounds.width / aspectSize.width, bounds.height / aspectSize.height)
            let width = aspectSize.width * scale
            let height = aspectSize.height * scale
            let top = window.safeAreaInsets.top
            target = CGRect(x: (bounds.width - width) / 2,
                            y: (bounds.height - height) / 2 + top / 2,
                            width: width, height: height)
            if let rect = lastSourceRect, rect.width > 0, rect.height > 0 {
                target = rect
            }
        } else {
            target = bounds
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.frame = target
        CATransaction.commit()
    }

    private func updatePlaybackState(_ args: [String: Any]) {
        if UIApplication.shared.applicationState != .active, !activeFeed,
           controller?.isPictureInPictureActive != true {
            // 同 prepareSource 静默窗：invalidatePlaybackState/timebase/
            // 镜像层布局都是过渡期禁忌，只记字段。
            if let id = args["textureId"] as? NSNumber { textureId = id.int64Value }
            playing = args["playing"] as? Bool ?? false
            NSLog("SimpleLive PiP: updatePlaybackState deferred (background transition)")
            return
        }
        let oldTextureId = textureId
        if let id = args["textureId"] as? NSNumber { textureId = id.int64Value }
        playing = args["playing"] as? Bool ?? false
        duration = max(0, (args["durationMillis"] as? NSNumber)?.doubleValue ?? 0) / 1000
        let position = max(0, (args["positionMillis"] as? NSNumber)?.doubleValue ?? 0) / 1000
        let rate = (args["rate"] as? NSNumber)?.doubleValue ?? 1
        lastRate = rate
        if let timebase = timebase {
            CMTimebaseSetRateAndAnchorTime(
                timebase,
                rate: playing ? rate : 0,
                anchorTime: CMTime(seconds: position, preferredTimescale: 1000),
                immediateSourceTime: CMClockGetTime(CMClockGetHostTimeClock()))
        }
        if let rect = args["sourceRect"] as? [String: NSNumber] {
            lastSourceRect = CGRect(x: rect["left"]?.doubleValue ?? 0,
                                    y: rect["top"]?.doubleValue ?? 0,
                                    width: rect["width"]?.doubleValue ?? 0,
                                    height: rect["height"]?.doubleValue ?? 0)
        }
        // 本控制器专用直播页面——恒定直播语义。mpv 对直播 HLS 会把缓冲长度
        // 报成时长（日志实证 ContentDuration=7.22s），系统因此在系统画中画
        // 窗口显示点播 UI（进度条 + 快进/快退 10 秒）。无限区间即三件套全消。
        controller?.requiresLinearPlayback = true
        controller?.invalidatePlaybackState()
        layoutVideoView()
        // 渲染后端恒定，纹理 ID 通常不变；万一变了（换台/换清晰度）补一帧。
        if oldTextureId != textureId, let id = textureId,
           let buffer = copyPixelBuffer?(id) {
            onVideoFrame(buffer, textureId: id)
        }
        // 激活期间仅在播放状态翻转时重写 Now Playing：锁屏进度由系统按
        // rate+elapsed 自行推算，直播语义下无进度条，无需每秒整包 Replace。
        let pipActive = activeFeed || controller?.isPictureInPictureActive == true
        if !pipActive || playing != lastNowPlayingPlaying || !lastNowPlayingSynced {
            lastNowPlayingPlaying = playing
            lastNowPlayingSynced = true
            refreshNowPlayingInfo()
        }
    }

    private func enter(_ result: @escaping FlutterResult) {
        guard let pip = controller, textureId != nil, entryResult == nil else {
            result(false); return
        }
        if pip.isPictureInPictureActive { result(true); return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            let failure = error as NSError
            NSLog("SimpleLive PiP: audio activation failed %@ (%ld)", failure.domain, failure.code)
            cleanUp()
            result(FlutterError(code: "pip_audio_session", message: "Audio session activation failed",
                                details: ["domain": failure.domain, "code": failure.code]))
            return
        }
        entryResult = result
        startRequested = false
        // 手动路径：启动调用一发出就退桌面，让小窗动画与桌面动画几乎同时
        // （启动调用本身已把小窗交给系统管理，随后退后台不影响它）。
        suspendOnStart = true
        possibleObservation = pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) {
            [weak self] _, _ in
            DispatchQueue.main.async { self?.startIfPossible() }
        }
        if let layer = videoView?.displayLayer {
            renderingObservation = layer.observe(\.status, options: [.initial, .new]) {
                [weak self] _, _ in
                DispatchQueue.main.async { self?.startIfPossible() }
            }
            if #available(iOS 17.4, *) {
                // readyForDisplay 不符合 KVO 规范；AVFoundation 通过通知广播。
                readyForDisplayObserver = NotificationCenter.default.addObserver(
                    forName: .AVSampleBufferDisplayLayerReadyForDisplayDidChange,
                    object: layer, queue: .main) { [weak self] _ in
                        self?.startIfPossible()
                    }
            }
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self, self.entryResult != nil else { return }
            let ready = self.hasDisplayableFrame
            let details = self.entryDiagnostics()
            NSLog("SimpleLive PiP: entry timeout %@", details.description)
            self.finishEntry(false, error: FlutterError(
                code: ready ? "pip_start_timeout" : "pip_not_ready",
                message: ready ? "Picture in Picture start timed out" : "Video frame is not ready",
                details: details))
            self.controller?.stopPictureInPicture()
            self.cleanUp()
        }
        entryTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
    }

    private var hasDisplayableFrame: Bool {
        guard hasEnqueuedFrame, renderSize.width > 0, renderSize.height > 0,
              let layer = videoView?.displayLayer, layer.status == .rendering else { return false }
        if #available(iOS 17.4, *) { return layer.isReadyForDisplay }
        return true
    }

    private func entryDiagnostics() -> [String: Any] {
        ["textureId": textureId ?? -1, "hasVideoFrame": hasEnqueuedFrame,
         "width": renderSize.width, "height": renderSize.height,
         "layerStatus": videoView?.displayLayer.status.rawValue ?? -1,
         "displayable": hasDisplayableFrame,
         "possible": controller?.isPictureInPicturePossible ?? false,
         "autoStart": controller?.canStartPictureInPictureAutomaticallyFromInline ?? false,
         "autoStartArmed": autoStartArmed,
         "enteredBackground": enteredBackground,
         "sourceFrames": sourceFrames, "enqueuedFrames": enqueuedFrames,
         "audioCategory": AVAudioSession.sharedInstance().category.rawValue]
    }

    private func startIfPossible() {
        // isPictureInPicturePossible 可能先于首帧到来，那时启动会让 AVKit
        // 拿到零视频尺寸。
        guard entryResult != nil, !startRequested, hasDisplayableFrame,
              let pip = controller, pip.isPictureInPicturePossible else { return }
        startRequested = true
        NSLog("SimpleLive PiP: startPictureInPicture issued %@",
              suspendOnStart ? "(manual + suspend)" : "(auto)")
        pip.startPictureInPicture()
        if suspendOnStart {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.textureId != nil else { return }
                UIApplication.shared.perform(NSSelectorFromString("suspend"))
            }
        }
    }

    private func clearEntryObservations() {
        possibleObservation = nil
        renderingObservation = nil
        if let observer = readyForDisplayObserver { NotificationCenter.default.removeObserver(observer) }
        readyForDisplayObserver = nil
    }

    private func finishEntry(_ entered: Bool, error: FlutterError? = nil) {
        clearEntryObservations()
        entryTimeout?.cancel()
        entryTimeout = nil
        let result = entryResult
        entryResult = nil
        if let error = error { result?(error) } else { result?(entered) }
    }

    /// 会话离场常驻（c1 897fe9d8）：SpringBoard 只对"已预热"的 remote
    /// object 发起自动起窗；销毁重建 = 每轮上滑都是新对象。保留
    /// controller/displayLayer/contentSource/timebase，只重置帧管线状态；
    /// 同一直播间重新 attach 时 textureId 与渲染尺寸天然吻合。
    private func softReset() {
        sessionGeneration += 1
        clearEntryObservations()
        hasEnqueuedFrame = false
        autoStartArmed = false
        updateAutoEnterFlag()
        videoView?.displayLayer.flushAndRemoveImage()
        renderSize = .zero
        pixelBufferPool = nil
        pixelBufferPoolSize = .zero
        formatDescription = nil
        startRequested = false
        startRetries = 0
        suspendOnStart = false
        activeFeed = false
        stopFeedPump()
        stopRequested = false
        enteredBackground = false
        restoring = false
        lastEnqueueAt = 0
        enqueuedFrames = 0
        sourceFrames = 0
        droppedFrames = 0
        dropNotReady = 0
        dropPool = 0
        mainHopDelaySum = 0
        mainHopCount = 0
        lastStatsAt = 0
        lastArtworkBuffer = nil
        lastArtworkRequested = false
        lastNowPlayingPlaying = false
        lastNowPlayingSynced = false
        NSLog("SimpleLive PiP: soft reset (session kept across rooms)")
    }

    private func cleanUp(completion: @escaping () -> Void = {}) {
        sessionGeneration += 1
        clearEntryObservations()
        hasEnqueuedFrame = false
        autoStartArmed = false
        controller?.delegate = nil
        controller = nil
        textureId = nil
        lastSourceRect = nil
        videoView?.displayLayer.flushAndRemoveImage()
        videoView?.removeFromSuperview()
        videoView = nil
        timebase = nil
        pixelBufferPool = nil
        pixelBufferPoolSize = .zero
        formatDescription = nil
        renderSize = .zero
        restoring = false
        startRequested = false
        suspendOnStart = false
        activeFeed = false
        stopFeedPump()
        enteredBackground = false
        stopRequested = false
        lastEnqueueAt = 0
        enqueuedFrames = 0
        sourceFrames = 0
        droppedFrames = 0
        dropNotReady = 0
        dropPool = 0
        mainHopDelaySum = 0
        mainHopCount = 0
        lastStatsAt = 0
        lastArtworkBuffer = nil
        lastArtworkRequested = false
        lastNowPlayingPlaying = false
        lastNowPlayingSynced = false
        // 渲染后端全程恒定，无渲染器需要恢复。
        completion()
    }

    func onVideoFrame(_ source: CVPixelBuffer, textureId: Int64, force: Bool = false) {
        guard self.textureId == textureId, let layer = videoView?.displayLayer else { return }
        if layer.status == .failed {
            hasEnqueuedFrame = false
            layer.flush()
        }
        if !force, feedPump != nil {
            // 兜底泵在场时（PiP 活跃或武装窗口），通知驱动的拉取是重复劳动，
            // 统一由泵按 30Hz 喂，静默跳过（不计 drop）。
            return
        }
        guard layer.isReadyForMoreMediaData else {
            droppedFrames += 1
            dropNotReady += 1
            return
        }

        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        guard width > 0, height > 0 else { droppedFrames += 1; return }
        let pixelFormat = CVPixelBufferGetPixelFormatType(source)
        guard pixelFormat == kCVPixelFormatType_32BGRA || pixelFormat == kCVPixelFormatType_32ARGB
        else { droppedFrames += 1; return }

        // renderSize 自愈：会话早于系统尺寸协商时（真机实测 render 0x0 卡
        // 11 秒、manual entry 5s 超时），用首帧实际尺寸回填，布局与
        // hasDisplayableFrame 据此恢复。
        if renderSize.width == 0 || renderSize.height == 0 {
            renderSize = CGSize(width: width, height: height)
            layoutVideoView()
        }

        // 采样节流：迟到的工作不追赶，跳过的帧零拷贝开销。
        // 兜底条件：isPictureInPictureActive 直接问系统，防止 activeFeed
        // 因任何时序漏置而把小窗采样压回 0.25s 保温档（实测 4fps 卡顿）。
        let now = CACurrentMediaTime()
        let pipActive = activeFeed
            || controller?.isPictureInPictureActive == true
            || (autoStartArmed && enteredBackground)
        let interval = (pipActive || entryResult != nil)
            ? IosPictureInPictureController.activeFrameInterval
            : IosPictureInPictureController.idleFrameInterval
        if !force, lastEnqueueAt > 0, now - lastEnqueueAt < interval {
            droppedFrames += 1
            logFrameStats(now: now)
            return
        }
        lastEnqueueAt = now
        sourceFrames += 1
        if willStartAt > 0 {
            NSLog("SimpleLive PiP: first frame after willStart in %.0fms", (now - willStartAt) * 1000)
            willStartAt = 0
        }
        // 封面/锁屏卡片的方框：每会话只生成一次。CI 走 software renderer
        // （后台 CIContext 默认 Metal 会被 BackgroundExecutionNotPermitted
        // 拒掉），成功后整场刷新一次卡片图。
        if !lastArtworkRequested {
            lastArtworkRequested = true
            let src = source
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self = self else { return }
                let ci = CIImage(cvPixelBuffer: src)
                let w = CGFloat(CVPixelBufferGetWidth(src))
                let h = CGFloat(CVPixelBufferGetHeight(src))
                let scale = 320.0 / max(w, h)
                let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let ctx = CIContext(options: [.useSoftwareRenderer: true])
                guard let cg = ctx.createCGImage(scaled, from: scaled.extent),
                      let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.8) else { return }
                self.lastArtworkBuffer = jpeg
                DispatchQueue.main.async { self.refreshNowPlayingInfo() }
            }
        }

        // 输出尺寸：长边上限 960，其余交给 AVSampleBufferDisplayLayer 按
        // videoGravity 自行缩放。不跟随 PiP 窗口/纹理尺寸变化：入场动画与
        // 首帧尺寸协商会让 outSize 漂移，逐帧重建池+flush 是掉帧源。
        var scale = 1.0
        let longEdge = max(width, height)
        let maxLongEdge = IosPictureInPictureController.maxLongEdge
        if longEdge > maxLongEdge {
            scale = Double(maxLongEdge) / Double(longEdge)
        }
        let outWidth = max(1, Int((Double(width) * scale).rounded()))
        let outHeight = max(1, Int((Double(height) * scale).rounded()))
        let outSize = CGSize(width: outWidth, height: outHeight)
        let bufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: outWidth, kCVPixelBufferHeightKey: outHeight,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            // AVKit 消费的缓冲要能被 CoreVideo/CoreImage 直接接管。
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        if pixelBufferPool == nil || pixelBufferPoolSize != outSize {
            hasEnqueuedFrame = false
            layer.flushAndRemoveImage()
            pixelBufferPoolSize = outSize
            formatDescription = nil
            pixelBufferPool = nil
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, bufferAttributes as CFDictionary, &pixelBufferPool)
        }
        var destination: CVPixelBuffer?
        if let pool = pixelBufferPool {
            let limits = [kCVPixelBufferPoolAllocationThresholdKey: 10] as CFDictionary
            CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                kCFAllocatorDefault, pool, limits, &destination)
        }
        if destination == nil {
            // 池配额耗尽（缓冲全被渲染链持有）时散配一帧兜底，绝不因阈值
            // 丢帧——真机实测 pool 桶 50% 丢帧=入场卡顿主因。
            CVPixelBufferCreate(kCFAllocatorDefault, outWidth, outHeight,
                                kCVPixelFormatType_32BGRA, bufferAttributes as CFDictionary, &destination)
        }
        guard let buffer = destination else {
            droppedFrames += 1
            dropPool += 1
            return
        }

        // media-kit 的后备缓冲区与引用计数无关地被复用；缩放/拷贝进有上界的
        // 缓冲池，保证 AVKit 读到的帧不会被覆盖（坑 4 的防线）。
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let src = CVPixelBufferGetBaseAddress(source),
           let dst = CVPixelBufferGetBaseAddress(buffer) {
            let srcStride = CVPixelBufferGetBytesPerRow(source)
            let dstStride = CVPixelBufferGetBytesPerRow(buffer)
            if scale == 1.0 {
                for row in 0..<height {
                    memcpy(dst.advanced(by: row * dstStride), src.advanced(by: row * srcStride),
                           min(width * 4, srcStride))
                }
            } else {
                // vImage（CPU，NEON）：缩放与合成一律走 CPU，避免与 mpv 的
                // GPU 上下文争用。
                var srcBuffer = vImage_Buffer(data: src,
                                              height: vImagePixelCount(height),
                                              width: vImagePixelCount(width),
                                              rowBytes: srcStride)
                var dstBuffer = vImage_Buffer(data: dst,
                                              height: vImagePixelCount(outHeight),
                                              width: vImagePixelCount(outWidth),
                                              rowBytes: dstStride)
                vImageScale_ARGB8888(&srcBuffer, &dstBuffer, nil, vImage_Flags(kvImageNoFlags))
            }
            // mpv bgr0 的第四字节不是 alpha，是未初始化的填充位。
            // AVKit 目标格式是 BGRA，因此只把这份独立拷贝设为不透明。
            for row in 0..<outHeight {
                let bytes = dst.advanced(by: row * dstStride).assumingMemoryBound(to: UInt8.self)
                for column in 0..<outWidth { bytes[column * 4 + 3] = 255 }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        CVPixelBufferUnlockBaseAddress(source, .readOnly)
        if formatDescription == nil {
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                        imageBuffer: buffer, formatDescriptionOut: &formatDescription)
        }
        guard let format = formatDescription else {
            droppedFrames += 1
            dropPool += 1
            return
        }
        // 帧投递纪律（PiliPlus 同款）：mpv 已经按自己的节奏出帧，直接要求
        // 立即显示，不再用 controlTimebase 采样 PTS 做二次节流。
        var timing = CMSampleTimingInfo(duration: .invalid,
                                       presentationTimeStamp: timebase.map(CMTimebaseGetTime) ?? .zero,
                                       decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample = sample else {
            droppedFrames += 1
            dropPool += 1
            return
        }
        markDisplayImmediately(sample)
        enqueue(sample, on: layer)
        let firstFrame = !hasEnqueuedFrame
        hasEnqueuedFrame = true
        enqueuedFrames += 1
        if firstFrame {
            // 首帧到齐 → canStartPictureInPictureAutomaticallyFromInline 才能为真
            // （PiliPlus `updateAutoEnter()`；系统只在帧齐后才判定可自动启动）。
            updateAutoEnterFlag()
        }
        logFrameStats(now: now)
        if entryResult != nil {
            DispatchQueue.main.async { [weak self] in self?.startIfPossible() }
        }
    }

    private func markDisplayImmediately(_ sample: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 else { return }
        let raw = CFArrayGetValueAtIndex(attachments, 0)
        let dictionary = unsafeBitCast(raw, to: CFMutableDictionary.self)
        CFDictionarySetValue(dictionary,
                             Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }

    private func enqueue(_ sample: CMSampleBuffer, on layer: AVSampleBufferDisplayLayer) {
        if #available(iOS 17.0, *) {
            let renderer = layer.sampleBufferRenderer
            if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
                renderer.flush()
            }
            renderer.enqueue(sample)
            return
        }
        if layer.status == .failed || layer.requiresFlushToResumeDecoding {
            layer.flush()
        }
        layer.enqueue(sample)
    }

    private func logFrameStats(now: Double) {
        guard now - lastStatsAt > 5.0 else { return }
        lastStatsAt = now
        let layer = videoView?.displayLayer
        var rendererStatus = layer?.status.rawValue ?? -1
        var requiresFlush = layer?.requiresFlushToResumeDecoding ?? false
        if #available(iOS 17.0, *) {
            rendererStatus = layer?.sampleBufferRenderer.status.rawValue ?? -1
            requiresFlush = layer?.sampleBufferRenderer.requiresFlushToResumeDecoding ?? false
        }
        let hopCount = mainHopCount
        let hopAvg = hopCount > 0 ? mainHopDelaySum / Double(hopCount) * 1000.0 : 0
        mainHopDelaySum = 0
        mainHopCount = 0
        NSLog("SimpleLive PiP: frames source=%ld enqueued=%ld dropped=%ld (notReady=%ld throttle=%ld pool=%ld), render %.0fx%.0f, layerStatus=%ld, rendererStatus=%ld requiresFlush=%ld, mainHop=%.1fms/%ld",
              sourceFrames, enqueuedFrames, droppedFrames, dropNotReady,
              droppedFrames - dropNotReady - dropPool, dropPool,
              renderSize.width, renderSize.height,
              layer?.status.rawValue ?? -1,
              rendererStatus,
              requiresFlush ? 1 : 0,
              hopAvg, hopCount)
    }

    static func hostWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
        // 优先 Flutter 所在窗口（PiliPlus hostWindow 同款判定顺序）。
        if let flutterWindow = windows.first(where: { $0.rootViewController is FlutterViewController }) {
            return flutterWindow
        }
        return windows.first(where: { $0.isKeyWindow }) ?? windows.first
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard controller === pictureInPictureController else { return }
        // 自动启动路径的过渡保护：立即通知 Dart 进入 PiP 模式
        // （同步定时器提前运行，绘制状态不再漂移）。
        activeFeed = true
        syncFeedPump()
        // 小窗启动即重置图层解码管线：入场会话实测过图层内部队列不消费
        // （isReadyForMoreMediaData 长期 false，入队仅 ~11fps 抖动）；清掉
        // 入场前保温期积压的旧样本，让泵从空管线以 30Hz 重建画面。
        willStartAt = CACurrentMediaTime()
        // PiliPlus 同构：willStart 不 flush，仅立即补一帧（force 跳过节流）。
        // 无条件 flush 会清空已排队样本，小窗首瞬必空 1-2 帧（860 日志用户
        // 复测"还是有一瞬间的卡顿"）；排队帧的病态自愈交给 enqueue 的
        // failed/requiresFlush 守卫即可。
        if let id = textureId, let buffer = copyPixelBuffer?(id) {
            onVideoFrame(buffer, textureId: id, force: true)
        }
        refreshNowPlayingInfo()
        NSLog("SimpleLive PiP: will start (%@)",
              suspendOnStart ? "manual + suspend" : "auto")
        channel.invokeMethod("onModeChanged", arguments: ["isInPipMode": true])
        // 渲染后端恒定：此处不再切换软件渲染。
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard controller === pictureInPictureController else { return }
        startRetries = 0
        channel.invokeMethod("onModeChanged", arguments: ["isInPipMode": true])
        // 小窗真正 Active 时同步一次 Now Playing（rate/进度翻面），
        // 锁屏与控制中心卡片据此从"准备中/暂停"切回"在播"。
        lastNowPlayingSynced = false
        refreshNowPlayingInfo()
        finishEntry(true)
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        guard controller === pictureInPictureController else { return }
        activeFeed = false
        syncFeedPump()
        let failure = error as NSError
        var details = entryDiagnostics()
        details["domain"] = failure.domain
        details["code"] = failure.code
        if let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError {
            details["underlyingDomain"] = underlying.domain
            details["underlyingCode"] = underlying.code
        }
        NSLog("SimpleLive PiP: start failed %@", details.description)
        finishEntry(false, error: FlutterError(code: "pip_start_failed",
            message: "\(failure.domain) (\(failure.code))", details: details))
        // 自动路径的启动失败一律保留会话（软失败）：会话是常驻温热的，
        // 拆掉它只会让系统重新"喂熟"一遍，更糟。
        if autoStartArmed {
            activeFeed = false
            suspendOnStart = false
            // 失败即释放 startRequested：否则一次 -1001 之后 Manual 路径
            // 的重进也会被卡死的标志拦住。
            if startRequested, !restoring {
                startRequested = false
                NSLog("SimpleLive PiP: startRequested released after failure (retry chain armed)")
            }
            // 冷却窗口应对：SpringBoard 在 PiP 停止后约 3-5s 内压制一切起窗
            // （052807 实锤：判定全 YES 仍不发起，显式 start 也被 -1001 拒；
            // 用户 5s/轮快测全败，隔 8s 成功；PiliPlus"100%"源于长观看节奏
            // 远离冷却窗口）。失败后每秒重试，等窗口过期自动补起。
            if failure.domain == AVKitErrorDomain, failure.code == -1001 {
                startRetries += 1
                let gen = sessionGeneration
                let attempt = startRetries
                if attempt <= 10 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        guard let self = self, self.sessionGeneration == gen,
                              self.enteredBackground,
                              UIApplication.shared.applicationState == .background,
                              !(self.controller?.isPictureInPictureActive ?? false),
                              self.isPictureInPicturePossible,
                              self.hasEnqueuedFrame,
                              !self.startRequested else { return }
                        self.startRequested = true
                        NSLog("SimpleLive PiP: background retry #\(attempt) after -1001")
                        self.pip.startPictureInPicture()
                    }
                }
            }
            return
        }
        cleanUp()
    }

    /// 软停止：复位进入态但保留会话/图层/像素池/纹理管线。
    private func softStopReset() {
        entryTimeout?.cancel()
        entryTimeout = nil
        startRequested = false
        suspendOnStart = false
        activeFeed = false
        syncFeedPump()
        finishEntry(false)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard controller === pictureInPictureController else { return }
        let restored = restoring
        let closedByApp = stopRequested
        stopRequested = false
        restoring = false
        if closedByApp {
            // 回 app 自动关闭：会话保留（软停止），下一次退后台系统标志直接拉起。
            softStopReset()
            channel.invokeMethod("onModeChanged",
                arguments: ["isInPipMode": false, "restored": restored, "closedByApp": true])
            return
        }
        if restored {
            // 用户点"返回 app"：镜像层本就在 window 底层，无需收放；软停止即可。
            softStopReset()
            channel.invokeMethod("onModeChanged",
                arguments: ["isInPipMode": false, "restored": true])
            return
        }
        // 系统侧关闭（用户在小窗按关闭钮等）：整段清理。
        finishEntry(false)
        cleanUp()
        channel.invokeMethod("onModeChanged",
            arguments: ["isInPipMode": false, "restored": restored, "closedByApp": closedByApp])
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        restoring = true
        channel.invokeMethod("onRestore", arguments: nil) { [weak self] result in
            let restored = result as? Bool ?? false
            self?.restoring = restored
            completionHandler(restored)
        }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        channel.invokeMethod("onAction", arguments: ["action": playing ? "play" : "pause"])
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        // 恒定无限区间（直播）。任何有限区间都会让系统按点播渲染
        // 进度条与 ±10 秒快进/快退按钮。
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        !playing
    }

    /// 显式 @objc 选择器：8a71c4b3 实测隐式推断未给该方法暴露 ObjC 入口
    /// （构建二进制缺 selector，AVKit respondsToSelector 不命中）。
    @objc(pictureInPictureControllerIsPlaybackBufferEmpty:)
    func pictureInPictureControllerIsPlaybackBufferEmpty(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        // 不实现时 AVKit 自行探测缓冲，willStart 的 flush 重置后会被误判成
        // "视频还没准备好"，小窗菜单的播放按钮随之失效；显式回报缓冲状态。
        !hasEnqueuedFrame
    }

    /// PiP 窗口尺寸变化 → 记下实际 renderSize（PiliPlus `didTransitionToRenderSize`）。
    /// 输出尺寸据此压缩，避免超采样；同时立刻补一帧让新窗口有画面。
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        renderSize = CGSize(width: Int(newRenderSize.width), height: Int(newRenderSize.height))
        lastEnqueueAt = 0
        layoutVideoView()
        if let id = textureId, let buffer = copyPixelBuffer?(id) {
            onVideoFrame(buffer, textureId: id, force: true)
        }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        let current = timebase.map { CMTimeGetSeconds(CMTimebaseGetTime($0)) } ?? 0
        let target = max(0, min(duration > 0 ? duration : .greatestFiniteMagnitude,
                               current + CMTimeGetSeconds(skipInterval)))
        channel.invokeMethod("onAction", arguments: ["action": "seek", "positionMillis": Int64(target * 1000)]) {
            _ in completionHandler()
        }
    }
}
