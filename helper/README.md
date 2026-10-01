# motodesktop-helper — 配套 LSPosed 模块（C-lite 模式用）

这个 APK 只做一件事：让 **原厂 Moto 桌面当 HOME 时也能安全地拉起 recents 手势**，
这样模块就可以把「最近任务」换成 Axion 的堆叠式，而桌面仍归 `com.motorola.launcher3`。

只有走 **C-lite** 模式才需要它（标记文件 `/data/adb/axion_recents_stock_home` 存在）。
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
  `UnsupportedOperationException: Tried to obtain display from a Context not associated with one`。

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
```

流程是 `aapt2 compile/link → javac → d8 → 注入 classes.dex → zipalign → apksigner`，
四个类一个字符串数组，不值得上 Gradle。`stubs/` 里是 LSPosed 编译期接口（不打包进 dex 之外）。

## 安装（C-lite）

模块 zip 里已经带上这个 APK（`extras/motodesktop-helper.apk`，刷完模块后在设备上位于
`/data/adb/modules/axion_recents/extras/`）：

```bash
adb push motodesktop-helper.apk /data/local/tmp/
adb shell su -c 'pm install -r /data/local/tmp/motodesktop-helper.apk'
```

**必须用经典 `pm install`，不要用 `adb install`（incremental）**：incremental 的
`/data/app/~~…==/…/base.apk` 路径每次重启会变，而 LSPosed 的
`/data/adb/lspd/config/modules_config.db` 记的是绝对路径，对不上它会**静默跳过**整个模块。

然后在 LSPosed 管理器里启用「Axion 桌面桥接」，作用域勾 `系统框架 system` 与
`Moto 应用启动器 com.motorola.launcher3`（详情页里这两行会标「推荐应用」），
再 `touch /data/adb/axion_recents_stock_home` 并重启。完整步骤见
[`../docs/C-LITE.md`](../docs/C-LITE.md)。

## 许可

与仓库其它部分一致：**GPL-3.0**（见 [`../LICENSE`](../LICENSE)）。
