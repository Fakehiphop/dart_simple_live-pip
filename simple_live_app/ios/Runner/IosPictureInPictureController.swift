import AVKit
import Accelerate
import Flutter
import UIKit

// 基于 Kazumi PR #2646（sibogentleman）的 media-kit 帧拦截 + 软件渲染切换方案，
// 并吸收 SwiftPeek（GPL-3.0）验证过的自动启动路径：
//   1. 开播即建会话（attach），canStartPictureInPictureAutomaticallyFromInline
//      常开——退后台瞬间的自动启动由系统判定，武装链不能压在那几百毫秒里；
//   2. 层内有持续新鲜的帧（30fps 采样、960px 长边上限、控制时基纪律，
//      不与 kCMSampleAttachmentKey_DisplayImmediately 混用——AVFoundation
//      头文件明确不建议）；
//   3. 退后台前才切换软件渲染规避后台 GPU 提交限制，且该操作独立成步，
//      失败可观测。
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

    // 帧泵纪律（SwiftPeek PiPFramePump 设计）：
    // 直播采样 30fps 已足够（tunable），跳过的帧零拷贝开销。
    private static let frameInterval: Double = 1.0 / 30.0
    // 小窗物理尺寸有限，超采样是浪费；长边 960px。
    private static let maxLongEdge: Int = 960
    private var lastEnqueueAt = 0.0
    private var enqueuedFrames = 0
    private var sourceFrames = 0
    private var droppedFrames = 0
    private var lastStatsAt = 0.0

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "simple_live/ios_pip", binaryMessenger: messenger)
        super.init()
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { result(false); return }
            let args = call.arguments as? [String: Any] ?? [:]
            switch call.method {
            case "isSupported":
                result(AVPictureInPictureController.isPictureInPictureSupported())
            case "attach":
                self.attachSession(args, result: result)
            case "softwareRendering":
                self.switchToSoftwareRendering(args, result: result)
            case "updatePlaybackState":
                self.updatePlaybackState(args)
                result(nil)
            case "enter":
                self.enter(result)
            case "setAutoStartEnabled":
                // 退后台自动启动的唯一正规机制（Apple 文档契约）：
                // 后台时 startPictureInPicture() 不保证可用，须由系统在
                // 用户退后台瞬间自行拉起。
                let enabled = args["enabled"] as? Bool == true
                guard let controller = self.controller else {
                    NSLog("SimpleLive PiP: autoStart \(enabled) ignored, no session")
                    result(false)
                    return
                }
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
    /// 设计用于开播即调用（早武装）：前台期间硬件渲染的帧同样会经由
    /// 纹理拦截器到达本层，软件切换留给退后台前的独立步骤。
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

    /// 切换 mpv 输出到软件渲染（评论后台 GPU 提交限制）。
    /// 独立步骤：只应在退后台前调用；失败时记录，层内旧帧仍可维持
    /// 系统的自动启动判定。
    private func switchToSoftwareRendering(_ args: [String: Any], result: @escaping FlutterResult) {
        guard controller != nil else {
            NSLog("SimpleLive PiP: softwareRendering ignored, no session")
            result(false); return
        }
        guard let handle = args["handle"] as? NSNumber,
              let useSoftwareRendering = useSoftwareRendering else {
            NSLog("SimpleLive PiP: softwareRendering failed, no handle/renderer")
            result(false); return
        }
        let generation = sessionGeneration
        useSoftwareRendering(handle.int64Value) { [weak self] ready in
            guard let self = self, self.sessionGeneration == generation else { result(false); return }
            NSLog("SimpleLive PiP: softwareRendering %@", ready ? "ready" : "failed")
            result(ready)
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
        lastEnqueueAt = 0
        enqueuedFrames = 0
        sourceFrames = 0
        droppedFrames = 0
        lastStatsAt = 0
        // Dart 侧的输出回调要等进行中的渲染器替换（及前台恢复 vid）完成后才能失效。
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
        if lastEnqueueAt > 0, now - lastEnqueueAt < IosPictureInPictureController.frameInterval {
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
        finishEntry(false)
        cleanUp()
        channel.invokeMethod("onModeChanged", arguments: ["isInPipMode": false, "restored": restored])
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
