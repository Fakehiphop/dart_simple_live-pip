# SimpleLive iOS 画中画版

> 在 [June6699/dart_simple_live](https://github.com/June6699/dart_simple_live) 基础上增加 **iOS 系统级画中画（Picture-in-Picture）**。
> 直播可以在退到后台后继续以小窗播放。

<p align="center">
    <img width="128" src="/assets/logo.png" alt="SimpleLive logo">
</p>

---

## 下载

| 版本 | 文件 | 大小 | SHA256 |
|---|---|---|---|
| v1.13.3 | [`SimpleLive-pip_v1.13.3.ipa`](https://github.com/Fakehiphop/dart_simple_live-pip-v2/releases/download/v1.13.3/SimpleLive-pip_v1.13.3.ipa) | 34,477,626 B | `52FB1DAF6AFE5ADBC2A7EC497A9687C8C0B0103CEF3DBCA91F3DFE63823ED1C9` |

无签名包，需要自行签名后安装：AltStore / Sideloadly / TrollStore / 越狱设备直接侧载均可。

---

## 画中画功能

直播播放时：

- 点播放页的小窗按钮 → 立即进入画中画
- 开播中上滑退桌面 / 按 Home → 由系统自动拉起画中画
- 小窗内可播放 / 暂停，按钮状态与主播放器同步
- 点小窗的恢复按钮 → 回到直播间；点关闭按钮 → 结束小窗
- 回到 App 时小窗自动关闭，不残留
- 锁屏与控制中心卡片显示主播名 + 直播间标题，并带封面图
- 锁屏 / 控制中心的播放、暂停命令直接作用于播放器

渲染与生命周期：

- 前台与画中画**全程 GPU 渲染**（TextureHW），不做软件渲染降级
- 后台持续出帧依赖 `UIBackgroundModes=audio` + 音频在播，进程不被挂起
- 帧节流：画中画激活 30fps，未激活时 0.25s 保温，保证系统判定"可自动启动"
- 退出直播页即销毁原生画中画会话，不留冻结的僵尸小窗

---

## 已知限制

- **模拟器跑不了**：模拟器报告系统 PiP 不受支持，必须真机验证
- **iOS 15+**：`ContentSource(sampleBufferDisplayLayer:)` 自 iOS 15 起可用
- **必须有音频在播**：纯静音或暂停状态下退后台，进程会被挂起，小窗随之停帧
- **多 Scene**：纹理追踪依赖单 Scene 假设
- 首次进入小窗时首帧尚未就绪的情况下，系统可能拒绝该轮自动起窗，下一轮正常

---

## 分支

| 分支 | 用途 |
|---|---|
| `master` | 当前可用版本，对应 v1.13.3（Release 中的 IPA 源码）；默认分支 |
| 其他 | 各轮并行迭代的归档快照，只读参考 |

---

## 参考实现

- [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus) —— 原生 iOS 画中画插件（`PipPlugin`）的整体结构与本项目同构。
- [SwiftPeek](https://github.com/Rladmsrl/SwiftPeek)

---

## 上游

- [June6699/dart_simple_live](https://github.com/June6699/dart_simple_live) —— 本仓库的直接上游
- [xiaoyaocz/dart_simple_live](https://github.com/xiaoyaocz/dart_simple_live) —— 原作者仓库

除 iOS 画中画外的功能说明、站点支持列表、配置导入教程等，请参考上游 README。

---

## 许可

GPL-3.0，见 [LICENSE](/LICENSE)。与上游一致。
