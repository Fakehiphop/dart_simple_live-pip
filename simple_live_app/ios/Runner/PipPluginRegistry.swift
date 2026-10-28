import CoreVideo
import Flutter
import UIKit

// 通过 Flutter 公开纹理 API 观察帧（PiliPlus TextureTracker 的等价实现，
// 但用的是公开注册表包装而非 ObjC runtime hook）。
//
// 本轮只保留两件事：
//   1. 把 media-kit 注册的纹理包一层，在 `textureFrameAvailable` 时抓一份
//      最新像素缓冲交给 iOS 画中画控制器；
//   2. 其余注册表接口原样转发。
//
// 软件渲染切换（原 Kazumi PR #2646 的 setSoftwareRendering / restoreRendering
// 一整套机制）已整体移除：渲染后端全程恒定，后台出帧靠 audio 后台模式维持
// 进程与主队列存活（PiliPlus 同构）。
private final class PipTextureRegistry: NSObject, FlutterTextureRegistry {
    private let registry: FlutterTextureRegistry
    private let frameHandler: (CVPixelBuffer, Int64) -> Void
    private var textures: [Int64: FlutterTexture] = [:]

    init(registry: FlutterTextureRegistry, frameHandler: @escaping (CVPixelBuffer, Int64) -> Void) {
        self.registry = registry
        self.frameHandler = frameHandler
        super.init()
    }

    func register(_ texture: FlutterTexture) -> Int64 {
        let textureId = registry.register(texture)
        textures[textureId] = texture
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

// 包住真实的 FlutterPluginRegistry，只为 MediaKitVideoPlugin 换掉纹理注册表。
final class PipPluginRegistry: NSObject, FlutterPluginRegistry {
    private let registry: FlutterPluginRegistry
    private let frameHandler: (CVPixelBuffer, Int64) -> Void
    private var videoRegistrar: PipRegistrar?

    init(registry: FlutterPluginRegistry,
         frameHandler: @escaping (CVPixelBuffer, Int64) -> Void) {
        self.registry = registry
        self.frameHandler = frameHandler
        super.init()
    }

    func registrar(forPlugin pluginKey: String) -> FlutterPluginRegistrar? {
        guard let registrar = registry.registrar(forPlugin: pluginKey) else { return nil }
        guard pluginKey == "MediaKitVideoPlugin" else { return registrar }
        let textures = PipTextureRegistry(registry: registrar.textures(), frameHandler: frameHandler)
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
}
