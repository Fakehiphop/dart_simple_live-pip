import AVKit
import Accelerate
import Flutter
import UIKit

// v3：放弃 Kazumi PR #2646 的"退后台前切换软件渲染"前置步骤，改走
// PiliPlus（#3162，与本项目同构：media-kit 纹理帧 → AVSampleBufferDisplayLayer）
// 已验证的全程温热管线方案，同时保留 SwiftPeek（GPL-3.0）的帧泵纪律：
//   1. 全程不切换渲染器、不挂起视频轨：纹理 ID 恒定，帧镜像持续喂养
//      （未进小窗 4fps 低速保温，进小窗/进入中 30fps 全速）。PiliPlus 用
//      同构栈验证了这是后台自动画中画成立的充分条件；切换软件渲染会更换
//      纹理、断开管线，是进小窗 1 秒卡顿、后台拉不起与 -1001 残留的根源。
//   2. 回前台（didBecomeActive/didActivate）且画中画活跃时自动 stop
//      （enteredBackground 守卫，PiliPlus 同款），并根除残留会话导致的
//      AVKitErrorDomain -1001。
//   3. 退后台 2 秒系统仍未拉起则原生兜底显式 startPictureInPicture 一次
//      （Dart 侧另有 2.5 秒兜底，两条路径都有完整日志用于定案）。
//   4. 时基纪律：PTS 来自 controlTimebase，不与
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
        NSLog("SimpleLive PiP: didEnterBackground, autoStart=%@ possible=%@ active=%@ playing=%@ hasFrame=%@ src=%ld enq=%ld",
              pip.canStartPictureInPictureAutomaticallyFromInline ? "true" : "false",
              pip.isPictureInPicturePossible ? "true" : "false",
              pip.isPictureInPictureActive ? "true" : "false",
              playing ? "true" : "false",
              hasEnqueuedFrame ? "true" : "false",
              sourceFrames, enqueuedFrames)
        // 系统应在退后台瞬间自行拉起（canStart…FromInline + 温热帧管线）。
        // 给系统 2 秒；仍未拉起则原生兜底显式进入一次。
        backgroundAutoStartCheck?.cancel()
        guard autoStartArmed, !pip.isPictureInPictureActive, playing else { return }
        let check = DispatchWorkItem { [weak self] in
            guard let self = self, let pip = self.controller else { return }
            guard self.autoStartArmed, !pip.isPictureInPictureActive, !self.stopRequested else { return }
            NSLog("SimpleLive PiP: system auto start did not happen, fallback start issued (auto#fallback)")
            pip.startPictureInPicture()
        }
        backgroundAutoStartCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: check)
    }

    private func handleDidBecomeActive() {
        guard enteredBackground else { return }
        enteredBackground = false
        backgroundAutoStartCheck?.cancel()
        backgroundAutoStartCheck = nil
        guard let pip = controller else { return }
        // 回 app 自动关闭小窗（PiliPlus 同款），并顺带根除
        // "上一会话系统侧仍活跃"导致的 AVKitErrorDomain -1001。
        guard pip.isPictureInPictureActive else { return }
        NSLog("SimpleLive PiP: became active, stopPictureInPicture issued (auto stop on return)")
        stopRequested = true
        pip.stopPictureInPicture()
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
            videoView = view
            let content = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: view.displayLayer, playbackDelegate: self)
            let pip = AVPictureInPictureController(contentSource: content)
            pip.delegate = self
            pip.canStartPictureInPictureAutomaticallyFromInline = false
            controller = pip
            NSLog("SimpleLive PiP: session created")
        }
        textureId = id.int64Value
        updatePlaybackState(args)
        if let buffer = copyPixelBuffer?(id.int64Value) {
            onVideoFrame(buffer, textureId: id.int64Value)
        }
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
        if let rect = args["sourceRect"] as? [String: NSNumber] {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            videoView?.frame = CGRect(x: rect["left"]?.doubleValue ?? 0,
                                      y: rect["top"]?.doubleValue ?? 0,
                                      width: rect["width"]?.doubleValue ?? 0,
                                      height: rect["height"]?.doubleValue ?? 0)
            CATransaction.commit()
        }
        controller?.requiresLinearPlayback = duration <= 0
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

    private var hasDisplayableFrame: Bool {
        guard hasEnqueuedFrame, frameSize.width > 0, frameSize.height > 0,
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
        NSLog("SimpleLive PiP: will start (auto#@%@)", suspendOnStart ? "manual" : "system")
        channel.invokeMethod("onModeChanged", arguments: ["isInPipMode": true])
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
        cleanUp()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard controller === pictureInPictureController else { return }
        let restored = restoring
        let closedByApp = stopRequested
        stopRequested = false
        activeFeed = false
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
        // 直播是无限时间轴。有限区间会让小窗显示无意义的进度条。
        duration > 0
            ? CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 1000))
            : CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
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
