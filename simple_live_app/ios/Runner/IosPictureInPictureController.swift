import AVKit
import Accelerate
import Flutter
import UIKit

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
    private var suspendOnStart = false
    private var restoring = false
    private var textureId: Int64?
    private var lastSourceRect: CGRect?
    private var playing = false
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
            case "dispose":
                self.finishEntry(false)
                self.controller?.stopPictureInPicture()
                self.cleanUp { result(nil) }
            default:
                result(FlutterMethodNotImplemented)
            }
        }
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
        // 不做任何硬闯：合法路径只有系统自动启动（标志 + 帧）。
        // 若此处仍未武装，只记录观察日志，供真机定位。
        if !pip.canStartPictureInPictureAutomaticallyFromInline {
            NSLog("SimpleLive PiP: backgrounded without armed auto-start (no automatic PiP expected)")
        }
    }

    private func handleDidBecomeActive() {
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
        controller?.canStartPictureInPictureAutomaticallyFromInline = autoStartArmed && hasEnqueuedFrame
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
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              let id = args["textureId"] as? NSNumber,
              let window = Self.hostWindow() else { return false }

        if controller == nil {
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
        let oldTextureId = textureId
        if let id = args["textureId"] as? NSNumber { textureId = id.int64Value }
        playing = args["playing"] as? Bool ?? false
        duration = max(0, (args["durationMillis"] as? NSNumber)?.doubleValue ?? 0) / 1000
        let position = max(0, (args["positionMillis"] as? NSNumber)?.doubleValue ?? 0) / 1000
        let rate = (args["rate"] as? NSNumber)?.doubleValue ?? 1
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
        enteredBackground = false
        stopRequested = false
        lastEnqueueAt = 0
        enqueuedFrames = 0
        sourceFrames = 0
        droppedFrames = 0
        lastStatsAt = 0
        // 渲染后端全程恒定，无渲染器需要恢复。
        completion()
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
        guard width > 0, height > 0 else { droppedFrames += 1; return }
        let pixelFormat = CVPixelBufferGetPixelFormatType(source)
        guard pixelFormat == kCVPixelFormatType_32BGRA || pixelFormat == kCVPixelFormatType_32ARGB
        else { droppedFrames += 1; return }

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

        // 输出尺寸：长边上限 960；已知 PiP 实际 renderSize 时再压到它以内
        // （PiP 窗口多大就出多大，PiliPlus `copy()` 同款）。
        var scale = 1.0
        let longEdge = max(width, height)
        let maxLongEdge = IosPictureInPictureController.maxLongEdge
        if longEdge > maxLongEdge {
            scale = Double(maxLongEdge) / Double(longEdge)
        }
        let displayScale = videoView?.window?.screen.scale ?? UIScreen.main.scale
        if renderSize.width > 0, renderSize.height > 0 {
            let targetWidth = renderSize.width * displayScale
            let targetHeight = renderSize.height * displayScale
            let renderScale = max(targetWidth / Double(width), targetHeight / Double(height))
            if renderScale > 0, renderScale < scale {
                scale = renderScale
            }
        }
        let outWidth = max(1, Int((Double(width) * scale).rounded()))
        let outHeight = max(1, Int((Double(height) * scale).rounded()))
        let outSize = CGSize(width: outWidth, height: outHeight)
        if pixelBufferPool == nil || pixelBufferPoolSize != outSize {
            hasEnqueuedFrame = false
            layer.flushAndRemoveImage()
            pixelBufferPoolSize = outSize
            formatDescription = nil
            pixelBufferPool = nil
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: outWidth, kCVPixelBufferHeightKey: outHeight,
                kCVPixelBufferIOSurfacePropertiesKey: [:],
                // AVKit 消费的缓冲要能被 CoreVideo/CoreImage 直接接管。
                kCVPixelBufferMetalCompatibilityKey: true
            ]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pixelBufferPool)
        }
        guard let pool = pixelBufferPool else { return }
        var destination: CVPixelBuffer?
        let limits = [kCVPixelBufferPoolAllocationThresholdKey: 3] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault, pool, limits, &destination) == kCVReturnSuccess,
              let buffer = destination else { return }

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
        guard let format = formatDescription else { return }
        // 帧投递纪律（PiliPlus 同款）：mpv 已经按自己的节奏出帧，直接要求
        // 立即显示，不再用 controlTimebase 采样 PTS 做二次节流。
        var timing = CMSampleTimingInfo(duration: .invalid,
                                       presentationTimeStamp: timebase.map(CMTimebaseGetTime) ?? .zero,
                                       decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample = sample else { return }
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
        NSLog("SimpleLive PiP: frames source=%ld enqueued=%ld dropped=%ld, render %.0fx%.0f, layerStatus=%ld",
              sourceFrames, enqueuedFrames, droppedFrames,
              renderSize.width, renderSize.height,
              videoView?.displayLayer.status.rawValue ?? -1)
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
        NSLog("SimpleLive PiP: will start (%@)",
              suspendOnStart ? "manual + suspend" : "auto")
        channel.invokeMethod("onModeChanged", arguments: ["isInPipMode": true])
        // 渲染后端恒定：此处不再切换软件渲染。
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
        // 自动路径的启动失败一律保留会话（软失败）：会话是常驻温热的，
        // 拆掉它只会让系统重新"喂熟"一遍，更糟。
        if autoStartArmed {
            activeFeed = false
            suspendOnStart = false
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

    /// PiP 窗口尺寸变化 → 记下实际 renderSize（PiliPlus `didTransitionToRenderSize`）。
    /// 输出尺寸据此压缩，避免超采样；同时立刻补一帧让新窗口有画面。
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        renderSize = CGSize(width: Int(newRenderSize.width), height: Int(newRenderSize.height))
        lastEnqueueAt = 0
        layoutVideoView()
        if let id = textureId, let buffer = copyPixelBuffer?(id) {
            onVideoFrame(buffer, textureId: id)
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
