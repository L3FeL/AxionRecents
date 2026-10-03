# motodesktop-helper — 配套 LSPosed 模块（C-lite 模式用）

这个 APK 只做一件事：让 **原厂 Moto 桌面当 HOME 时也能安全地拉起 recents 手势**，
这样模块就可以把「最近任务」换成 Axion 的堆叠式，而桌面仍归 `com.motorola.launcher3`。

只有走 **C-lite** 模式才需要它（在 LSPosed 里启用它 + 重启即为 C-lite）。
默认模式（Axion 同时当桌面和 recents）**不需要**装它。

## 它改了什么

Android 16 里带 `recents` 标志的权限（`MANAGE_ACTIVITY_TASKS` = `signature|recents`、
`REMOVE_TASKS`、`ROTATE_SURFACE_FLINGER` …）只授予 `config_recentsComponentName` 指向的包
（判定点 `PermissionManagerServiceImpl.shouldGrantPermissionByProtectionFlags`）。
C-lite 下 recents 组件是 Axion，HOME 却是 Moto ⇒ Moto 一上手势就
`SecurityException: … requires android.permission.MANAGE_ACTIVITY_TASKS` 崩掉。
privapp 白名单和 `pm grant` 都救不了（前者只对 `privileged` 标志生效，后者是
`not a changeable permission type`），所以只能在 system_server 里改判定：

* `android`（系统框架）作用域：hook `ActivityManagerService.checkComponentPermission` /
  `checkPermission` / `enforceCallingPermission` 与
  `PermissionManagerServiceImpl.shouldGrantPermissionByProtectionFlags`，
  对 uid = `com.motorola.launcher3` 判为已授予；
* `com.motorola.launcher3`（原厂桌面进程）作用域：给 `android.app.ContextImpl#getDisplay`
  兜底 —— Moto 用 application context 预热 task view pool 时会抛
  `UnsupportedOperationException: Tried to obtain display from a Context not associated with one`；
  另外修好 C-lite 下被 RRO 连带关掉的两个桌面手势（v1.2.1 起）：
  * `SystemUiProxy#isActive` / `#onStatusBarTouchEvent` —— 原厂桌面的触摸流本来要转给 SystemUI
    拖动帷幕，但 C-lite 下 `mSystemUiProxy == null`（SystemUI 绑的是 Axion 的
    `TouchInteractionService`），`isActive()` 恒 false ⇒ 桌面下滑连拦截都进不去。桥接只在
    proxy 为 null 时把 `isActive()` 判为 true，并在抬手时按位移改调
    `StatusBarManager.expandSettingsPanel(null)`（长滑）/ `expandNotificationsPanel()`（短滑）；
  * `SystemUiProxy#lockDevice` —— 同一个 null proxy 让「双击空白处息屏」在
    `WorkspaceTouchListener.lockScreen()` 里静默 return；桥接改调
    `PowerManager.goToSleep(SystemClock.uptimeMillis())`；
  * 为此在 system_server 侧给原厂桌面的 uid 追加放行 `android.permission.DEVICE_POWER` 与
    `android.permission.EXPAND_STATUS_BAR`（两者都不在原厂桌面 manifest 里）；
  * `Utilities#isSleepScreenEnabled` 的 after-hook 只在 `put_display_to_sleep` 完全未设置时兜底。

  机制、阈值实测表与验证命令见 [`../docs/C-LITE.md`](../docs/C-LITE.md) 第 8 节。

## 作用域声明（`xposedscope`）

`res/values/arrays.xml` 里声明的就是这两个：`android` 与 `com.motorola.launcher3`。
`android` 是 LSPosed 上游对「系统框架」的写法，核心会把它规范化成数据库里的
`scope('…','system',0)` 行（可对照 `com.drdisagree.iconify` 声明
`["android","com.android.systemui"]`、`com.jozein.xedgepro` 声明 `["android"]`）。
**其余应用一个都不需要**，不要为了图省事把声明扩成一大串。

## 构建

```powershell
# 需要 Android SDK（build-tools 36 与 platforms/android-36）与 JDK 17+
pwsh -File helper\build-helper.ps1 -SdkRoot "$env:ANDROID_SDK_ROOT" -JdkHome "$env:JAVA_HOME"
# 输出：helper\dist\motodesktop-helper.apk（用 helper\keystore\axion-moto.jks 签名）
#       + helper\dist\motodesktop-helper.prop（实际烘焙进 APK 的 version/versionCode）
```

版本取自 **`helper/helper.prop`**（不是 `../module.prop`）：只有桥接代码/资源真的改了才递增它，
这样「只改模块脚本」的版本升级不会重装桥接 APK —— 每次重装都会换 `/data/app` 路径，
而 LSPosed 缓存的旧路径一旦失效它会**静默跳过**本模块，C-lite 就无声失效
（`docs/C-LITE.md` §6.2）。构建脚本会把 aapt2 实际烘焙进 APK 的版本回写成
`dist/motodesktop-helper.prop`，与 APK 不一致时会打 WARNING（`AndroidManifest.xml` 里写死
`versionCode`/`versionName` 会盖过命令行参数，所以那两个属性已经删掉了）。

流程是 `aapt2 compile/link → javac → d8 → 注入 classes.dex → zipalign → apksigner`，
四个类一个字符串数组，不值得上 Gradle。`stubs/` 里是 LSPosed 编译期接口（不打包进 dex 之外）。

## 安装（C-lite）

刷入 **axion_recents** 模块时会**自动安装本 APK**：`customize.sh` 尽力执行
`pm install -r -d "$MODPATH/extras/motodesktop-helper.apk"`（装不上也不中止刷入，下次开机重试）；
`service.sh` 每次开机会调用 `ensure_helper_installed()`，读模块根目录的 `helper.prop`
（打包时由 `dist/motodesktop-helper.prop` 复制而来）拿到目标 `versionCode`，**只有已装版本更低
时才**重装。刷完后它位于设备上
`/data/adb/modules/axion_recents/extras/motodesktop-helper.apk`。

你只需要：

1. 在 LSPosed 管理器里**启用**「Axion 桌面桥接」；
2. 作用域勾 `系统框架 system` 与 `Moto 应用启动器 com.motorola.launcher3`
   （详情页里这两行会标「推荐应用」）；
3. **重启**（启用即 C-lite，停用即默认模式，不再需要 `touch` 任何标记文件）。

**不需要**手工 `pm install`，也**不需要**在 LSPosed 数据库里对齐 `apk_path`：v1.2 起 LSPosed 会
自己刷新该字段（实测 `pm install -r` 之后约 6 秒，`/data/adb/lspd/config/modules_config.db` 里的
`modules.apk_path` 已指向新的 base.apk）。完整步骤见 [`../docs/C-LITE.md`](../docs/C-LITE.md)。

## 许可

与仓库其它部分一致：**GPL-3.0**（见 [`../LICENSE`](../LICENSE)）。
