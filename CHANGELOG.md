# Changelog

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
