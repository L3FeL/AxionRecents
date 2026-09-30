# Changelog

## v1.0 — 首个公开发布版

首个对外版本，打包了内部迭代到 “build-65” 的最终形态：

* **堆叠式最近任务**：AxionOS/Lawnchair 派生的 Launcher3 以系统 priv-app 镜像 + 静态框架 RRO
  的形式生效，`config_recentsComponentName` 指向 `com.android.launcher3/com.android.quickstep.RecentsActivity`，
  开机后自动把 HOME 交给同一个包。
* **从 app 内进入最近任务正常**：修掉了「上滑后 Shell 发出的 runner 回调解析不了、
  `onAnimationStart` 从不执行」的问题 —— 按本机 AIDL 的真实布局自行解析
  `IRecentsAnimationRunner` 的 parcel（token 前导 12 字节，生成的 stub 会在对象表上越界读，
  libbinder 判 `PERMISSION_DENIED` 且 oneway 事务静默失败）。详见
  [`docs/HOW-IT-WORKS.md`](docs/HOW-IT-WORKS.md)。
* **切到另一张卡不再卡死**：事务码 2（`onAnimationCanceled`）与 4（`onTasksAppeared`）做同样
  的手工解析，Shell 的 `merge` 流程能正常收尾。
* **远处卡片会提前渲染**：牌堆模式预加载更远的卡片，不再要滑到附近才加载缩略图。
* **没有启动器切换开关**：回原厂桌面统一走“停用模块 + 重启”，模块里不再有动作按钮脚本。
* **安全网**：开机失败自动停用（熔断）+ 崩溃循环看门狗 + `/data/adb/axion_recents*.log` 日志。

### 说明

* 模块 `versionCode` 从 1 重新开始计数，与内部开发期的编号无关（内部开发期使用过 v1.0–v1.15）。
* 仅在 Motorola Android 16（SDK 36）上测试；详见 README §2 的兼容性与已知限制。
