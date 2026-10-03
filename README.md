# Axion Recents for Motorola Android 16

把 AxionOS 派生 Launcher3 的**牌堆式最近任务**带到 Motorola Android 16（SDK 36）

## 功能

* 在 Motorola 上实现堆叠式最近任务。
* 两种模式（同一模块，靠 LSPosed 是否启用桥接切换）：

  | 模式 | HOME | 最近任务 |
  | --- | --- | --- |
  | 默认 | Axion（`com.android.launcher3`） | Axion 堆叠式 |
  | **C-lite** | 原厂 Moto（`com.motorola.launcher3`） | Axion 堆叠式 |

* 限制：默认模式下原厂桌面在模块生效期间不可用。

## 安装方式

1. 从 **Releases** 下载模块。
2. KernelSU 刷入后重启。
3. **C-lite 模式**：在 LSPosed 里启用「Axion 桌面桥接」（作用域勾选 `系统框架 system` 与
   `Moto 应用启动器 com.motorola.launcher3`）后重启。


## 注意

* 仅在 Motorola Android 16 / SDK 36、原厂桌面为 `com.motorola.launcher3` 的机型上实测，测试环境：KernelSU v3.3.0，LSPosed (API 102)。
* 默认模式下原厂桌面在模块生效期间不可用。
* 模块脚本、RRO 源码、桥接由 AI 生成。

## 许可 / 致谢

* 本仓库以 **GPL-3.0** 发布，见 [`LICENSE`](LICENSE)；变更记录见 [`CHANGELOG.md`](CHANGELOG.md)。
* `payload/AxionLauncher3.apk` 由 **AxionOS / Lawnchair / AOSP Launcher3** 派生的源码构建，
  `AxStack*` 堆叠式 Overview 来自 AxionOS/Lawnchair 一侧，权利归其各自作者。
* 感谢 AOSP Launcher3、Lawnchair、AxionOS 与 KernelSU / LSPosed 生态。