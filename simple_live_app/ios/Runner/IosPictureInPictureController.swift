import AVKit
import Accelerate
import Flutter
import UIKit

// v4（混合路线：SwiftPeek/PiliPlus 温热管线 + Kazumi 软件渲染后台续航）：
//   1. 全程不切换渲染器的温热帧管线只用于"武装"：会话与首帧在前台就绪
//      （未进小窗 4fps 保温、进小窗/进入中 30fps 全速），ARM 后置
//      canStartPictureInPictureAutomaticallyFromInline。
//   2. 镜像层常态离屏（窗口左上角 1px）：v3 实证插在 FlutterView 内的
//      子视图位于 Flutter 绘制内容之上，以 4fps 镜像"顶替"真实直播
//      ——房间卡顿与菜单被"直播挡住"皆源于此。PiP 消费 AVSampleBuffer
//      只依赖 layer 本身，不依赖视图正常展示。
//   3. media_kit 后台 GPU 渲染停摆（v3 实证：小窗冻结在最后一帧；v1
//      软件渲染路径实证后台可续帧）→ 软件渲染在武装时刻预演切换
//      （v6：真机实证启动时切换会让首个小窗卡 1-2 秒），WillStart 时
//      管线已就绪，小窗全程 30fps——前台零卡与后台活画面兼得。
//   4. 自动启动三路保险：a) 系统标志（退后台探针：镜像层临时摆回视频
//      区域最顶层，回前台收回）；b) inactive 阶段显式 start（Dart 新
//      通道 enterAuto，此时重活已全部就绪仅余一行调用）；c) 退后台 1 秒
//      原生显式 start 兜底。全程日志可定案。
//   5. 回前台且 PiP 活跃即自动 stop（除启动过渡回声），小窗不残留，
//      同时根除残留会话导致的 AVKitErrorDomain -1001。
//   6. 时基纪律：PTS 来自 controlTimebase，不与
//      kCMSampleAttachmentKey_DisplayImmediately 混用（30fps 采样、
//      960px 长边上限、vImage CPU 缩放、单槽 latest、背压）。
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
    var useSoftwareRendering: ((Int64, @escaping (Bool) -> Void) -> Void)?
    var restoreRendering: ((@escaping () -> Void) -> Void)?
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
    private var suspendOnStart = false
    private var restoring = false
    private var textureId: Int64?
    private var pendingRenderHandle: Int64?
    private var softwareSwitchDone = false
    private var lastSourceRect: CGRect?
    private var lastWillStartAt: Double = 0
    private var playing = false
    private var duration: Double = 0
    private var timebase: CMTimebase?
    private var pixelBufferPool: CVPixelBufferPool?
    private var formatDescription: CMVideoFormatDescription?
    private var frameSize = CGSize.zero

    // 帧泵纪律（SwiftPeek PiPFramePump 设计，PiliPlus 同款双速）：
    // 进小窗/进入中 30fps 全速；未进小窗 4fps 低速保温（层在 Flutter 视图
    // 之下不可见，拷贝/缩放开销可忽略——vImage CPU 路线后台也可靠）。
    private static let activeFrameInterval: Double = 1.0 / 30.0
    private static let idleFrameInterval: Double = 0.25
    // 小窗物理尺寸有限，超采样是浪费；长边 960px。
    private static let maxLongEdge: Int = 960
    /// 画中画激活或正在进入时为真（提高采样速率）。
    private var activeFeed = false
    private var autoStartArmed = false
    private var enteredBackground = false
    private var stopRequested = false
    private var backgroundAutoStartCheck: DispatchWorkItem?
    private var lastEnqueueAt = 0.0
    private var enqueuedFrames = 0
    private var sourceFrames = 0
    private var droppedFrames = 0
    private var lastStatsAt = 0.0

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "simple_live/ios_pip", binaryMessenger: messenger)
        super.init()
        registerLifecycleObservers()
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { result(false); return }
            let args = call.arguments as? [String: Any] ?? [:]
            switch call.method {
            case "isSupported":
                result(AVPictureInPictureController.isPictureInPictureSupported())
            case "attach":
                self.attachSession(args, result: result)
            case "softwareRendering":
                // v3 已废弃：全程保持 GPU 渲染管线，不再切换软件渲染。
                // 兼容旧 Dart 二进制的调用，只确认不做。
                NSLog("SimpleLive PiP: softwareRendering ignored (obsolete in v3)")
                result(nil)
            case "updatePlaybackState":
                self.updatePlaybackState(args)
                result(nil)
            case "enter":
                self.enter(result)
            case "enterAuto":
                self.enterAuto(result)
            case "setAutoStartEnabled":
                // 退后台自动启动的唯一正规机制（Apple 文档契约）：
                // 后台时 startPictureInPicture() 不保证可用，须由系统在
                // 用户退后台瞬间自行拉起。帧管线全程温热（保底 4fps），
                // 层内恒有新鲜帧，随建随武装即可（PiliPlus 同款）。
                let enabled = args["enabled"] as? Bool == true
                guard let controller = self.controller else {
                    NSLog("SimpleLive PiP: autoStart \(enabled) ignored, no session")
                    result(false)
                    return
                }
                autoStartArmed = enabled
                controller.canStartPictureInPictureAutomaticallyFromInline = enabled
                NSLog("SimpleLive PiP: autoStart set to %@", enabled ? "true" : "false")
                if enabled {
                    // v8：新房间会创建新的 Pegasus 远程对象，真机日志实证
                    // SpringBoard 对全新对象的首次退后台不发起启动（判定
                    // YES 却按兵不动），直到标志被重复推送多次后才认。
                    // 在前台武装时刻主动 OFF→ON 重推两次，赶在用户首次
                    // 上滑之前完成绑定（此处均为前台操作，无 -1001 风险）。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        guard let self = self, let c = self.controller,
                              self.autoStartArmed, !c.isPictureInPictureActive else { return }
                        c.canStartPictureInPictureAutomaticallyFromInline = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                            guard let self = self, let c = self.controller,
                                  self.autoStartArmed, !c.isPictureInPictureActive else { return }
                            c.canStartPictureInPictureAutomaticallyFromInline = true
                            NSLog("SimpleLive PiP: autoStart flag re-pushed (bind new remote object)")
                        }
                    }
                }
                result(true)
            case "dispose":
                self.finishEntry(false)
                self.controller?.stopPictureInPicture()
                self.cleanUp { result(nil) }
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    func videoOutputWillChange(_ handle: Int64, completion: @escaping (Bool) -> Void) {
        channel.invokeMethod("onVideoOutputWillChange", arguments: ["handle": handle]) {
            completion($0 as? Bool ?? false)
        }
    }

    func videoOutputDidChange(_ handle: Int64, waitForTexture: Bool, completion: @escaping (Bool) -> Void) {
        channel.invokeMethod("onVideoOutputDidChange", arguments: ["handle": handle, "waitForTexture": waitForTexture]) {
            completion($0 as? Bool ?? false)
        }
    }

    /// 建立画中画会话（内容源 + delegate + 时基），不切换渲染器。
    /// 设计用于开播即调用（早武装）：GPU 渲染管线全程恒定，帧镜像
    /// 持续（前台全速、未进小窗 4fps 保温），随后 setAutoStartEnabled
    /// 打开系统自动启动开关即完成武装。
    private func attachSession(_ args: [String: Any], result: @escaping FlutterResult) {
        let prepared = prepareSource(args)
        if !prepared {
            NSLog("SimpleLive PiP: attach failed %@", entryDiagnostics().description)
        } else {
            NSLog("SimpleLive PiP: attach ok, texture %@, size %.0fx%.0f",
                  (args["textureId"] as? NSNumber)?.stringValue ?? "nil",
                  frameSize.width, frameSize.height)
        }
        result(prepared)
    }

    /// 应用级生命周期观察（控制器与 Flutter 引擎同生命周期，注册一次）：
    /// 回前台自动 stop（修"回 app 小窗还在"），退后台做兜底启动检查。
    private func registerLifecycleObservers() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.handleDidEnterBackground() }
        // PiliPlus 注记：PiP 启动/停止也会广播前台场景通知，所以
        // didActivate 必须以 enteredBackground 为前提，避免回环。
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.handleDidBecomeActive() }
        NotificationCenter.default.addObserver(
            forName: UIScene.didActivateNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.handleDidBecomeActive() }
    }

    private func handleDidEnterBackground() {
        guard let pip = controller else { return }
        enteredBackground = true
        stopRequested = false
        // 内联可见性探针（v4）：系统自动拉起需要"inline 内容源可见"的
        // 判定条件。退后台瞬间把镜像层摆回视频区域最顶层，给系统判定
        // 的机会；成功与否日志见下，探针在回前台时收回。
        mirrorExpose()
        NSLog("SimpleLive PiP: didEnterBackground, autoStart=%@ possible=%@ active=%@ playing=%@ hasFrame=%@ src=%ld enq=%ld",
              pip.canStartPictureInPictureAutomaticallyFromInline ? "true" : "false",
              pip.isPictureInPicturePossible ? "true" : "false",
              pip.isPictureInPictureActive ? "true" : "false",
              playing ? "true" : "false",
              hasEnqueuedFrame ? "true" : "false",
              sourceFrames, enqueuedFrames)
        // 层内恒有新鲜帧 + 自动启动开关已开，系统应即拉起。
        // v5：不再在后台显式 start 兜底——AVKit 日志实证场景态
        // activationState=Background 时 startPictureInPicture 一律被拒
        // （AVKitErrorDomain -1001，20:27 轮次五连败）。合法路径只剩：
        // 系统标志自动启动 + inactive 阶段的显式 start（enterAuto）。
        // 1 秒后仍未拉起只记录观察日志，不再硬闯。
        backgroundAutoStartCheck?.cancel()
        guard autoStartArmed, !pip.isPictureInPictureActive, playing else { return }
        let check = DispatchWorkItem { [weak self] in
            guard let self = self, let pip = self.controller else { return }
            guard self.autoStartArmed, !pip.isPictureInPictureActive, !self.stopRequested else { return }
            // v6 实测：武装后 2 秒内的首次退后台，SpringBoard 反复判定
            // "可以自动拉起"却按兵不动（真机日志 22:05:42：ShouldAutoPiP
            // YES 连发而 startPictureInPictureEnteringBackground 从未发出，
            // 4 秒后的第二次退后台才正常）。系统自发的后台启动合法
            // （-1001 只拦应用显式 start），这里把标志 OFF→ON 重新推给
            // SpringBoard，逼它重新评估并补发错过的启动。
            NSLog("SimpleLive PiP: system auto start did not happen (1s), re-arming flag to nudge SpringBoard")
            pip.canStartPictureInPictureAutomaticallyFromInline = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self = self, let pip = self.controller,
                      self.autoStartArmed, !pip.isPictureInPictureActive else { return }
                pip.canStartPictureInPictureAutomaticallyFromInline = true
                NSLog("SimpleLive PiP: autoStart flag re-armed (nudge while backgrounded)")
            }
        }
        backgroundAutoStartCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: check)
    }

    private func handleDidBecomeActive() {
        backgroundAutoStartCheck?.cancel()
        backgroundAutoStartCheck = nil
        enteredBackground = false
        // 探针立即收回。v7 实测延迟收回会在恢复窗口内露出镜像层——
        // 用户此刻退出直播页会看到"直播画面跟着页面切出去"。
        // restoring 守卫：若恢复流程已先行把镜像层摆回视频区（收缩
        // 动画目标），不能收回（DidStop 后由恢复分支收回）。
        if !restoring {
            mirrorConceal()
        }
        guard let pip = controller else { return }
        // 回 app 自动关闭小窗（PiP 关闭即回归行内，小窗不再残留）。
        // v8：取消 1.5s 启动过渡守卫——真机实测守卫期内返回会被跳过，
        // 只能靠 0.6s 延迟复查补停，小窗要多挂约 1 秒才消失。回声保护
        // 改由 applicationState 把关：真回 app 必然 active；启动回声期
        // PiP 尚未 active 不会误停。回到前台立即关，不再等待。
        pip.canStartPictureInPictureAutomaticallyFromInline = autoStartArmed
        if pip.isPictureInPictureActive && !restoring
            && UIApplication.shared.applicationState == .active {
            NSLog("SimpleLive PiP: became active, stopPictureInPicture issued (auto stop on return)")
            stopRequested = true
            pip.stopPictureInPicture()
        }
    }

    /// 探针：把镜像层摆回视频区域最顶层（可见）。
    private func mirrorExpose() {
        guard let rect = lastSourceRect, let rootView = videoView?.superview,
              let videoView = videoView else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootView.bringSubviewToFront(videoView)
        videoView.frame = rect
        CATransaction.commit()
        NSLog("SimpleLive PiP: mirror exposed at video rect (inline visibility probe)")
    }

    /// 探针结束：镜像层收回窗口左上角 1px 离屏。
    private func mirrorConceal() {
        guard let videoView = videoView else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoView.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        CATransaction.commit()
    }

    /// PiP 启动即切软件渲染：media_kit 的 GPU 渲染后台停摆（CADisplayLink
    /// 类驱动随生命周期暂停），此前 v1 的软件渲染路径实证可在后台持续
    /// 出帧。小窗已启动后切换（数百毫秒），期间小窗保持旧帧，此后持续
    /// 有 30fps 新鲜帧——不影响前台行内画面，也不产生进入时 1 秒卡顿。
    private func switchToSoftwareRenderingForPip() {
        guard !softwareSwitchDone, let handle = pendingRenderHandle,
              let useSoftwareRendering = useSoftwareRendering else {
            if !softwareSwitchDone {
                NSLog("SimpleLive PiP: software rendering switch skipped (no handle/renderer)")
                softwareSwitchDone = true
            }
            return
        }
        softwareSwitchDone = true
        let generation = sessionGeneration
        NSLog("SimpleLive PiP: software rendering switch issued (prewarm at arm / post-start)")
        useSoftwareRendering(handle) { [weak self] ready in
            guard let self = self, self.sessionGeneration == generation else { return }
            NSLog("SimpleLive PiP: software rendering switch %@",
                  ready ? "ready" : "failed (PiP may hold last frame)")
            if ready {
                // 通知 Dart 立即把新纹理 ID 同步回来，缩短小窗静止间隙。
                self.channel.invokeMethod("onSoftwareSwitchReady", arguments: nil)
            }
        }
    }

    private func prepareSource(_ args: [String: Any]) -> Bool {
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              let id = args["textureId"] as? NSNumber,
              let rootView = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows }).first(where: { $0.isKeyWindow })?.rootViewController?.view,
              rootView.window != nil else { return false }

        if controller == nil {
            let view = PipVideoView()
            view.isUserInteractionEnabled = false
            view.displayLayer.videoGravity = .resizeAspect
            CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                                           sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
            view.displayLayer.controlTimebase = timebase
            // 压到底层：镜像层在应用内不可见，AVKit 只是消费这个内容源。
            rootView.insertSubview(view, at: 0)
            // v4：镜像层常态离屏（窗口左上角 1px、裁剪）。v3 实证插在
            // FlutterView 内的子视图位于 Flutter 绘制内容之上，前台会以
            // 4fps 镜像"顶替"真实直播——房间卡顿与菜单被"直播挡住"皆源于
            // 此；v6 起软件渲染在武装时刻预演切换（见 prepareSource 尾部），
            // 小窗启动时管线已就绪，画面持续新鲜。
            view.clipsToBounds = true
            view.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            videoView = view
            let content = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: view.displayLayer, playbackDelegate: self)
            let pip = AVPictureInPictureController(contentSource: content)
            pip.delegate = self
            pip.canStartPictureInPictureAutomaticallyFromInline = false
            controller = pip
            // v5：仅在新建会话时复位软件渲染切换标记。常驻温热会话的
            // 重进（软停止后 attach）渲染器已是软件态，重复切换会闪黑。
            softwareSwitchDone = false
            NSLog("SimpleLive PiP: session created")
        }
        textureId = id.int64Value
        if let handle = args["handle"] as? NSNumber {
            pendingRenderHandle = handle.int64Value
        }
        updatePlaybackState(args)
        if let buffer = copyPixelBuffer?(id.int64Value) {
            onVideoFrame(buffer, textureId: id.int64Value)
        }
        // v6：预演切换移到武装时刻。此前小窗启动（WillStart）才切软件
        // 渲染，切换管线（排空→重建纹理→注册等待→恢复）耗时 1-2 秒，
        // 真机实证首个小窗必卡这一两秒；而软停止保住会话后"后续每次都
        // 流畅"恰好证明管线就位即全程流畅。提前到前台开播瞬间切换
        // （加载转圈窗口期，行内几乎无感），WillStart 时管线已就绪，
        // 首个小窗零切换秒顺。后台会话不加新切换。
        switchToSoftwareRenderingForPip()
        return true
    }

    private func updatePlaybackState(_ args: [String: Any]) {
        let oldTextureId = textureId
        if let id = args["textureId"] as? NSNumber { textureId = id.int64Value }
        playing = args["playing"] as? Bool ?? false
        duration = max(0, (args["durationMillis"] as? NSNumber)?.doubleValue ?? 0) / 1000
        let position = max(0, (args["positionMillis"] as? NSNumber)?.doubleValue ?? 0) / 1000
        let rate = (args["rate"] as? NSNumber)?.doubleValue ?? 1
        if let timebase = timebase {
            CMTimebaseSetTime(timebase, time: CMTime(seconds: position, preferredTimescale: 1000))
            CMTimebaseSetRate(timebase, rate: playing ? rate : 0)
        }
        // v4：镜像层常态离屏，不随 sourceRect 移动；仅在退后台探针时
        // 临时摆回视频区域（mirrorExpose）。这里缓存最近一次区域。
        if let rect = args["sourceRect"] as? [String: NSNumber] {
            lastSourceRect = CGRect(x: rect["left"]?.doubleValue ?? 0,
                                    y: rect["top"]?.doubleValue ?? 0,
                                    width: rect["width"]?.doubleValue ?? 0,
                                    height: rect["height"]?.doubleValue ?? 0)
        }
        // v5：本控制器专用直播页面——恒定直播语义。mpv 对直播 HLS 会把
        // 缓冲长度报成时长（日志实证 ContentDuration=7.22s），系统因此在
        // 小窗显示点播 UI（进度条+快进/快退10秒）。无限区间 + 线性播放
        // 即三件套全消（LIVE 标记替代）。
        controller?.requiresLinearPlayback = true
        controller?.invalidatePlaybackState()
        // 渲染后端切换会产生新的纹理 ID。暂停状态下可能只渲染一帧，
        // 所以在 Dart 侧上报新 ID 时立刻取一次。
        if oldTextureId != textureId, let id = textureId,
           let buffer = copyPixelBuffer?(id) {
            onVideoFrame(buffer, textureId: id)
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

    /// inactive 阶段的显式启动（v9 恢复 v4 通道）：系统自动启动对全新
    /// Pegasus 远程对象的首次退后台始终不发起（v7/v8 两轮真机日志实证，
    /// 预绑定与后台补推均无效），而 v4 的 inactive 显式 start 实证首次
    /// 即成功（彼时场景仍在前台，合法；后台显式 start 才是 -1001）。
    /// 防误触发：仅当应用已非完全活跃（正在离开）才发——控制中心快速
    /// 关闭回到活跃态时不会弹小窗；停留的控制中心场景小窗会短暂出现，
    /// 回前台自动关闭自愈。
    private func enterAuto(_ result: @escaping FlutterResult) {
        guard let pip = controller else {
            NSLog("SimpleLive PiP: enterAuto ignored, no session")
            result(false); return
        }
        guard UIApplication.shared.applicationState != .active else {
            NSLog("SimpleLive PiP: enterAuto ignored, app fully active")
            result(false); return
        }
        guard !pip.isPictureInPictureActive, entryResult == nil,
              hasEnqueuedFrame, suspendOnStart == false else {
            result(false); return
        }
        NSLog("SimpleLive PiP: startPictureInPicture issued (auto@inactive), possible=%@",
              pip.isPictureInPicturePossible ? "true" : "false")
        pip.startPictureInPicture()
        result(true)
    }

    private var hasDisplayableFrame: Bool {        guard hasEnqueuedFrame, frameSize.width > 0, frameSize.height > 0,
              let layer = videoView?.displayLayer, layer.status == .rendering else { return false }
        if #available(iOS 17.4, *) { return layer.isReadyForDisplay }
        return true
    }

    private func entryDiagnostics() -> [String: Any] {
        ["textureId": textureId ?? -1, "hasVideoFrame": hasEnqueuedFrame,
         "width": frameSize.width, "height": frameSize.height,
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
        // isPictureInPicturePossible 可能先于替换纹理的第一帧到来。
        // 那时启动会让 AVKit 拿到零视频尺寸。
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

    private func cleanUp(completion: @escaping () -> Void = {}) {
        sessionGeneration += 1
        clearEntryObservations()
        hasEnqueuedFrame = false
        autoStartArmed = false
        controller?.delegate = nil
        controller = nil
        textureId = nil
        pendingRenderHandle = nil
        softwareSwitchDone = false
        lastSourceRect = nil
        lastWillStartAt = 0
        videoView?.displayLayer.flushAndRemoveImage()
        videoView?.removeFromSuperview()
        videoView = nil
        timebase = nil
        pixelBufferPool = nil
        formatDescription = nil
        frameSize = .zero
        restoring = false
        startRequested = false
        suspendOnStart = false
        activeFeed = false
        backgroundAutoStartCheck?.cancel()
        backgroundAutoStartCheck = nil
        lastEnqueueAt = 0
        enqueuedFrames = 0
        sourceFrames = 0
        droppedFrames = 0
        lastStatsAt = 0
        // v3 不再切换渲染器，restoreRendering 闭包即时返回；保留调用
        // 以兼容 AppDelegate 现有接线。
        if let restoreRendering = restoreRendering {
            restoreRendering(completion)
        } else {
            completion()
        }
    }

    func onVideoFrame(_ source: CVPixelBuffer, textureId: Int64) {
        guard self.textureId == textureId, let layer = videoView?.displayLayer else { return }
        if layer.status == .failed {
            hasEnqueuedFrame = false
            layer.flush()
        }
        guard layer.isReadyForMoreMediaData else { droppedFrames += 1; return }

        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        guard width > 0, height > 0,
              CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA else {
            droppedFrames += 1
            return
        }
        // 采样节流：迟到的工作不追赶，跳过的帧零拷贝开销。
        let now = CACurrentMediaTime()
        let interval = (activeFeed || entryResult != nil)
            ? IosPictureInPictureController.activeFrameInterval
            : IosPictureInPictureController.idleFrameInterval
        if lastEnqueueAt > 0, now - lastEnqueueAt < interval {
            droppedFrames += 1
            logFrameStats(now: now)
            return
        }
        lastEnqueueAt = now
        sourceFrames += 1

        // 输出上限：小窗物理尺寸就那么大，超采样是浪费（SwiftPeek 长边 960px）。
        let longEdge = max(width, height)
        let maxLongEdge = IosPictureInPictureController.maxLongEdge
        let scaleFactor = longEdge > maxLongEdge ? Double(maxLongEdge) / Double(longEdge) : 1.0
        let outWidth = max(1, Int((Double(width) * scaleFactor).rounded()))
        let outHeight = max(1, Int((Double(height) * scaleFactor).rounded()))
        let outSize = CGSize(width: outWidth, height: outHeight)
        if outSize != frameSize {
            hasEnqueuedFrame = false
            layer.flushAndRemoveImage()
            frameSize = outSize
            formatDescription = nil
            pixelBufferPool = nil
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: outWidth, kCVPixelBufferHeightKey: outHeight,
                kCVPixelBufferIOSurfacePropertiesKey: [:]
            ]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pixelBufferPool)
        }
        guard let pool = pixelBufferPool else { return }
        var destination: CVPixelBuffer?
        let limits = [kCVPixelBufferPoolAllocationThresholdKey: 3] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault, pool, limits, &destination) == kCVReturnSuccess,
              let buffer = destination else { return }

        // media-kit 的三个后备缓冲区与引用计数无关地被复用。
        // 缩放/拷贝进有上界的缓冲池，保证 AVKit 读到的帧不会被覆盖。
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let src = CVPixelBufferGetBaseAddress(source), let dst = CVPixelBufferGetBaseAddress(buffer) {
            let srcStride = CVPixelBufferGetBytesPerRow(source)
            let dstStride = CVPixelBufferGetBytesPerRow(buffer)
            if scaleFactor == 1.0 {
                for row in 0..<height {
                    memcpy(dst.advanced(by: row * dstStride), src.advanced(by: row * srcStride), width * 4)
                }
            } else {
                // vImage（CPU，NEON）：后台 GPU 路线不可靠，缩放与合成一律走 CPU。
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
        guard let format = formatDescription else { return }
        // 时基纪律：PTS 来自 controlTimebase（与主时钟同步），不再附加
        // DisplayImmediately——附件与时基混用为 AVFoundation 头文件明确不建议。
        var timing = CMSampleTimingInfo(duration: .invalid,
                                       presentationTimeStamp: timebase.map(CMTimebaseGetTime) ?? .zero,
                                       decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample = sample else { return }
        layer.enqueue(sample)
        hasEnqueuedFrame = true
        enqueuedFrames += 1
        logFrameStats(now: now)
        if entryResult != nil {
            DispatchQueue.main.async { [weak self] in self?.startIfPossible() }
        }
    }

    private func logFrameStats(now: Double) {
        guard now - lastStatsAt > 5.0 else { return }
        lastStatsAt = now
        NSLog("SimpleLive PiP: frames source=%ld enqueued=%ld dropped=%ld, size %.0fx%.0f, layerStatus=%ld",
              sourceFrames, enqueuedFrames, droppedFrames,
              frameSize.width, frameSize.height,
              videoView?.displayLayer.status.rawValue ?? -1)
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard controller === pictureInPictureController else { return }
        // 自动启动路径的过渡保护：立即通知 Dart 进入 PiP 模式
        // （同步定时器提前运行，绘制状态不再漂移）。
        activeFeed = true
        lastWillStartAt = CACurrentMediaTime()
        NSLog("SimpleLive PiP: will start (%@)",
              suspendOnStart ? "manual + suspend" : "auto")
        channel.invokeMethod("onModeChanged", arguments: ["isInPipMode": true])
        // 启动即切软件渲染，让小窗在后台持续出帧（GPU 路线已实证停摆）。
        switchToSoftwareRenderingForPip()
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard controller === pictureInPictureController else { return }
        channel.invokeMethod("onModeChanged", arguments: ["isInPipMode": true])
        finishEntry(true)
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        guard controller === pictureInPictureController else { return }
        activeFeed = false
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
        // v5：后台里的启动失败（-1001 等，场景态不允许）保留会话继续
        // 保温热——拆了再建只会引入会话抖动，而系统自动启动仍可能随后
        // 拉起；前台路径的失败才整段清理（点播手动进入需重置状态）。
        if enteredBackground && autoStartArmed {
            activeFeed = false
            return
        }
        cleanUp()
    }

    /// 软停止：复位进入态但保留会话/图层/像素池/纹理管线。
    /// v5 核心变更——重建会话 during 后台必被系统拒绝（-1001），而保留
    /// 常驻温热会话后系统自动启动在每次退后台都能立即拉起（首轮实证）。
    private func softStopReset() {
        entryTimeout?.cancel()
        entryTimeout = nil
        startRequested = false
        suspendOnStart = false
        activeFeed = false
        lastWillStartAt = 0
        finishEntry(false)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard controller === pictureInPictureController else { return }
        let restored = restoring
        let closedByApp = stopRequested
        stopRequested = false
        restoring = false
        if closedByApp {
            // 回 app 自动关闭：会话保留（软停止）。镜像层收回离屏。
            softStopReset()
            mirrorConceal()
            channel.invokeMethod("onModeChanged",
                arguments: ["isInPipMode": false, "restored": restored, "closedByApp": true])
            return
        }
        if restored {
            // 用户从小窗点"返回 app"：收起动画以镜像层（已摆在视频区）
            // 为目标飞行。DidStop 在动画结束时到达，短暂缓冲后立即收回
            // ——v7 的 0.8s 太长，用户立刻退出直播页会看到镜像层跟着
            // 页面一起切出去（真机反馈）。
            softStopReset()
            channel.invokeMethod("onModeChanged",
                arguments: ["isInPipMode": false, "restored": true])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self else { return }
                self.mirrorConceal()
            }
            return
        }
        // 系统侧关闭（用户在小窗按关闭钮等）：与旧版一致，整段清理。
        finishEntry(false)
        cleanUp()
        channel.invokeMethod("onModeChanged",
            arguments: ["isInPipMode": false, "restored": restored, "closedByApp": closedByApp])
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        restoring = true
        // v4 问题"小窗关闭动画往左上角缩"的根因：收起动画以内容源 layer
        // 的当前位置为目标飞，而镜像层常态在窗口左上角 1px 离屏。恢复前
        // 先把它摆回直播页的视频区域，动画便飞向直播画面所在处。
        mirrorExpose()
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
        // v5：恒定无限区间（直播）。任何有限区间都会让系统按点播渲染
        // 进度条与 ±10 秒快进/快退按钮。
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        !playing
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

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
