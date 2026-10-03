# Changelog

## v1.2.2 — 删除「自动停用/熔断/自动回滚」机制（真机误判修复）

v1.2.1 的 bug 修复版：删掉模块的自我保护机制（并自动清理误判留下的 `disable` 标记），
另外给 payload 补上 C-lite 的「最近任务 → 桌面」缩放淡出动画，并让模块能自己修好 LSPosed
缓存路径（不再是只报警告）。

* **事故**：2026-10-03 开机后模块正常挂载并进入 C-lite（11:19:18 探测 `moto pid=13057
  focused=1 crashes=0 patch_loaded=2`，健康标记已写）。11:20:57 C-lite 看门狗的一次采样里
  `pidof com.motorola.launcher3` 恰好为空（原厂桌面在开机早期本来就会因重建进程而换 pid：
  7849 → 12217 → 13057，最后一次才拿到 LSPosed 补丁），看门狗把它判成「原厂桌面进程不在」
  ⇒ `ax_rollback()` 关 RRO（静态 RRO 运行时关不掉，报 SecurityException，预期）、把 HOME
  还原厂、写 `/data/adb/modules/axion_recents/disable` 与 `_crashloop` 标记，并**自动重启**。
  重启后 `post-fs-data.sh` 见到 crashloop 标记就「跳过全部挂载」并**再写一次 disable** ⇒
  KernelSU 里永远显示「未启用」，用户手动启用再重启也没有用（还必须同时删掉 `_bootcount`，
  否则下一次守卫仍会停用）。那一次采样 `launcher_crashes=0 systemui_crashes=0`、无 tombstone、
  无 LMK 记录 —— 是纯误判。
* **现在的口径**：**每次开机都照常挂载**。异常只写日志与
  `/data/adb/axion_recents_needs_attention` 标记，绝不自己停用模块、绝不跳过挂载、绝不自动重启。
  要停用模块请在 KernelSU 管理器里手动关掉（或删模块目录）再重启。
* **删掉的东西**：`post-fs-data.sh` 的开机失败守卫（`HEALTHY`/`BOOTCOUNT` 判定 + `touch disable
  + exit 0`）与 `_crashloop` 分支；`service.sh` 的 `ax_rollback()`（关 RRO + 还原 HOME + 写
  disable/crashloop + `reboot`），三个看门狗函数（`watchdog` / `watchdog_clite` /
  `watchdog_passive`）的不健康分支改成只打 `WARN` 行（原来会 `return 1` 触发回滚），FATAL
  分支与被动分支里的 `touch "$MODDIR/disable"`、`cmd overlay disable` 移除；
  `boot-completed.sh` 的 FATAL 分支同样改为「把 HOME 交还原厂 + 写 needs_attention + 退出」。
* **新增**：`service.sh` 的 `restore_stock_home()`（把 HOME 交回
  `com.motorola.launcher3/com.android.launcher3.CustomizationPanelLauncher`、记 HOME 与 pid、
  写 `needs_attention`；不写 disable、不重启）；`post-fs-data.sh` 每次开机清掉遗留的
  `_bootcount` / `_rebooted` / `_crashloop` 标记，并在发现 `$MODDIR/disable` 时提示用户去
  KernelSU 里重新启用；`customize.sh` 安装时删除遗留标记与 `disable` 文件（否则覆盖安装后
  管理器里仍显示「未启用」）。
* **代价（须知）**：如果 payload 真的导致桌面起不来，模块不会再自我停用，需要用户自己在
  KernelSU 里停用模块（或删 `/data/adb/modules/axion_recents/`）后重启；日志里会留下
  `needs_attention` 标记与原因行。我们选择这条路是因为自动停用已经在真机上误判过一次，
  代价大于收益。
* **顺带修掉一个静默失效**：`helper/AndroidManifest.xml` 里原来写死的 `versionCode` /
  `versionName` 会**盖过** aapt2 link 的 `--version-code/--version-name`，所以「桥接版本自动
  同步 module.prop」从来没真正生效（APK 里一直是旧值）。现已把这两个属性从 manifest 删掉。
* **桥接 APK 版本独立**：新增 `helper/helper.prop`（`version` / `versionCode`）作为桥接的唯一
  版本源；`helper/build-helper.ps1` 只读它，并把**实际烘焙进 APK** 的版本回写成
  `helper/dist/motodesktop-helper.prop`，打包时以 `helper.prop` 放进模块根目录（本次 =
  `1.2.2` / `5`）。以后只有改 `Main.java` 或桥接资源时才递增它，模块自己的版本怎么涨都不影响。
* **不再无谓重装桥接（第二个 C-lite 静默失效的根因）**：每次 `pm install` 都会给 APK 换一个
  `/data/app/~~<随机>/…` 路径，而 LSPosed 加载的是它自己在
  `/data/adb/lspd/config/modules_config.db` 里记下的旧路径 —— 路径一失效它就**静默跳过**这个
  模块：LSPosed 日志里一行 `AxionDesktopBridge` 都没有，`service.sh` 探针 `active=0`，于是这次
  开机走默认模式（HOME 回到 Axion），C-lite 无声失效。本次真机就是这么坏的。
  现在 `customize.sh` 与 `service.sh` 都只比较 `helper.prop` 的 `versionCode`：已装版本 ≥ zip 里
  的版本就**原样不动**已装的 APK；只有真的需要重装时，才额外比对 LSPosed 缓存路径与
  `pm path` 的实际路径，不一致时**模块自己把它修回去**（见下条），只有修不了才打印醒目
  WARNING 并写 `needs_attention` 标记，提示用户打开 LSPosed 把 `Axion Desktop Bridge`
  关掉再打开、然后重启。详见 `docs/C-LITE.md` §6.2。
* **模块能自己修 LSPosed 缓存路径了（不再只是报警告）**：新增 `helper/lspd-fix.jar`
  （`LspdPathFix`：`app_process` + 框架 `SQLiteDatabase`，`-get <db> <pkg>` 读、
  `<db> <pkg> <apk>` 写并复核，写操作带 10×200 ms 打开重试；**不需要设备上有 `sqlite3`**）。
  `service.sh` 的 `lsposed_cached_path()` 先问它、失败才回落到原来的 `grep -a` 读法；
  `check_lsposed_path()` 检测到陈旧 → `repair_lsposed_path()` 写入真实路径 → 再读复核，
  成功记 `fixed : the cached path now matches the installed bridge`，失败才写 `needs_attention`。
  真机验证：对 `/data/local/tmp` 里的 DB 副本注入假路径后跑真实函数链，输出
  `cached : /data/app/~~STALE==/…` → `repair : rc=0 fixed: … -> …` → `fixed : …`，副本里的行
  随之变成真实路径；DB 正常时再一次运行只留下标题行（静默）。详见 `docs/C-LITE.md` §10。
* **payload（桌面 APK）**：C-lite 的「最近任务 → 桌面」转场新增内容缩放淡出动画 —— 动画
  `RecentsDragLayer`（`scale 1.0 → axion_home_reveal_zoom`，默认 **1.4**；`alpha 1.0 → 0`，
  `axion_home_reveal_alpha` 默认 0；`axion_home_reveal_duration` 默认 **250 ms**，即平台
  本身的转场时长），scale 用桌面手势曲线、alpha 用后置曲线（0.55,0,1,1），动画期间给该层开
  硬件层并在结束时清掉，且动画未结束前吞掉新的按下事件。修掉了旧版「动画结束后整层回闪一帧」
  的问题（复位不能放在转场结束回调里，改到 `onStart()`）。`axion_home_reveal_enabled=0`
  可整体关掉。详见 `docs/C-LITE.md` §9；三个设置键改完立即生效，不需要重装。
* **payload（桌面 APK，build-88）**：C-lite 下「从原厂桌面上滑进最近任务」不再跟手 —— 手势处理器
  `OtherActivityInputConsumer` 在首次越过 slop 时，如果 running task 是**别的桌面 App 的 HOME
  任务**（`runningTask.isHomeTask && !isHomeAndOverviewSame()`，只在 C-lite 成立），就直接执行
  `OverviewCommandHelper` 的 `TOGGLE`（= 最近任务键 / `KEYCODE_APP_SWITCH` 那条路）并停掉本帧
  后续处理：不启动交互式 recents 动画、不把位移喂给手势 handler，手指停在哪都不影响结果（实测
  400 px 的短上滑也直接完整进入最近任务）。斜向/水平 swipe（夹角 ≤ 15°）、触控板手势，以及默认
  模式（home == overview）行为全部不变；从**应用**上滑的跟手动画回归验证无变化。详见 §11。
* **版本**：`module.prop` 的 `version=v1.2.2`、`versionCode=5`，发布 zip 为
  `dist/AxionRecents-v1.2.2.zip`。

## v1.2.1 — C-lite 下恢复原厂桌面的两个手势（双击桌面息屏 / 桌面下滑控制中心）

v1.2 的 bug 修复版：没有新功能，默认模式（Axion 同时当桌面和最近任务）行为与 v1.2 完全一致，
只更新 C-lite 用的桥接 APK，把 C-lite 下被 RRO 连带关掉的两个原厂桌面手势接回来，并给桥接补上
「抬手时决定展开控制中心还是通知栏」的判定。

* **双击桌面空白处息屏**：C-lite 下原厂桌面进程里 `SystemUiProxy.mSystemUiProxy == null`
  （SystemUI 绑的是 Axion 的 `TouchInteractionService`），`WorkspaceTouchListener.lockScreen()` 走到
  `SystemUiProxy.lockDevice(true)` 时在 `if (mSystemUiProxy != null)` 处**静默 return**。桥接新增
  `SystemUiProxy#lockDevice` hook：proxy 为 null 时改调
  `PowerManager.goToSleep(SystemClock.uptimeMillis())`，并为原厂桌面的 uid 放行
  `android.permission.DEVICE_POWER`（其 manifest 里没有该权限；enforcement 在 system_server，
  走桥接已有的权限漏斗）。
* **桌面下滑拉出控制中心/通知**：`StatusBarTouchController.canInterceptTouch()` 最后一句是
  `return SystemUiProxy.INSTANCE.get(mLauncher).isActive();`，null proxy 下恒 false ⇒ 触摸流连拦截
  都进不去。桥接新增 `SystemUiProxy#isActive`（仅在 proxy 为 null 时改写为 true）与
  `SystemUiProxy#onStatusBarTouchEvent`（proxy 为 null 时改调
  `StatusBarManager.expandSettingsPanel(null)` / `expandNotificationsPanel()`）两个 hook，并放行
  `android.permission.EXPAND_STATUS_BAR`。阈值 `CONTROL_CENTRE_TRAVEL_PX = 240f`，按**转发触摸流**
  的位移算（原厂会把 slop 之后的第一帧改写成 `ACTION_DOWN` 再转发，所以起点已在屏幕中段）：
  真机实测屏幕拖动 300–550 px → 通知栏、≥ 约 570 px → 控制中心；每次抬手打一行
  `swipe down: downY=… travel=…px -> control centre|notifications`（`adb logcat -s AXMOTO:*`）。
  因为 SystemUI 的 `ISystemUiProxy` 不是系统服务、拿不到 binder，C-lite 下无法像原厂那样逐帧
  转发做跟手拖动，只能在抬手时二选一展开。
* **`Utilities#isSleepScreenEnabled` 兜底 hook**：只在 `put_display_to_sleep` 完全**未设置**（读到
  null）时放开，已有设置值时保持原厂语义 —— 本机实测原厂值就是 `"1"`，所以这层是纯兜底
  （也能解释「`settings get global put_display_to_sleep` 为 null 但双击照样坏」的现象：原厂是
  从 `MotorolaSettings` 自己的 provider 读的）。
* **默认模式/正常绑定不受影响**：4 个 hook 只装在 `com.motorola.launcher3` 进程，且每个都先检查
  `mSystemUiProxy`（读不到字段则视为「有代理」，保持原厂路径）；`isActive` 只在 false 时改写。
* 详细机制、阈值实测表与验证步骤见 [`docs/C-LITE.md`](docs/C-LITE.md) 第 8 节。
* **版本**：`module.prop` 的 `version=v1.2.1`、`versionCode=4`，发布 zip 变为
  `dist/AxionRecents-v1.2.1.zip`；桥接 APK 的 `versionCode` / `versionName` 也由
  `helper/build-helper.ps1` 从 `module.prop` 自动同步（本次 = `4` / `1.2.1`）。

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
  > **v1.2.2 更正**：这条**是错的**。当时那次"6 秒就同步"其实是同一次实验里手工重跑
  > `_clite_install.ps1`（它会把模块开关重写一遍）造成的假象。真机复现的结果是：路径一旦
  > 不存在，LSPosed 就**静默跳过**该模块，既不报错也不自愈 —— 详见 v1.2.2 段与
  > `docs/C-LITE.md` §6.2。
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
