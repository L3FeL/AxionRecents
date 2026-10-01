# Changelog

## v1.2 — C-lite 开关并入 LSPosed + payload 换 release 变体

第三个公开发布版。默认行为不变（Axion 同时当桌面和最近任务），C-lite 的**切换方式**从
「标记文件」换成「LSPosed 里启用桥接 + 重启」；打包的 launcher payload 换成 release 变体；
顺手修掉两处诊断文件只增不减的问题。

* **模式判定改为桥接握手（废弃标记文件）**：`boot-completed.sh` 与 `service.sh` 里逐字相同的
  一段代码取代原来的 `if [ -f "$STOCK_HOME" ]`：取**最新**的 `/data/adb/lspd/log/modules_*.log`，
  用 `grep -a -o 'AxionDesktopBridge active in system_server[^=]*boot=[0-9a-fA-F-]*'` 抠出桥接
  握手行里的 `boot=`，与 `/proc/sys/kernel/random/boot_id` 比较，一致才 `bridge_active=1` ⇒
  进 C-lite，否则默认模式。桥接在 system_server 里载入成功时调用
  `XposedBridge.log("AxionDesktopBridge active in system_server hooks=… boot=…")`，LSPosed 只对
  调用 `XposedBridge.log()` 的模块落这个日志。因为比的是 boot id，**旧开机的日志不会把本次
  开机误判成 C-lite**；boot id 读不到时不匹配 ⇒ 留在默认模式（安全默认）。每次判定都打印
  `bridge probe: log=… boot_id=… line_boot=… active=…`；进 C-lite 的那行改为
  `C-LITE MODE (bridge enabled in LSPosed): …`（`service.sh` 侧为
  `C-LITE mode: bridge handshake for this boot (…)` / `not C-lite: no bridge handshake for this boot (…)`）。
  改用日志 + boot id 的原因是桥接写不了标记文件：`/data/adb` 是 `drwx------ root root`，
  system_server（uid 1000）写不进去。v1.1 的 `/data/adb/axion_recents_stock_home` 因此彻底失效
  （还在也不读，升级用户可删）；`/data/adb/axion_recents_stock_home_kept` 仍会在探测成功时写入，
  但只是「本开机确实建起了 C-lite」的证据。桥接启用后若功能性探测（重建原厂桌面 + 确认补丁注入
  + 无崩溃，最长 12 轮 × 15 s）失败，依旧写 `_clite_state=failed` 并落回默认模式；
  `service.sh` 的 C-lite 看门狗也仍然等 settle 状态再计时。
* **切换 C-lite 只需在 LSPosed 里开关桥接 + 重启**：在 LSPosed 管理器里启用/停用「Axion 桌面桥接」
  （作用域 `系统框架 system` + `Moto 应用启动器 com.motorola.launcher3`）→ 重启。
  **不再需要 `touch /data/adb/axion_recents_stock_home`，也不再需要手工 `pm install`。**
* **桥接 APK 自动安装 / 自动升级**：`customize.sh` 刷入时尽力
  `pm install -r -d "$MODPATH/extras/motodesktop-helper.apk"`（装不了不中止，下次开机重试）；
  `service.sh` 每次开机在**看门狗之后**调用 `ensure_helper_installed()`：比较
  `extras/motodesktop-helper.apk` 与已装 `pm path com.axion.motodesktop` 的 base.apk 的 sha256，
  不一致才 `pm install -r -d` 重装。
* **LSPosed 自动同步 `apk_path`**：实测 `pm install -r` 之后 6 秒，`/data/adb/lspd/config/modules_config.db`
  里的 `modules.apk_path` 已指向新的 `/data/app/~~…==/…/base.apk`。数据库因此只需要
  `modules_state.enabled=1` + `scope` 两行，路径由 LSPosed 自己维护 —— v1.1 文档里
  「路径过期导致模块被静默跳过、必须重跑 `_clite_install.ps1`」的警告已过时。本地的
  `_tools/_clite_install.ps1` 现在只是命令行开关（`-Off` 关闭桥接），不在发布树里。
* **payload 换成 release 变体（方案 A）**：原厂系统侧的 launcher APK（`payload/AxionLauncher3.apk`）
  从 debug 换到 release —— 不再包含 LeakCanary（桌面图标库里的「Leaks」入口消失）、
  `android:debuggable` 为 false、应用名从 `Axion (Debug)` 变回 `Axion`；用同一个 release 签名密钥，
  签名身份不变（SHA-256 `F678407FB4B26B1AF63CCA614EEA6C8FEB08923D15C78AC930CD5FA7FE97EAD7`）。
  功能改动（build-77 的「桌面不再出现在最近任务里」等）全部保留。
* **诊断文件清理**：`service.sh` 新增 `diag_rotate()` ——
  `/data/adb/axion_recents_diag.log` 超过 512 KiB 就轮转成 `.old`（v1.1 里它只增不减，
  实测已经 1.65 MB）；`service.sh` 在 `kill $LOGCAT_PID` 之后删掉 logcat ring 文件
  `/data/adb/axion_logcat.txt*`（v1.1 残留约 26 MB：主文件 + `.1`/`.2`/`.3`）。
* **版本**：`module.prop` 的 `version=v1.2`、`versionCode=3`，发布 zip 变为
  `dist/AxionRecents-v1.2.zip`。

## v1.1 — C-lite 模式（原厂桌面 + Axion 最近任务）+ 最近任务修复

第二个公开发布版。模块默认行为与 v1.0 相同（Axion 同时当桌面和最近任务），新增可选的
**C-lite** 模式：原厂 Moto 桌面继续当 HOME，只把最近任务换成 Axion 的堆叠式。打包的 launcher
payload 也更新到 build-77（修掉"从桌面进最近任务会先闪一张透明桌面卡"，并包含 v1.0 之后的
文件夹预览修复）。

* **新模式**：`/data/adb/axion_recents_stock_home` 标记存在时，模块不再接管 HOME，
  原厂 `com.motorola.launcher3` 继续当桌面，RRO 仍把最近任务指到 Axion
  （`com.android.launcher3/com.android.quickstep.RecentsActivity`）。完整说明见
  [`docs/C-LITE.md`](docs/C-LITE.md)。
* **新增配套 LSPosed 模块** `moto-desktop-helper`（源码与本仓库同许可，见 [`helper/`](helper/)）：
  在 system_server 里对原厂桌面的 uid 放行 `MANAGE_ACTIVITY_TASKS` / `REMOVE_TASKS` /
  `ROTATE_SURFACE_FLINGER` 等 `recents` 标志权限，并给 `android.app.ContextImpl#getDisplay`
  加兜底 —— 解决"桌面不是 `config_recentsComponentName` 指向的包"时必崩的两处问题
  （权限拒绝；`ViewPool` 用 application context 预热 task view 撞上 Android 16 的 display 严格化）。
  预编译 APK 随 zip 分发（`extras/motodesktop-helper.apk`，签名密钥也在仓库里，
  可用 `helper/build-helper.ps1` 重建）。
* `boot-completed.sh`：C-lite 分支改成**带退避的功能性探测**（重建原厂桌面进程 + 确认补丁
  真的注入了该进程 + 焦点 + 无崩溃），成功后立刻补写健康标记 —— 否则 post-fs-data 的崩溃
  守卫会把"还没等到看门狗写标记的正常开机"误判成崩溃循环而停用模块。
* `service.sh`：新增 C-lite 看门狗（只观察 Axion quickstep 进程 / 原厂桌面进程 / 崩溃计数，
  **绝不 force-stop 原厂桌面**）；健康即写 `/data/adb/axion_recents_healthy`。并新增"等
  `boot-completed` settle 再开始计时"的等待循环，避免看门狗 160 s 窗口与上面最长达 4.4 min
  的探测**抢跑**（真机踩过一次：探测跑到第 4 轮就被看门狗回滚）。
* **桌面不再出现在最近任务里**（launcher APK 侧，`FallbackRecentsView`）：
  上游为"第三方桌面上手势快速切换"给 home 任务造的临时卡片（`showCurrentTask()` 里的运行任务
  stub + `applyLoadPlan()` 里追加的 `SingleTask(mHomeTask)`），在 Axion 的堆叠布局里会以
  **透明桌面卡**出现在栈中心，随后才被 dismiss 掉；现在 `shouldAvoidAddingStubTaskView()`
  对手势起点的 home 任务直接返回 true（并保留 build-76 起 `applyLoadPlan()` 不再追加 home 任务
  的改动），即**永远不为 home 任务创建 task view**。详见
  [`docs/C-LITE.md`](docs/C-LITE.md) 第 7 节。payload 对应 build-77：`42969707 B`，
  md5 `bc29e50ca1c8126ec66ba22627cb978b`。
* **文件夹预览外观修复**（launcher 侧，v1.0 之后）：
  * `PreviewBackground.getBgColor()` 只在 blur 真正可用时才用 Axion 的模糊表面色，
    否则回落到主题色 —— 本 port 的 `AxWindowBlurController.supportsBlur()` 恒为 false 且
    `AxBlurColors.surfaceEffect0()` 返回透明，单看 `LAUNCHER_BLUR_ENABLED`（默认 true）
    会让文件夹图标/预览背景被涂成透明；
  * `PreviewItemManager.buildParamsForPage()` 里 1×1 桌面文件夹保持经典裁剪式预览布局，
    workspace 快照布局只给多格文件夹 —— 修掉"1×1 文件夹第一次打开后预览尺寸变了且回不去"。
* **helper 的 `xposedscope` 声明改用 LSPosed 上游写法**：`["android", "com.motorola.launcher3"]`
  （原来写 `system`）。两者在核心/管理器里是同一个框架 scope，写成 `android` 与
  Iconify / XedgePro 等模块一致；声明里只有这两个真正需要的条目。
* **发布打包**：zip 新增 `extras/`（桥接 APK + `C-LITE.md`），`tools/build-zip.ps1` 会校验它
  在包里；README 增加 C-lite 安装步骤与 `helper/` 说明。`versionCode` 改为 2。

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

* 模块 `versionCode` 从 1 重新开始计数，与内部开发期的编号无关（内部开发期使用过 v1.0–v1.15）；
  v1.1 = `versionCode 2`。
* 仅在 Motorola Android 16（SDK 36）上测试；详见 README §2 的兼容性与已知限制。
