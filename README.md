# SimpleLive iOS 画中画版

> 在 [June6699/dart_simple_live](https://github.com/June6699/dart_simple_live) 基础上增加 **iOS 系统级画中画（Picture-in-Picture）** 支持。
> 直播可以在退到后台后继续以小窗播放。
>

---

## 功能

iOS 端新增系统级画中画。直播播放时：

- 点播放页的小窗按钮 → 立即进入画中画
- 开播中按 Home 退后台 → 自动进入画中画（跟随「退后台自动小窗」设置）
- 小窗内可播放 / 暂停，按钮状态与主播放器同步
- 点小窗的恢复按钮 → 回到直播间；点关闭按钮 → 结束小窗并恢复弹幕
- 小窗内不显示进度条与快进快退按钮（直播没有 seek 语义）


---

## 已知限制

- **模拟器跑不了**：模拟器报告系统 PiP 不受支持，必须真机验证
- **iOS 15+**：`ContentSource(sampleBufferDisplayLayer:)` 自 iOS 15 起可用
- **前台也走 CPU 渲染**：`enableHardwareAcceleration` 无法运行期切换，见上文 ②
- **多 Scene**：纹理追踪依赖单 Scene 假设
---

## 分支

| 分支 | 用途 |
|---|---|
| `master` | 当前可用版本，基于上游最新代码，画中画以单个提交 `fd19592` 呈现，可正常 Sync fork |
| `pip-history` | 仅存档。保留画中画功能最初的两次提交 `93db1a5`（初版，小窗冻在最后一帧）与 `48e6f58`（修复后）。其内容已被 `master` 覆盖并改进，且基于更早的上游基线，**不要从该分支合并或 cherry-pick** |

---

## 参考实现

帧调度设计参考 [Rladmsrl/SwiftPeek](https://github.com/Rladmsrl/SwiftPeek)（斗鱼客户端，
同为 GPL-3.0）的 `PiPFramePump` / `PiPPixelTransfer`；其 `PiPLiveFrameSource` 未采用——
它依赖 FLV demux，本项目没有。

---

## 上游

- [June6699/dart_simple_live](https://github.com/June6699/dart_simple_live) —— 本仓库的直接上游
- [xiaoyaocz/dart_simple_live](https://github.com/xiaoyaocz/dart_simple_live) —— 原作者仓库

除 iOS 画中画外的功能说明、站点支持列表、配置导入教程等，请参考上游 README。
