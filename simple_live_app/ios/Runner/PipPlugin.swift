import AVKit
import Accelerate
import Flutter
import UIKit

// The tracked `FlutterTexture` is media_kit_video's `SafeResizableTexture`,
// whose `render(_:)` is a Swift-only requirement (`ResizableTextureProtocol`),
// so it is not reachable through the Objective-C runtime.
#if canImport(media_kit_video)
  import media_kit_video
#endif

/// Picture-in-Picture for the video texture rendered by media_kit (mpv).
///
/// mpv renders into `CVPixelBuffer`s owned by a `FlutterTexture` that is
/// private to media_kit_video, so the engine's texture registry is hooked to
/// map texture ids to textures and to get notified of new frames. Frames of the
/// tracked texture are copied and fed to an `AVSampleBufferDisplayLayer`, which
/// is used as the PiP content source (iOS 15+).
///
/// Ported from PiliPlus (GPL-3.0) `ios/Runner/PipPlugin.swift`.
final class PipPlugin: NSObject, FlutterPlugin {
  private static let channelName = "simple_live/ios_pip"

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    let instance = PipPlugin(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
    TextureTracker.install(on: registrar.textures())
  }

  private let channel: FlutterMethodChannel
  private var _session: AnyObject?

  @available(iOS 15.0, *)
  private var session: PipSession? {
    get { _session as? PipSession }
    set { _session = newValue }
  }

  private init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
    TextureTracker.onFrameAvailable = { [weak self] textureId in
      guard #available(iOS 15.0, *), let session = self?.session,
        session.textureId == textureId
      else { return }
      session.frameAvailable()
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard #available(iOS 15.0, *) else {
      result(call.method == "isAvailable" ? false : nil)
      return
    }
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "isAvailable":
      result(AVPictureInPictureController.isPictureInPictureSupported())
    case "enter":
      guard let textureId = (args["textureId"] as? NSNumber)?.int64Value else {
        result(FlutterError(code: "ARGS", message: "textureId is required", details: nil))
        return
      }
      let session: PipSession
      if let current = self.session, current.textureId == textureId {
        session = current
      } else {
        tearDown()
        session = PipSession(textureId: textureId) { [weak self] method, arguments in
          self?.channel.invokeMethod(method, arguments: arguments)
        }
        session.onStop = { [weak self, weak session] in
          // Keep the session alive while armed for auto-enter.
          guard let self, let session, self.session === session,
            !session.autoEnter
          else { return }
          self.tearDown()
        }
        self.session = session
      }
      session.configure(
        width: (args["width"] as? NSNumber)?.doubleValue ?? 16,
        height: (args["height"] as? NSNumber)?.doubleValue ?? 9
      )
      session.update(args)
      if args["autoEnter"] as? Bool == true {
        session.autoEnter = true
      } else {
        session.start()
      }
      result(nil)
    case "update":
      session?.update(args)
      result(nil)
    case "disableAutoEnter":
      if let session {
        session.autoEnter = false
        if !session.isActive {
          tearDown()
        }
      }
      result(nil)
    case "dispose":
      tearDown()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  @available(iOS 15.0, *)
  private func tearDown() {
    session?.invalidate()
    session = nil
  }
}

// MARK: - Session

@available(iOS 15.0, *)
private final class PipSession: NSObject {
  /// Upper bound of the longest side of the frames sent to PiP.
  ///
  /// The PiP window is physically small, so anything above this is wasted CPU
  /// and memory on the per-frame copy. Matches SwiftPeek's compositor, which
  /// caps its output at 960 as well.
  private static let maxDimension = 960.0
  /// Frame interval used while armed for auto-enter but not yet in PiP.
  private static let idleFrameInterval = 0.25

  let textureId: Int64
  var onStop: (() -> Void)?
  private(set) var isActive = false

  var autoEnter = false {
    didSet { updateAutoEnter() }
  }

  private let sendEvent: (String, Any?) -> Void
  private let sourceView: SampleBufferView
  private let displayLayer: AVSampleBufferDisplayLayer
  private let timebase: CMTimebase
  private var controller: AVPictureInPictureController!
  private var possibleObservation: NSKeyValueObservation?
  private var observers: [NSObjectProtocol] = []
  private var enteredBackground = false

  private var isPlaying = false
  /// Defaults to a live stream: this plugin is only used from the live room, and
  /// treating it as on-demand would make the window draw a scrubber.
  private var isLive = true
  private var speed = 1.0
  private var duration = CMTime.zero
  private var pendingStart = false
  private var stopRequested = false
  private var restoring = false
  /// Whether to leave the app once PiP has started, see `start()`.
  private var backgroundOnStart = false
  private var frameInFlight = false
  private var lastFrameTime: CFTimeInterval = 0
  /// Whether a frame has been enqueued, PiP shows a black window otherwise.
  private var hasFrame = false
  /// Timer pulling frames while PiP is visible, see `startPump()`.
  /// Main thread only.
  private var pump: DispatchSourceTimer?
  /// The tracked texture, resolved on the main thread because `TextureTracker`
  /// is main-thread only, then read by the pump. Guarded by `pushLock`.
  private var trackedTexture: FlutterTexture?
  /// Size media_kit renders at, taken from the last copied frame.
  /// Guarded by `pushLock`.
  private var lastFrameSize = CGSize.zero
  /// Last time media_kit itself delivered a frame. Guarded by `pushLock`.
  private var lastNotifyTime: CFTimeInterval = 0
  /// Whether playback was paused from the PiP window.
  private var isPausedByUser = false

  /// Counters reported every 5 s, so a remaining problem can be diagnosed from
  /// the device log instead of guessed at. Accessed on `pumpQueue` only.
  private var diagnostics = Diagnostics()
  // Accessed on `pumpQueue` only.
  private let pumpQueue = DispatchQueue(label: "com.simplelive.pip.pump")
  // Guards `frameInFlight`, which is touched by both the main thread and the
  // pump.
  private let pushLock = NSLock()
  /// The timebase anchor, exactly as SwiftPeek's `PiPFramePump` keeps it:
  /// `anchorMediaTime` is expressed in the layer's timeline, `anchorHostTime` in
  /// `CACurrentMediaTime()`. `makeSampleBuffer` derives every frame timestamp
  /// from this pair, and `pumpTick` anchors the control timebase to the same
  /// pair, so the two can never drift apart. `pumpQueue` only.
  private var mediaAnchor = CMTime.zero
  private var anchorHostTime: TimeInterval = 0
  private var anchorRate: Double = 1
  /// Base address of the surface last handed to the layer, used to skip a frame
  /// that mpv did not actually replace. Guarded by `pushLock`.
  private var lastPushedBuffer: UnsafeMutableRawPointer?
  /// Invalidates in-flight composition work, see `stopPump()`. Guarded by
  /// `pushLock`.
  private var generation = 0
  private var pool: CVPixelBufferPool?
  private var poolSize = CGSize.zero
  private var formatDescription: CMVideoFormatDescription?

  init(textureId: Int64, sendEvent: @escaping (String, Any?) -> Void) {
    let sourceView = SampleBufferView()
    let displayLayer = sourceView.layer as! AVSampleBufferDisplayLayer
    displayLayer.videoGravity = .resizeAspect
    var timebase: CMTimebase?
    CMTimebaseCreateWithSourceClock(
      allocator: kCFAllocatorDefault,
      sourceClock: CMClockGetHostTimeClock(),
      timebaseOut: &timebase
    )
    // Left at rate 0. Frames are enqueued with `DisplayImmediately` and paced by
    // the pump, so the layer is not asked to schedule anything against this
    // timebase; it only backs the PiP window's playback state. Driving it as
    // well (as an earlier version did) puts two schedulers on the same queue and
    // the layer redisplays whichever frame loses the race.
    displayLayer.controlTimebase = timebase

    self.textureId = textureId
    self.sendEvent = sendEvent
    self.sourceView = sourceView
    self.displayLayer = displayLayer
    self.timebase = timebase!
    super.init()

    controller = AVPictureInPictureController(
      contentSource: .init(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
    )
    controller.delegate = self
    controller.canStartPictureInPictureAutomaticallyFromInline = false
    possibleObservation = controller.observe(\.isPictureInPicturePossible) {
      [weak self] _, _ in
      DispatchQueue.main.async { self?.startIfPending() }
    }
    // The video is shown inline again once the app is back in the foreground.
    // Starting PiP also posts foreground notifications, and stopping it is
    // ignored until the scene is active, hence `didActivate` after background.
    observers = [
      NotificationCenter.default.addObserver(
        forName: UIScene.didEnterBackgroundNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        // Also posted while active when PiP stops.
        if UIApplication.shared.applicationState == .background {
          self?.enteredBackground = true
        }
      },
      NotificationCenter.default.addObserver(
        forName: UIScene.didActivateNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        guard let self, self.enteredBackground else { return }
        self.enteredBackground = false
        if self.controller.isPictureInPictureActive {
          self.stopRequested = true
          self.controller.stopPictureInPicture()
        }
      },
    ]
  }

  /// Places the (hidden) source layer where the player usually is, so the
  /// system's start/stop animation roughly matches the inline video.
  func configure(width: Double, height: Double) {
    guard let window = Self.hostWindow() else { return }
    if sourceView.superview !== window {
      // Below the Flutter view: it must be in the window, but not visible.
      window.insertSubview(sourceView, at: 0)
    }
    let aspectRatio = width > 0 && height > 0 ? width / height : 16 / 9
    let bounds = window.bounds
    var size = CGSize(width: bounds.width, height: bounds.width / aspectRatio)
    if size.height > bounds.height {
      size = CGSize(width: bounds.height * aspectRatio, height: bounds.height)
    }
    let y =
      bounds.height > bounds.width
      ? window.safeAreaInsets.top : (bounds.height - size.height) / 2
    sourceView.frame = CGRect(
      x: (bounds.width - size.width) / 2,
      y: y,
      width: size.width,
      height: size.height
    )
    frameAvailable(force: true)
  }

  func update(_ args: [String: Any]) {
    if let value = args["isPlaying"] as? Bool { isPlaying = value }
    if let value = args["isLive"] as? Bool { isLive = value }
    if let value = (args["duration"] as? NSNumber)?.int64Value {
      duration = CMTime(value: value, timescale: 1000)
    }
    if let value = (args["speed"] as? NSNumber)?.doubleValue { speed = value }
    let isBuffering = args["isBuffering"] as? Bool ?? false
    // Dart-side state only decides whether frames are pushed at all. The layer
    // is not scheduled against the control timebase (frames carry
    // `DisplayImmediately`), so nothing here drives it while `isLive`. Live
    // `position` is not used either: it jumps backwards whenever the buffer
    // refills, and anchoring to it drags the timeline back under frames that are
    // already queued.
    pushLock.lock()
    isPausedByUser = isLive ? !isPlaying : false
    pushLock.unlock()
    if !isLive, let position = (args["position"] as? NSNumber)?.int64Value {
      // On-demand content has a real timeline, the reported position is exact.
      CMTimebaseSetRateAndAnchorTime(
        timebase,
        rate: isPlaying && !isBuffering ? speed : 0,
        anchorTime: CMTime(value: position, timescale: 1000),
        immediateSourceTime: CMClockGetTime(CMClockGetHostTimeClock())
      )
    }
    controller.invalidatePlaybackState()
  }

  /// Enters PiP and then leaves the app, so that the video only plays in the
  /// PiP window, as on Android where the whole activity becomes the window.
  func start() {
    guard !controller.isPictureInPictureActive else { return }
    pendingStart = true
    backgroundOnStart = true
    startIfPending()
    // Give up if PiP doesn't become possible shortly, so a stale request
    // doesn't start PiP unexpectedly later.
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
      guard let self, self.pendingStart else { return }
      self.pendingStart = false
      self.backgroundOnStart = false
      self.sendEvent("onStateChanged", ["active": false, "error": "PiP is not possible"])
      self.onStop?()
    }
  }

  private func startIfPending() {
    guard pendingStart, hasFrame, controller.isPictureInPicturePossible else { return }
    pendingStart = false
    controller.startPictureInPicture()
  }

  private func updateAutoEnter() {
    // AVKit may start PiP as soon as the app goes to background.
    controller.canStartPictureInPictureAutomaticallyFromInline = autoEnter && hasFrame
  }

  func invalidate() {
    pendingStart = false
    stopPump()
    possibleObservation?.invalidate()
    observers.forEach(NotificationCenter.default.removeObserver)
    controller.delegate = nil
    if controller.isPictureInPictureActive {
      controller.stopPictureInPicture()
    }
    if isActive {
      isActive = false
      sendEvent("onStateChanged", ["active": false])
    }
    // The content source retains its playback delegate (`self`).
    controller.contentSource = nil
    sourceView.removeFromSuperview()
  }

  // MARK: Frames

  /// Must be called on the main thread.
  func frameAvailable(force: Bool = false) {
    let now = CACurrentMediaTime()
    if !force && !isActive && now - lastFrameTime < Self.idleFrameInterval {
      return
    }
    // `TextureTracker` is main-thread only, so the texture is resolved here and
    // handed to the pump. Kept when the lookup fails, the registry may drop it
    // for a frame while the engine re-registers.
    pushLock.lock()
    if let texture = TextureTracker.texture(for: textureId) {
      trackedTexture = texture
    }
    lastNotifyTime = CACurrentMediaTime()
    let unwound = anchorHostTime == 0
    if unwound {
      // Before PiP starts there is no pump yet, and the anchor has never been
      // set. Establish it here so the very first frame already carries a sane
      // timestamp instead of one anchored at host time 0.
      anchorHostTime = now
      anchorRate = isPlaying ? speed : 1
    }
    pushLock.unlock()
    // While PiP is visible the pump is the only enqueuer. Letting this path push
    // too would interleave two threads into the display layer, and the frame
    // timestamps taken on them can arrive out of order, which shows up as the
    // picture flipping between a couple of frames.
    guard !isActive else { return }
    pushFrame(hostTime: now)
  }

  /// Copies the current texture content into the display layer.
  ///
  /// Runs on any thread, but never on the main thread while PiP is up. The copy
  /// and the enqueue happen synchronously, before the source surface can be
  /// recycled, see the note in the body.
  ///
  /// - Parameter hostTime: when the caller observed the frame. Together with
  ///   `mediaAnchor` it is what the PTS is derived from, exactly like
  ///   SwiftPeek's `PiPFramePump.Input`.
  private func pushFrame(hostTime: TimeInterval? = nil) {
    pushLock.lock()
    if frameInFlight {
      pushLock.unlock()
      return
    }
    let texture = trackedTexture
    let token = generation
    frameInFlight = true
    pushLock.unlock()

    guard let texture,
      let source = texture.copyPixelBuffer()?.takeRetainedValue()
    else {
      // Nothing rendered yet: `TextureHW`/`TextureSW` keep `current` nil until
      // `render(_:)` produced a buffer. Retried by the pump.
      diagnostics.noteEmptyCopy()
      pushLock.lock()
      frameInFlight = false
      pushLock.unlock()
      return
    }
    let now = hostTime ?? CACurrentMediaTime()
    lastFrameTime = now
    // `copyPixelBuffer()` hands back whatever `render(_:)` last wrote, and keeps
    // handing back the same surface until the next render produces a new one.
    // `render(_:)` itself is a no-op when the swappable pool has no free context
    // (`TextureSW.swift:103-106`), and mpv produces nothing while it is buffering
    // or paused. Pushing that unchanged surface again would re-present a frame
    // the user has already seen, so only forward surfaces that differ from the
    // one sent last. The pool rotates three contexts, so consecutive real frames
    // are always distinct and none is dropped.
    let identity = CVPixelBufferGetBaseAddress(source)
    pushLock.lock()
    let repeated = identity != nil && lastPushedBuffer == identity
    if !repeated {
      lastPushedBuffer = identity
    }
    pushLock.unlock()
    if repeated {
      diagnostics.noteRepeated()
      pushLock.lock()
      frameInFlight = false
      pushLock.unlock()
      return
    }
    // The buffer is allocated at media_kit's render size, which is what
    // `render(_:)` must be called with.
    let renderSizeHint = CGSize(
      width: Double(CVPixelBufferGetWidth(source)),
      height: Double(CVPixelBufferGetHeight(source))
    )
    pushLock.lock()
    lastFrameSize = renderSizeHint
    pushLock.unlock()
    // The source buffer is reused by mpv a few frames later, so it is copied
    // (and downscaled if needed) instead of being handed to the layer as is.
    // The copy runs synchronously: media_kit rotates only three buffers, and the
    // one `copyPixelBuffer()` returned goes back into the write pool after as
    // little as one more `render(_:)`. Reading it on a later queue hop would
    // sometimes catch a surface that is already being rewritten, which shows up
    // as the frame tearing between two pictures. While PiP is up this runs on
    // the pump queue, never on the main thread.
    var enqueued = false
    if let copy = copy(source), let sampleBuffer = makeSampleBuffer(copy, hostTime: now) {
      diagnostics.noteFresh()
      // The window may have been closed while this frame was being composed:
      // `stopPump()` bumps the generation for exactly this reason.
      pushLock.lock()
      let current = generation == token
      pushLock.unlock()
      if current {
        enqueued = enqueue(sampleBuffer)
      }
      if enqueued {
        diagnostics.noteEnqueued()
      } else {
        diagnostics.noteRejected()
      }
    }
    pushLock.lock()
    frameInFlight = false
    pushLock.unlock()
    // Only `hasFrame` and the PiP start are main-thread state.
    if enqueued && !hasFrame {
      DispatchQueue.main.async { [weak self] in
        guard let self, !self.hasFrame else { return }
        self.hasFrame = true
        self.updateAutoEnter()
        self.startIfPending()
      }
    }
  }

  // MARK: Pump

  /// Pulls frames while PiP is visible, independently of the texture registry
  /// notification.
  ///
  /// While the app is in the background iOS throttles the Flutter engine, so
  /// media_kit's `VideoOutput._updateCallback()` stops being scheduled and
  /// `textureFrameAvailable:` is no longer posted. That callback is the only
  /// thing that calls `render(_:)`, which in turn is the only writer of the
  /// pixel buffer handed out by `copyPixelBuffer()` — hence the PiP window
  /// freezing on the last frame rendered before backgrounding while audio keeps
  /// playing. The pump renders and pushes on its own, so PiP keeps updating.
  private func startPump() {
    guard pump == nil else { return }
    pushLock.lock()
    // Bumping the generation invalidates any frame that is still being composed
    // on `pumpQueue` from a previous session.
    generation += 1
    pushLock.unlock()
    let timer = DispatchSource.makeTimerSource(queue: pumpQueue)
    // ~30 fps, leeway lets the system coalesce the wake ups.
    timer.schedule(
      deadline: .now(),
      repeating: .milliseconds(33),
      leeway: .milliseconds(8)
    )
    timer.setEventHandler { [weak self] in
      self?.pumpTick()
    }
    pump = timer
    timer.resume()
  }

  private func stopPump() {
    pump?.setEventHandler {}
    pump?.cancel()
    pump = nil
    pushLock.lock()
    // Late work must not reach the layer once the window is gone, see
    // `SwiftPeek`'s `generation` latch in `PiPFramePump`.
    generation += 1
    lastPushedBuffer = nil
    frameInFlight = false
    pushLock.unlock()
  }

  /// Runs on `pumpQueue`, one tick at a time. Sole enqueuer while PiP is up.
  private func pumpTick() {
    let now = CACurrentMediaTime()
    guard isActive else { return }
    pushLock.lock()
    let busy = frameInFlight
    let texture = trackedTexture
    let size = lastFrameSize
    let mediaKitStalled = now - lastNotifyTime > 0.2
    let shouldRender = !isPausedByUser
    let rate = isPlaying ? speed : 0
    pushLock.unlock()

    guard !busy, let texture else { return }
    // Paused from the PiP window: the layer keeps showing the last frame, which
    // is what a paused live stream should look like.
    guard shouldRender else { return }

    diagnostics.tick(at: now)
    // Anchor the timeline once, then leave it alone. `mediaAnchor` starts at
    // zero because a live stream has no seekable origin; what matters is that
    // the timebase and the frame timestamps are derived from the same pair, which
    // is what SwiftPeek's pump does.
    anchorRate = rate
    CMTimebaseSetRateAndAnchorTime(
      timebase,
      rate: rate,
      anchorTime: mediaAnchor,
      immediateSourceTime: CMTime(seconds: anchorHostTime, preferredTimescale: 600)
    )
    // Force mpv to produce a frame once media_kit stopped scheduling its own
    // render: `render(_:)` is what advances the buffer that
    // `copyPixelBuffer()` returns, and with the libmpv render API mpv only
    // advances video when the client renders. `SafeResizableTexture.render(_:)`
    // takes the same recursive lock media_kit's worker holds, so the two never
    // render at once. While media_kit still notifies there is nothing to force.
    if mediaKitStalled {
      #if canImport(media_kit_video)
        if let resizable = texture as? ResizableTextureProtocol,
          size.width > 0, size.height > 0
        {
          resizable.render(size)
          diagnostics.forcedRender += 1
        }
      #endif
    }
    pushFrame(hostTime: now)
  }

  private func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
    let sourceWidth = Double(CVPixelBufferGetWidth(source))
    let sourceHeight = Double(CVPixelBufferGetHeight(source))
    guard sourceWidth > 0, sourceHeight > 0 else { return nil }
    let scale = min(1, Self.maxDimension / max(sourceWidth, sourceHeight))
    // The output size is derived from the source resolution only. `videoGravity`
    // fits it into the window, so nothing here has to track the window size —
    // and rebuilding the pool on window changes used to invalidate the cached
    // format description and flush the layer, dropping a frame each time.
    let size = CGSize(
      width: max(2, ((sourceWidth * scale) / 2).rounded(.down) * 2),
      height: max(2, ((sourceHeight * scale) / 2).rounded(.down) * 2)
    )

    if pool == nil || poolSize != size {
      pool = nil
      poolSize = size
      let attributes: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey: Int(size.width),
        kCVPixelBufferHeightKey: Int(size.height),
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferMetalCompatibilityKey: true,
      ]
      CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
    }
    guard let pool else { return nil }

    // The layer keeps the buffers it is displaying. Without an allocation
    // threshold the pool hands back one of those surfaces, so the layer ends up
    // showing a buffer that is being overwritten and the picture tears between
    // two surfaces. With a threshold the pool reports exhaustion instead and the
    // frame is dropped, which is correct for live. Six is SwiftPeek's budget.
    var output: CVPixelBuffer?
    let limits = [kCVPixelBufferPoolAllocationThresholdKey: 6] as CFDictionary
    guard
      CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
        nil, pool, limits, &output
      ) == kCVReturnSuccess, let output
    else { return nil }

    // CPU-only scaling. `CIContext` renders through Metal by default, and iOS
    // denies application Metal work once the app is in the background — which is
    // exactly when PiP is visible. The render then either fails silently or
    // leaves the destination partially updated, so the layer keeps re-showing a
    // half-written surface: the "last frame shaking" symptom. (Ref. SwiftPeek
    // `PiPPixelTransfer`, which is CPU-only for this reason.)
    guard PiPPixelTransfer.copy(source, to: output) else { return nil }
    return output
  }

  private func makeSampleBuffer(
    _ pixelBuffer: CVPixelBuffer,
    hostTime: TimeInterval
  ) -> CMSampleBuffer? {
    let matches =
      formatDescription.map {
        CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: pixelBuffer)
      } ?? false
    if !matches {
      formatDescription = nil
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: nil,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &formatDescription
      )
    }
    guard let formatDescription else { return nil }

    // SwiftPeek's contract, `PiPFramePump.swift:134-143`: the control timebase
    // is anchored to the pair (anchorMediaTime, anchorHostTime), and every frame
    // is stamped with
    //
    //     pts = anchorMediaTime + (hostTime - anchorHostTime) * rate
    //
    // Both the timebase and the timestamps are therefore derived from the same
    // anchor, so they cannot disagree. That is the invariant this plugin was
    // missing: it used to stamp frames with one clock while driving (or not
    // driving) the timebase with another, and the layer then re-ordered frames
    // that were already queued — a picture alternating between two neighbours.
    let pts = CMTimeAdd(
      mediaAnchor,
      CMTime(
        seconds: max(0, hostTime - anchorHostTime) * anchorRate,
        preferredTimescale: 600
      )
    )
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 60),
      presentationTimeStamp: pts,
      decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
      allocator: nil,
      imageBuffer: pixelBuffer,
      formatDescription: formatDescription,
      sampleTiming: &timing,
      sampleBufferOut: &sampleBuffer
    )
    guard let sampleBuffer else { return nil }
    return sampleBuffer
  }

  private func enqueue(_ sampleBuffer: CMSampleBuffer) -> Bool {
    if #available(iOS 17.0, *) {
      let renderer = displayLayer.sampleBufferRenderer
      if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
        renderer.flush()
      }
      // Pushing while the renderer is still full makes it buffer frames and play
      // them back later, which lags behind the live edge. Dropping is correct
      // for a live stream — the pump retries on its next tick.
      guard renderer.isReadyForMoreMediaData else { return false }
      renderer.enqueue(sampleBuffer)
      return renderer.status != .failed
    } else {
      if displayLayer.status == .failed || displayLayer.requiresFlushToResumeDecoding {
        displayLayer.flush()
      }
      guard displayLayer.isReadyForMoreMediaData else { return false }
      displayLayer.enqueue(sampleBuffer)
      return displayLayer.status != .failed
    }
  }

  /// Same as the home gesture. There is no public API for this, `suspend` is
  /// a private method of `UIApplication`.
  private static func moveToBackground() {
    UIControl().sendAction(#selector(URLSessionTask.suspend), to: UIApplication.shared, for: nil)
  }

  private static func hostWindow() -> UIWindow? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
    return windows.first { $0.rootViewController is FlutterViewController }
      ?? windows.first { $0.isKeyWindow }
  }
}

@available(iOS 15.0, *)
extension PipSession: AVPictureInPictureControllerDelegate {
  func pictureInPictureControllerWillStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    // The timeline starts at zero and is anchored to the current host time. Every
    // later timestamp and the control timebase both derive from this pair, which
    // is what keeps them from ever drifting apart.
    mediaAnchor = .zero
    anchorHostTime = CACurrentMediaTime()
    anchorRate = isPlaying ? speed : (speed > 0 ? speed : 1)
    // Pushed before `isActive`, because from then on the pump is the only
    // enqueuer and the window would stay black until its first tick.
    frameAvailable(force: true)
    isActive = true
    stopRequested = false
    restoring = false
    // From here on the app is usually backgrounded and media_kit's update
    // callback is throttled away, so frames are pulled by the pump instead.
    startPump()
    sendEvent("onStateChanged", ["active": true])
  }

  func pictureInPictureControllerDidStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    if backgroundOnStart {
      backgroundOnStart = false
      Self.moveToBackground()
    }
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    isActive = false
    backgroundOnStart = false
    stopPump()
    sendEvent("onStateChanged", ["active": false, "error": error.localizedDescription])
    DispatchQueue.main.async { [weak self] in self?.onStop?() }
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:
      @escaping (Bool) -> Void
  ) {
    restoring = true
    completionHandler(true)
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    isActive = false
    stopPump()
    // Neither restored nor stopped by the app: closed from the PiP window.
    let closed = !restoring && !stopRequested
    stopRequested = false
    restoring = false
    sendEvent("onStateChanged", ["active": false, "closed": closed])
    DispatchQueue.main.async { [weak self] in self?.onStop?() }
  }
}

@available(iOS 15.0, *)
extension PipSession: AVPictureInPictureSampleBufferPlaybackDelegate {
  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    setPlaying playing: Bool
  ) {
    isPlaying = playing
    // A live stream keeps its timeline running; pausing is expressed by holding
    // frames back, not by stopping the clock.
    if isLive {
      if CMTimebaseGetRate(timebase) != speed {
        CMTimebaseSetRate(timebase, rate: speed)
      }
    } else {
      CMTimebaseSetRate(timebase, rate: playing ? speed : 0)
    }
    pushLock.lock()
    isPausedByUser = !playing
    pushLock.unlock()
    pictureInPictureController.invalidatePlaybackState()
    sendEvent("setPlaying", playing)
  }

  /// A live stream has an endless timeline. Reporting a finite range makes the
  /// window draw a scrubber that means nothing and lets the user drag it into a
  /// seek the stream cannot serve.
  func pictureInPictureControllerTimeRangeForPlayback(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> CMTimeRange {
    return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
  }

  func pictureInPictureControllerIsPlaybackPaused(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> Bool {
    !isPlaying
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {
    // Nothing to do: the output frame size comes from the source resolution and
    // `videoGravity` handles fitting it to the window. Resizing the output here
    // used to rebuild the pixel buffer pool, which flushes the layer.
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping () -> Void
  ) {
    // A live stream cannot be skipped. Moves the timebase otherwise, which would
    // make the layer jump to a timeline that has no frames.
    guard !isLive else {
      completionHandler()
      return
    }
    let target = CMTimeClampToRange(
      CMTimeAdd(CMTimebaseGetTime(timebase), skipInterval),
      range: CMTimeRange(start: .zero, duration: duration)
    )
    CMTimebaseSetTime(timebase, time: target)
    sendEvent("skip", Int((skipInterval.seconds * 1000).rounded()))
    completionHandler()
  }

  func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> Bool {
    false
  }
}

// MARK: - Pixel transfer

/// CPU-only copy / scale between two BGRA buffers.
///
/// Deliberately avoids Core Image and Metal: iOS denies application Metal work
/// while the app is in the background, which is exactly when PiP is on screen.
/// A GPU render there either fails or leaves a partially written surface, and
/// the display layer keeps re-presenting it. (Ref. SwiftPeek `PiPPixelTransfer`.)
private enum PiPPixelTransfer {
  static func copy(_ source: CVPixelBuffer, to destination: CVPixelBuffer) -> Bool {
    // media_kit_video allocates its surfaces as 32BGRA, see
    // `OpenGLESHelpers.createPixelBuffer`.
    guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA,
      CVPixelBufferGetPixelFormatType(destination) == kCVPixelFormatType_32BGRA,
      CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess
    else { return false }
    defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }

    guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess
    else { return false }
    defer { CVPixelBufferUnlockBaseAddress(destination, []) }

    guard let sourceData = CVPixelBufferGetBaseAddress(source),
      let destinationData = CVPixelBufferGetBaseAddress(destination)
    else { return false }

    var input = vImage_Buffer(
      data: sourceData,
      height: vImagePixelCount(CVPixelBufferGetHeight(source)),
      width: vImagePixelCount(CVPixelBufferGetWidth(source)),
      rowBytes: CVPixelBufferGetBytesPerRow(source)
    )
    var output = vImage_Buffer(
      data: destinationData,
      height: vImagePixelCount(CVPixelBufferGetHeight(destination)),
      width: vImagePixelCount(CVPixelBufferGetWidth(destination)),
      rowBytes: CVPixelBufferGetBytesPerRow(destination)
    )
    if input.width == output.width, input.height == output.height {
      return vImageCopyBuffer(&input, &output, 4, vImage_Flags(kvImageNoFlags))
        == kvImageNoError
    }
    // Scaling treats all four channels equally, so BGRA order is preserved.
    return vImageScale_ARGB8888(&input, &output, nil, vImage_Flags(kvImageNoFlags))
      == kvImageNoError
  }
}

private final class SampleBufferView: UIView {
  override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
}

// MARK: - Diagnostics

/// Rate counters for the PiP frame path, logged every 5 s.
///
/// Modelled on SwiftPeek's `PiPFramePump.report(at:)`, which logs the same four
/// figures. Reading them off a device tells apart the remaining failure modes
/// instead of guessing: `enqueued` far below `ticks` means the layer is applying
/// backpressure, `fresh` far below `ticks` means mpv stopped producing frames,
/// and a healthy `enqueued` next to a still picture means the layer is not
/// presenting what it is given.
private struct Diagnostics {
  private var windowStart = CACurrentMediaTime()
  private var ticks = 0
  private var fresh = 0
  private var enqueued = 0
  private var emptyCopies = 0
  private var repeated = 0
  private var rejected = 0
  var forcedRender = 0

  mutating func tick(at now: TimeInterval) {
    ticks += 1
    guard now - windowStart >= 5 else { return }
    let elapsed = now - windowStart
    NSLog(
      "PipPlugin: ticks/s=%.1f fresh/s=%.1f enqueued/s=%.1f "
        + "emptyCopy=%d repeated=%d rejected=%d forcedRender=%d",
      Double(ticks) / elapsed,
      Double(fresh) / elapsed,
      Double(enqueued) / elapsed,
      emptyCopies,
      repeated,
      rejected,
      forcedRender
    )
    windowStart = now
    ticks = 0
    fresh = 0
    enqueued = 0
    emptyCopies = 0
    repeated = 0
    rejected = 0
    forcedRender = 0
  }

  mutating func noteFresh() { fresh += 1 }
  mutating func noteEnqueued() { enqueued += 1 }
  mutating func noteEmptyCopy() { emptyCopies += 1 }
  mutating func noteRejected() { rejected += 1 }
  mutating func noteRepeated() { repeated += 1 }
}

// MARK: - Texture tracking

/// Hooks the engine's `FlutterTextureRegistry` to keep track of registered
/// textures and to observe their frame updates. Main thread only.
private enum TextureTracker {
  private final class WeakTexture {
    weak var value: FlutterTexture?
    init(_ value: FlutterTexture) { self.value = value }
  }

  private static var textures = [Int64: WeakTexture]()
  private static var installed = false

  static var onFrameAvailable: ((Int64) -> Void)?

  static func texture(for textureId: Int64) -> FlutterTexture? {
    textures[textureId]?.value
  }

  static func install(on registry: FlutterTextureRegistry) {
    guard !installed, let cls = object_getClass(registry) else { return }
    installed = true

    let registerSelector = NSSelectorFromString("registerTexture:")
    hook(cls, registerSelector) { original in
      typealias Function = @convention(c) (AnyObject, Selector, AnyObject) -> Int64
      let function = unsafeBitCast(original, to: Function.self)
      let block: @convention(block) (AnyObject, AnyObject) -> Int64 = { this, texture in
        let textureId = function(this, registerSelector, texture)
        if let texture = texture as? FlutterTexture {
          Self.textures = Self.textures.filter { $0.value.value != nil }
          Self.textures[textureId] = WeakTexture(texture)
        }
        return textureId
      }
      return unsafeBitCast(block, to: AnyObject.self)
    }

    let frameAvailableSelector = NSSelectorFromString("textureFrameAvailable:")
    hook(cls, frameAvailableSelector) { original in
      typealias Function = @convention(c) (AnyObject, Selector, Int64) -> Void
      let function = unsafeBitCast(original, to: Function.self)
      let block: @convention(block) (AnyObject, Int64) -> Void = { this, textureId in
        function(this, frameAvailableSelector, textureId)
        // The engine may call this from a render thread; the tracker and the
        // session state are main-thread only.
        if Thread.isMainThread {
          Self.onFrameAvailable?(textureId)
        } else {
          DispatchQueue.main.async { Self.onFrameAvailable?(textureId) }
        }
      }
      return unsafeBitCast(block, to: AnyObject.self)
    }
  }

  private static func hook(
    _ cls: AnyClass,
    _ selector: Selector,
    _ makeBlock: (IMP) -> AnyObject
  ) {
    guard let method = class_getInstanceMethod(cls, selector) else {
      NSLog("PipPlugin: \(cls) does not respond to \(selector)")
      return
    }
    let imp = imp_implementationWithBlock(makeBlock(method_getImplementation(method)))
    // Add an override if the method is inherited, so the superclass is untouched.
    if !class_addMethod(cls, selector, imp, method_getTypeEncoding(method)) {
      method_setImplementation(method, imp)
    }
  }
}
