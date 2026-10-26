import CoreVideo
import Flutter
import UIKit
import media_kit_video

// 基于 Kazumi PR #2646（sibogentleman）的实现移植。
// 该插件通过 FlutterPluginRegistry 发布这份类型化 API。它拥有输出的配置与替换；
// 应用层负责 mpv 视频轨道的挂起与恢复。
protocol PipRendering: AnyObject {
    var softwareRenderingHandles: [Int64] { get }
    func setSoftwareRenderingForNewOutputs(_ enabled: Bool)
    func setSoftwareRendering(handle: Int64, enabled: Bool,
                              completion: @escaping (VideoOutputRenderingResult) -> Void)
}

extension MediaKitVideoPlugin: PipRendering {}

private final class PipTextureRegistry: NSObject, FlutterTextureRegistry {
    private let registry: FlutterTextureRegistry
    private let frameHandler: (CVPixelBuffer, Int64) -> Void
    private let onRegistered: () -> Void
    private var textures: [Int64: FlutterTexture] = [:]

    init(registry: FlutterTextureRegistry, frameHandler: @escaping (CVPixelBuffer, Int64) -> Void,
         onRegistered: @escaping () -> Void) {
        self.registry = registry
        self.frameHandler = frameHandler
        self.onRegistered = onRegistered
        super.init()
    }

    func register(_ texture: FlutterTexture) -> Int64 {
        let textureId = registry.register(texture)
        textures[textureId] = texture
        // 插件在 register 返回后才算完成初始化。重试此前遇到新输出忙的前台恢复。
        DispatchQueue.main.async(execute: onRegistered)
        return textureId
    }

    func unregisterTexture(_ textureId: Int64) {
        textures.removeValue(forKey: textureId)
        registry.unregisterTexture(textureId)
    }

    func copyPixelBuffer(forTexture textureId: Int64) -> CVPixelBuffer? {
        // FlutterTexture 返回的是已保留（retained）的缓冲区；把该引用交给 ARC。
        textures[textureId]?.copyPixelBuffer()?.takeRetainedValue()
    }

    func textureFrameAvailable(_ textureId: Int64) {
        // media-kit 在每次渲染完成后于平台线程调用此方法。
        // 不要指望 Flutter 在后台还会调用 copyPixelBuffer。
        if let buffer = copyPixelBuffer(forTexture: textureId) {
            frameHandler(buffer, textureId)
        }
        registry.textureFrameAvailable(textureId)
    }
}

// 只有 media-kit 的 registrar 拿到纹理适配器；其他插件使用原始 registrar，
// 插件注册仍由 Flutter 生成代码完成。
private final class PipRegistrar: NSObject, FlutterPluginRegistrar {
    private let registrar: FlutterPluginRegistrar
    let textureRegistry: PipTextureRegistry

    init(registrar: FlutterPluginRegistrar, textureRegistry: PipTextureRegistry) {
        self.registrar = registrar
        self.textureRegistry = textureRegistry
        super.init()
    }

    func messenger() -> FlutterBinaryMessenger { registrar.messenger() }
    func textures() -> FlutterTextureRegistry { textureRegistry }
    var viewController: UIViewController? { registrar.viewController }
    func publish(_ value: NSObject) { registrar.publish(value) }

    func addMethodCallDelegate(_ delegate: FlutterPlugin, channel: FlutterMethodChannel) {
        registrar.addMethodCallDelegate(delegate, channel: channel)
    }

    func addApplicationDelegate(_ delegate: FlutterPlugin) {
        registrar.addApplicationDelegate(delegate)
    }

    func addSceneDelegate(_ delegate: FlutterSceneLifeCycleDelegate) {
        registrar.addSceneDelegate(delegate)
    }

    func register(_ factory: FlutterPlatformViewFactory, withId factoryId: String) {
        registrar.register(factory, withId: factoryId)
    }

    func register(_ factory: FlutterPlatformViewFactory, withId factoryId: String,
                  gestureRecognizersBlockingPolicy policy: FlutterPlatformViewGestureRecognizersBlockingPolicy) {
        registrar.register(factory, withId: factoryId, gestureRecognizersBlockingPolicy: policy)
    }

    func lookupKey(forAsset asset: String) -> String { registrar.lookupKey(forAsset: asset) }
    func lookupKey(forAsset asset: String, fromPackage package: String) -> String {
        registrar.lookupKey(forAsset: asset, fromPackage: package)
    }

    func valuePublished(byPlugin pluginKey: String) -> NSObject? {
        registrar.valuePublished(byPlugin: pluginKey)
    }
}

// 通过 Flutter 公开纹理 API 观察帧。插件方法委托原样转发；
// 渲染器切换使用 media-kit 发布的 API。
final class PipPluginRegistry: NSObject, FlutterPluginRegistry {
    private let registry: FlutterPluginRegistry
    private let frameHandler: (CVPixelBuffer, Int64) -> Void
    private let renderingOverride: PipRendering?
    private let isForeground: () -> Bool
    private var videoRegistrar: PipRegistrar?
    private var recreatingHandles: Set<Int64> = []
    private var waitingForRegistration: Set<Int64> = []
    private var registrationGeneration: UInt = 0
    private var restorationCompletions: [() -> Void] = []
    private var softwareRendering = false

    var videoOutputWillChange: ((Int64, @escaping (Bool) -> Void) -> Void)?
    var videoOutputDidChange: ((Int64, Bool, @escaping (Bool) -> Void) -> Void)?

    private var renderer: PipRendering? {
        renderingOverride ?? registry.valuePublished(byPlugin: "MediaKitVideoPlugin") as? MediaKitVideoPlugin
    }

    init(registry: FlutterPluginRegistry,
         rendering: PipRendering? = nil,
         isForeground: @escaping () -> Bool = { UIApplication.shared.applicationState == .active },
         frameHandler: @escaping (CVPixelBuffer, Int64) -> Void) {
        self.registry = registry
        self.frameHandler = frameHandler
        self.renderingOverride = rendering
        self.isForeground = isForeground
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(restoreIfForeground),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(restoreIfForeground),
                                               name: UIScene.didActivateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(protectBackgroundOutputs),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(protectBackgroundOutputs),
                                               name: UIScene.didEnterBackgroundNotification, object: nil)
    }

    func registrar(forPlugin pluginKey: String) -> FlutterPluginRegistrar? {
        guard let registrar = registry.registrar(forPlugin: pluginKey) else { return nil }
        guard pluginKey == "MediaKitVideoPlugin" else { return registrar }
        let textures = PipTextureRegistry(registry: registrar.textures(), frameHandler: frameHandler) { [weak self] in
            self?.textureRegistered()
        }
        let adapter = PipRegistrar(registrar: registrar, textureRegistry: textures)
        videoRegistrar = adapter
        return adapter
    }

    func hasPlugin(_ pluginKey: String) -> Bool { registry.hasPlugin(pluginKey) }
    func valuePublished(byPlugin pluginKey: String) -> NSObject? {
        registry.valuePublished(byPlugin: pluginKey)
    }

    func copyPixelBuffer(forTexture textureId: Int64) -> CVPixelBuffer? {
        videoRegistrar?.textureRegistry.copyPixelBuffer(forTexture: textureId)
    }

    private func changeRendering(_ handle: Int64, software: Bool,
                                 completion: @escaping (Bool) -> Void) {
        guard !recreatingHandles.contains(handle), let renderer = renderer,
              let willChange = videoOutputWillChange,
              let didChange = videoOutputDidChange else { completion(false); return }
        recreatingHandles.insert(handle)
        var retryGeneration: UInt?
        let finish: (Bool) -> Void = { ready in
            self.recreatingHandles.remove(handle)
            completion(ready)
            // 关闭画中画可能与进入竞争。在其轨道恢复之后、向 Dart 确认原生会话
            // 释放之前执行恢复。
            if software && !self.softwareRendering && self.isForeground() {
                self.restoreIfForeground()
            } else if let generation = retryGeneration,
                      generation != self.registrationGeneration {
                self.retryRegisteredOutputs()
            }
            self.finishRestorationIfIdle()
        }
        willChange(handle) { suspended in
            guard suspended else { finish(false); return }
            // 挂起跨越 Dart 通道。等待期间应用可能已退后台或开始了另一个画中画会话。
            guard software || (!self.softwareRendering && self.isForeground()) else {
                renderer.setSoftwareRenderingForNewOutputs(true)
                didChange(handle, false) { _ in finish(false) }
                return
            }
            renderer.setSoftwareRendering(handle: handle, enabled: software) { result in
                if !software && result == .notReady {
                    self.waitingForRegistration.insert(handle)
                    retryGeneration = self.registrationGeneration
                } else {
                    self.waitingForRegistration.remove(handle)
                }
                // 即使失败或未变化也必须恢复轨道。
                // 依赖项只有在输出工作排空后才完成。
                didChange(handle, result == .changed) { resumed in
                    finish((result == .changed || result == .unchanged) && resumed)
                }
            }
        }
    }

    func useSoftwareRendering(forHandle handle: Int64, completion: @escaping (Bool) -> Void) {
        guard let renderer = renderer else { completion(false); return }
        softwareRendering = true
        // 画中画激活期间新建的替换播放器也必须避开 GL。
        renderer.setSoftwareRenderingForNewOutputs(true)
        changeRendering(handle, software: true, completion: completion)
    }

    func restoreRendering(completion: @escaping () -> Void) {
        softwareRendering = false
        restorationCompletions.append(completion)
        restoreIfForeground()
        finishRestorationIfIdle()
    }

    private func finishRestorationIfIdle() {
        guard recreatingHandles.isEmpty else { return }
        let completions = restorationCompletions
        restorationCompletions.removeAll()
        completions.forEach { $0() }
    }

    @objc private func restoreIfForeground() {
        guard !softwareRendering, isForeground(), let renderer = renderer else { return }
        renderer.setSoftwareRenderingForNewOutputs(false)
        for handle in renderer.softwareRenderingHandles where !recreatingHandles.contains(handle) {
            changeRendering(handle, software: false) { _ in }
        }
    }

    private func textureRegistered() {
        registrationGeneration &+= 1
        retryRegisteredOutputs()
    }

    private func retryRegisteredOutputs() {
        guard !softwareRendering, isForeground(), let renderer = renderer else { return }
        let liveHandles = Set(renderer.softwareRenderingHandles)
        waitingForRegistration.formIntersection(liveHandles)
        for handle in waitingForRegistration where !recreatingHandles.contains(handle) {
            waitingForRegistration.remove(handle)
            changeRendering(handle, software: false) { _ in }
        }
    }

    @objc private func protectBackgroundOutputs() {
        guard let renderer = renderer,
              softwareRendering || !renderer.softwareRenderingHandles.isEmpty || !recreatingHandles.isEmpty else { return }
        renderer.setSoftwareRenderingForNewOutputs(true)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
