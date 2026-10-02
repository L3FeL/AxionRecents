# Axion Recents for Motorola Android 16

把 AxionOS 派生 Launcher3 的**牌堆式最近任务**带到 Motorola Android 16（SDK 36）：上滑打开的是叠放在一起、
可上下拖拽翻看的卡片堆。

![堆叠式后台](docs/screenshot.png)

模块 ID `axion_recents` · 当前版本 **v1.2.1** · 作者 **L3FeL** · 许可 **GPL-3.0**

## 实现方式

1. 开机最早阶段 `post-fs-data.sh` 把 `payload/AxionLauncher3.apk` 与 privapp 权限白名单 **tmpfs 镜像**
   进 `/system_ext/priv-app/AxionLauncher3/`、`/system_ext/etc/permissions/` —— 原厂文件一个字节都不动。
2. 静态框架 RRO（`priority 100`）把 `android:string/config_recentsComponentName` 指到
   `com.android.launcher3/com.android.quickstep.RecentsActivity`。
3. `service.sh` / `boot-completed.sh` 确认 RRO 生效后把 HOME 角色交给 Axion 桌面，并持续自检：
   连续 3 次开机没留下健康标记就自动停用（熔断），160 s 内判定桌面崩溃循环就回滚 + 重启。
   日志：`/data/adb/axion_recents.log`。
4. C-lite 靠模块自带的 LSPosed 桥接（`extras/motodesktop-helper.apk`）：替仍当 HOME 的原厂桌面放行
   AOSP 只授予 recents 组件的 `recents` 标志权限，并补上 C-lite 下失效的两个桌面手势。

原理细节：[`docs/HOW-IT-WORKS.md`](docs/HOW-IT-WORKS.md)、[`docs/C-LITE.md`](docs/C-LITE.md)。

## 功能

* 在 Motorola 上实现堆叠式最近任务。
* 两种模式（同一模块，靠 LSPosed 是否启用桥接切换）：

  | 模式 | HOME | 最近任务 |
  | --- | --- | --- |
  | 默认 | Axion（`com.android.launcher3`） | Axion 堆叠式 |
  | **C-lite** | 原厂 Moto（`com.motorola.launcher3`） | Axion 堆叠式 |

* 限制：C-lite 下桌面本身不出现在最近任务里；默认模式下原厂桌面在模块生效期间不可用。
* C-lite 下原厂桌面的双击息屏、下滑拉出控制中心 / 通知栏已恢复（v1.2.1 起）。

## 安装方式

1. 从 **Releases** 下载模块。
2. KernelSU 刷入后重启。
3. **C-lite 模式**：在 LSPosed 里启用「Axion 桌面桥接」（作用域勾选 `系统框架 system` 与
   `Moto 应用启动器 com.motorola.launcher3`）后重启。

回原厂 / 卸载：KernelSU 里停用（或卸载）`axion_recents` → 重启。

## 警告（免责声明）

* 仅在 Motorola Android 16 / SDK 36、原厂桌面为 `com.motorola.launcher3` 的机型上实测，测试环境：KernelSU v3.3.0，LSPosed (API 102)。
* 默认模式下原厂桌面在模块生效期间不可用。
* 模块脚本、RRO 源码、桥接由 AI 生成。

## 许可 / 致谢

* 本仓库以 **GPL-3.0** 发布，见 [`LICENSE`](LICENSE)；变更记录见 [`CHANGELOG.md`](CHANGELOG.md)。
* `payload/AxionLauncher3.apk` 由 **AxionOS / Lawnchair / AOSP Launcher3** 派生的源码构建，
  `AxStack*` 堆叠式 Overview 来自 AxionOS/Lawnchair 一侧，权利归其各自作者。
* 感谢 AOSP Launcher3、Lawnchair、AxionOS 与 KernelSU / LSPosed 生态。作者：**L3FeL**。
