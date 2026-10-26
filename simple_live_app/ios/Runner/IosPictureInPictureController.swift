import AVKit
import Accelerate
import Flutter
import UIKit

// v4：帧源回到 Kazumi PR #2646 已真机验证的事件驱动路线，修掉 v3 三条病根：
//   1. 帧由 media-kit 的 textureFrameAvailable 回调驱动（渲一帧拷一帧），
//      不再常驻 CADisplayLink 泵——v3 的泵在退后台后停摆导致小窗冻在
//      最后一帧，前台空转导致进直播间卡顿（dropped=130 的来源）。
//      进入小窗前先把渲染器切到软件输出（Kazumi 同序列）：软件渲染在
//      后台持续产帧且产生新纹理，本控制器对新纹理 ID 自动重接。
//   2. 镜像层改为会话期 addSubview 正常上屏（Kazumi 同款），退出即移除。
//      v3 的 insertSubview(at:0) 埋进根视图底层，打乱 Flutter 叠层 z 序
//      （控制菜单被直播画面挡住的来源），也让系统自动拉起永远不触发。
//   3. v4 在 inactive（仍在前台）瞬间显式走手动进入同序列：attach→软件渲染→
//      startPictureInPicture + suspend，该序列已真机验证"秒进不卡"。
//   保留 v3的有效部分：回前台自动 stop（enteredBackground 守卫防回环）、
//   时基纪律（PTS 来自 controlTimebase，不用 DisplayImmediately）、
//   960px 长边上限、vImage CPU 缩放、有界缓冲池、全链日志。
//
// v5（v4 真机日志 20261026_205224 的三处修正）：
//   a. suspend 从"发出 start 之后立刻执行"移到 will start 回调里——start
//      被系统接受后再挂起应用。v4 日志中 4 次 -1001 失败的场景：挂起与启动
//      赛跑，场景先离屏导致 AVKit 拒绝启动。移位后失败时应用仍在前台，
//      补上 -1001 的 0.3s 重试（最多 2 次）。
//   b. 开启 canStartPictureInPictureAutomaticallyFromInline（经
//      setAutoStartEnabled 由 Dart 按设置项控制）：镜像层已真实上屏，
//      上滑回桌面时由系统直接拉起，与 inactive 显式进入互为双保险。
//      v3 时代它从未触发是埋层问题，不是开关问题。
//   c. 直播 timeRange：Dart 侧恒报 duration=0，系统小窗按直播样式渲染
//      （无进度条、无快进 10s）。
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
    private var startRetryCount = 0
    private var restoring = false
    private var textureId: Int64?
    private var playing = false
    private var duration: Double = 0
    private var timebase: CMTimebase?
    private var pixelBufferPool: CVPixelBufferPool?
    private var formatDescription: CMVideoFormatDescription?
    private var frameSize = CGSize.zero

    // 软件渲染切换后帧率有限，且切渲染器会产生新纹理：主动取一次首帧
    // （入场观测会追踪后续帧）。进小窗/进入中不节流——事件源本身是
    // media-kit 的渲染节拍，比小窗需要的高。
    private static let idleFrameInterval: Double = 0.25
    // 小窗物理尺寸有限，超采样是浪费；长边 960px。
    private static let maxLongEdge: Int = 960
    private var activeFeed = false
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
                self.setSoftwareRendering(args, result: result)
            case "updatePlaybackState":
                self.updatePlaybackState(args)
                result(nil)
            case "enter":
                self.enter(result)
            case "setAutoStartEnabled":
                // v5：系统自动拉起重新启用（镜像层已真实上屏，v3 时代它
                // 从未触发是埋层问题）。由 Dart 按设置项与直播状态控制。
                autoStartArmed = args["enabled"] as? Bool == true
                controller?.canStartPictureInPictureAutomaticallyFromInline = autoStartArmed
                NSLog("SimpleLive PiP: autoStart %@", autoStartArmed ? "arm" : "disarm")
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

    /// 建立画中画会话（内容源 + delegate + 时基）。会话期镜像层正常上屏
    /// （addSubview），退出时移除——不再常驻埋底污染 Flutter 叠层。
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
    /// 回前台自动 stop（修"回 app 小窗还在"）。
    private func registerLifecycleObservers() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.handleDidEnterBackground() }
        // PiP 启动/停止也会广播前台场景通知，所以
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
        NSLog("SimpleLive PiP: didEnterBackground, active=%@ playing=%@ hasFrame=%@ src=%ld enq=%ld",
              pip.isPictureInPictureActive ? "true" : "false",
              playing ? "true" : "false",
              hasEnqueuedFrame ? "true" : "false",
              sourceFrames, enqueuedFrames)
        // v4：启动要么在 inactive 已完成（显式序列），要么由系统侧接管；
        // didEnterBackground 不再发兜底 start（后台时该调用不保证可用）。
    }

    private func handleDidBecomeActive() {
        guard enteredBackground else { return }
        enteredBackground = false
        guard let pip = controller else { return }
        // 回 app 自动关闭小窗，并顺带根除
        // "上一会话系统侧仍活跃"导致的 AVKitErrorDomain -1001。
        guard pip.isPictureInPictureActive else { return }
        NSLog("SimpleLive PiP: became active, stopPictureInPicture issued (auto stop on return)")
        stopRequested = true
        pip.stopPictureInPicture()
    }

    /// 进入前切换软件渲染（Kazumi 同序列）。后台产帧依赖软件输出；
    /// 切换产生新纹理 ID，updatePlaybackState 会自动重接帧源。
    /// 已在软件渲染中（softwareRenderingHandles 非空经 Dart 侧判断）或
    /// 无播放句柄时直接成功，保证幂等。
    private func setSoftwareRendering(_ args: [String: Any], result: @escaping FlutterResult) {
        let enable = args["enabled"] as? Bool == true
        let handle = (args["handle"] as? NSNumber)?.int64Value
        guard enable else {
            // 恢复 GL 只能经 restoreRendering（cleanUp 内），这里无法逐句柄恢复。
            NSLog("SimpleLive PiP: softwareRendering enable=false ignored")
            result(true)
            return
        }
        guard let handle = handle else {
            NSLog("SimpleLive PiP: softwareRendering enable=true missing handle")
            result(false)
            return
        }
        guard let useSoftwareRendering = useSoftwareRendering else {
            NSLog("SimpleLive PiP: softwareRendering unavailable (no registry)")
            result(false)
            return
        }
        NSLog("SimpleLive PiP: softwareRendering begin handle=%lld", handle)
        useSoftwareRendering(handle) { [weak self] switched in
            guard let self = self else { result(false); return }
            if !switched {
                NSLog("SimpleLive PiP: softwareRendering failed")
                result(false)
                return
            }
            // 新纹理 ID 已由 Dart 侧经 updatePlaybackState 上报；
            // 这里主动取一次首帧，避免暂停态下无人喂帧。
            if let id = self.textureId, let buffer = self.copyPixelBuffer?(id) {
                self.onVideoFrame(buffer, textureId: id)
            }
            NSLog("SimpleLive PiP: softwareRendering done")
            result(true)
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
            // 会话期正常上屏（Kazumi 同款）；frame 缩到屏幕外 1px 角，
            // 应用内不可见，但层"真实上屏"，AVKit 消费内容源无障碍——
            // v3 埋根视图底层同时破坏了这两点。
            view.frame = CGRect(x: -2, y: -2, width: 1, height: 1)
            view.alpha = 0.01
            rootView.addSubview(view)
            videoView = view
            let content = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: view.displayLayer, playbackDelegate: self)
            let pip = AVPictureInPictureController(contentSource: content)
            pip.delegate = self
            pip.canStartPictureInPictureAutomaticallyFromInline = autoStartArmed
            controller = pip
            NSLog("SimpleLive PiP: session created")
        }
        let oldTextureId = textureId
        textureId = id.int64Value
        updatePlaybackState(args)
        if oldTextureId != textureId, let buffer = copyPixelBuffer?(textureId!) {
            onVideoFrame(buffer, textureId: textureId!)
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
        // 镜像层保持屏幕外 1px 窗，无需跟随 sourceRect（v3 用它当内联位置，
        // v4 层永远不可见，只在 PiP 内显示）。
        controller?.requiresLinearPlayback = duration <= 0
        controller?.invalidatePlaybackState()
        // 软件渲染等输出替换会产生新纹理 ID。暂停状态下可能只渲染一帧，
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
        // 启动调用一发出就退桌面，让小窗动画与桌面动画几乎同时
        // （启动调用本身已把小窗交给系统管理，随后退后台不影响它）。
        // 手动与 inactive 自动路径共用该序列（真机已验证"秒进不卡"）。
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
        // v5：suspend 移到 will start 回调（系统接受启动后再挂起）。
        // v4 在发出 start 后立刻挂起，上滑场景里场景离屏与启动赛跑，
        // 日志 4 次 -1001 失败皆源于此。
        NSLog("SimpleLive PiP: startPictureInPicture issued")
        pip.startPictureInPicture()
    }

    /// -1001（AVKitErrorDomain：系统判定当前起点无法开始画中画）短暂重试：
    /// 失败时应用仍在前台（suspend 已移到 will start 之后再挂起），
    /// 内容全部就绪（possible=true hasFrame=true）时再试一次即可通过。
    private func retryStartAfterFailure() {
        guard entryResult != nil, startRetryCount < 2,
              controller != nil, enteredBackground == false else { return }
        startRetryCount += 1
        startRequested = false
        NSLog("SimpleLive PiP: retry start (%ld/2) after -1001", startRetryCount)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.startIfPossible()
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
        startRetryCount = 0
        suspendOnStart = false
        activeFeed = false
        lastEnqueueAt = 0
        enqueuedFrames = 0
        sourceFrames = 0
        droppedFrames = 0
        lastStatsAt = 0
        // 退出小窗后恢复 GL 渲染（若进小窗走过软件渲染）。
        if let restoreRendering = restoreRendering {
            restoreRendering(completion)
        } else {
            completion()
        }
    }

    /// 帧入口：由 PipTextureRegistry.textureFrameAvailable（media-kit 渲一帧
    /// 调一次）以及软件渲染切换后主动取的首帧驱动。无计时器、无轮询。
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
        // 未进小窗时轻节流：拷贝跟随 media-kit 渲染节拍，这里只压前台
        // 重复拷贝的开销。进小窗/进入中不节流（事件源天然有背压：
        // isReadyForMoreMediaData 为 false 时即被丢弃）。
        let now = CACurrentMediaTime()
        if !activeFeed && entryResult == nil,
           lastEnqueueAt > 0, now - lastEnqueueAt < IosPictureInPictureController.idleFrameInterval {
            droppedFrames += 1
            return
        }
        lastEnqueueAt = now
        sourceFrames += 1

        // 输出上限：小窗物理尺寸就那么大，超采样是浪费（长边 960px）。
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

        // media-kit 的后备缓冲区被无引用计数复用；拷进有上界的缓冲池，
        // 保证 AVKit 读到的帧不会被覆盖。
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
                // vImage（CPU，NEON）：缩放与后台合成一律走 CPU。
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
        // 时基纪律：PTS 来自 controlTimebase（与主时钟同步），不附加
        // DisplayImmediately（附件与时基混用为 AVFoundation 头文件明确不建议）。
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
        activeFeed = true
        NSLog("SimpleLive PiP: will start (auto#system)" + (suspendOnStart ? " + suspend" : ""))
        if suspendOnStart {
            // v5：启动已被系统接受，此刻挂起应用让小窗动画与桌面动画衔接。
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.textureId != nil else { return }
                UIApplication.shared.perform(NSSelectorFromString("suspend"))
            }
        }
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
        // 内容就绪（possible/hasFrame/layer 全 OK）却收到 -1001：
        // 启动与场景离屏赛跑的瞬时竞态，短暂重试；其余错误照常收场。
        if failure.domain == "AVKitErrorDomain", failure.code == -1001 {
            retryStartAfterFailure()
            return
        }
        finishEntry(false, error: FlutterError(code: "pip_start_failed",
            message: "\(failure.domain) (\(failure.code))", details: details))
        // 失败即恢复 GL：本次尝试到此为止，不留软件渲染空转。
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
