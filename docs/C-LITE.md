# C-lite 模式：原厂桌面 + Axion 最近任务

> 目标（用户口径）：**桌面用 Moto 自带的（`com.motorola.launcher3`），最近任务用本模块带进来的 Axion 堆叠式**
> （`com.android.launcher3`）。两个包名不同，可以共存。

本模块有两种模式，靠 **LSPosed 里是否启用配套桥接模块 + 重启** 切换：

| 模式 | 触发条件 | HOME | 最近任务 |
| --- | --- | --- | --- |
| 默认（v1.0 行为） | 桥接未启用（或本开机没有握手） | `com.android.launcher3`（Axion） | Axion |
| **C-lite** | LSPosed 里启用了桥接，且**本开机**有握手 | `com.motorola.launcher3`（原厂） | Axion |

### v1.1 的标记文件已废弃（v1.2 起）

v1.1 用 `/data/adb/axion_recents_stock_home` 这个文件的存在与否当开关。v1.2 **完全废弃**了它：
该文件即使还在也**不再被读取**（升级用户可以删掉，无害）。

原因是桥接没法自己写标记文件：`/data/adb` 是 `drwx------ root root`，system_server（uid 1000）
**写不进去**，所以桥接改用 **LSPosed 日志 + boot id** 反向证明自己在本开机跑起来了 —— 见第 3 节。

RRO 与 priv-app 镜像两种模式都一样：`config_recentsComponentName` 始终指向
`com.android.launcher3/com.android.quickstep.RecentsActivity`。

## 1. 为什么需要那个 LSPosed 模块

Android 16 里带 `recents` 标志的权限（`MANAGE_ACTIVITY_TASKS` = `signature|recents`、
`REMOVE_TASKS` = `signature|recents|role`、`ROTATE_SURFACE_FLINGER` = `signature|recents` …）
**只授予 `config_recentsComponentName` 指向的那个包**，判定点在
`PermissionManagerServiceImpl.shouldGrantPermissionByProtectionFlags`
（`bp.isRecents() && getKnownPackageNames(PACKAGE_RECENTS)`）。

C-lite 下 HOME 是 Moto，但 recents 组件是 Axion ⇒ Moto 拿不到这些权限，一起手就崩：

```
FATAL EXCEPTION: main
java.lang.RuntimeException: Unable to start activity ...QuickstepLauncher:
  java.lang.SecurityException: Permission Denial: getRootTaskInfo() from pid=…, uid=10266
  requires android.permission.MANAGE_ACTIVITY_TASKS
  at com.android.quickstep.RecentsAnimationDeviceState.<init>(…:263)
```

`privapp-permissions-*.xml` 白名单**没用**（白名单只对带 `privileged` 标志的权限生效），
`pm grant` 也没用（`not a changeable permission type`）。所以只能由 **LSPosed 模块在
system_server 里把这个判定改掉**：`moto-desktop-helper` 挂
`ActivityManagerService.checkComponentPermission` / `checkPermission` /
`enforceCallingPermission` 与 `PermissionManagerServiceImpl.shouldGrantPermissionByProtectionFlags`，
对 uid = `com.motorola.launcher3` 判为已授予。

它同时兜住第二处崩溃（Moto 用 application context 预热 task view pool）：

```
UnsupportedOperationException: Tried to obtain display from a Context not associated with one
  ← ContextImpl.getDisplay ← ScreenDecorationsUtils.getPhysicalPixelDisplaySizeRatio
  ← QuickStepContract.getWindowCornerRadius ← TaskView$FullscreenDrawParams.<init>
```

⇒ 模块同时 hook `android.app.ContextImpl#getDisplay`，只在该异常上返回默认显示器
（返回的 display 只用来算圆角半径，属外观量）。

## 2. 安装

前提：KernelSU（本模块，v1.1+）+ LSPosed（Zygisk Next 版本即可）。

桥接 APK 随模块 zip 分发，**刷入时会自动装好**：`customize.sh` 尽力执行
`pm install -r -d "$MODPATH/extras/motodesktop-helper.apk"`（装不上也不中止刷入，下次开机重试）；
之后 `service.sh` 每次开机都会调用 `ensure_helper_installed()`，读模块根目录的 `helper.prop`
（由 `helper/build-helper.ps1` 从实际产物生成）拿到目标 `versionCode`，与设备上已装
`com.axion.motodesktop` 的版本比较：**只有已装版本更低时才** `pm install -r -d` 重装。
版本相同就原样不动 —— 这是有意的：重装会把 APK 换到新的 `/data/app/…` 路径，而 LSPosed
缓存的旧路径随即失效、C-lite 会静默失效（§6.2）。
刷完后它就在设备上 `/data/adb/modules/axion_recents/extras/motodesktop-helper.apk`
（仓库里是 [`helper/`](../helper/)，可用 `helper/build-helper.ps1` 重建）。
**不需要**手工 `pm install`。

也可以手工照下面做（这里记录的是开发机上的一键脚本，做的是「装桥接 + 写数据库」，
本地调试用；它不在发布树里）：

```powershell
pwsh -NoProfile -File 'D:\Download\dsh\_tools\_clite_install.ps1'
# 加 -Off 则关闭桥接；然后重启
adb -s <serial> reboot
```

脚本做的事：

1. `adb push motodesktop-helper.apk /data/local/tmp/` → `su -c "pm install -r /data/local/tmp/motodesktop-helper.apk"`。
   `pm install -r -d` 走的是经典安装，装出来的 base.apk 路径稳定；`adb install`（incremental）
   的路径每次重启会变。
2. 读 `pm path com.axion.motodesktop`，把设备上的
   `/data/adb/lspd/config/modules_config.db` 拉回主机，写入
   `modules_state('com.axion.motodesktop', user 0, enabled=1)`、
   `scope('…','system',0)` 与 `scope('…','com.motorola.launcher3',0)`，
   再推回设备（chown 0:0 / chmod 600，删掉 `-wal`/`-shm`）。
   **v1.2 起不需要再对齐 `modules.apk_path`**：LSPosed 会自己刷新这个字段 ——
   实测 `pm install -r` 之后约 6 秒，数据库里的 `apk_path` 已指向新的
   `/data/app/~~…==/…/base.apk`。数据库只需要 `modules_state.enabled=1` 与 `scope` 两行，
   路径由 LSPosed 自己维护（v1.1 文档里「路径过期会被静默跳过、必须重跑脚本」的警告已过时）。
   系统框架在 LSPosed 数据库里存的 scope 名是 **`system`**（`scope('…','system',0)`），
   但模块 APK 里**声明**（`xposedscope`）的是 `android` —— 这是 LSPosed 上游约定
   （`com.drdisagree.iconify` 声明 `["android","com.android.systemui"]`、
   `com.jozein.xedgepro` 声明 `["android"]`，它们的数据库 scope 行同样落成 `system`），
   核心会把 `android` 规范化成框架 scope。声明里**只有两个**条目：
   `android`（系统框架 = system_server 里的权限放行 hook）+ `com.motorola.launcher3`
   （原厂桌面进程里的 `ContextImpl#getDisplay` 兜底），其余应用一个都不需要。
3. 清掉守卫用的 `/data/adb/axion_recents_bootcount` 与
   `/data/adb/modules/axion_recents/disable`（**不再需要 `touch` 任何标记文件**）。

### 从 LSPosed 管理器手工启用（不用脚本时）

1. `com.axion.motodesktop` 装好后（刷模块时已自动装好）打开 LSPosed 管理器；
2. 启用「Axion 桌面桥接」，作用域只勾 `系统框架 system` 与
   `Moto 应用启动器 com.motorola.launcher3`（详情页里这两行会标「推荐应用」）；
3. 重启。启用即 C-lite，停用即默认模式。

## 3. 开机会发生什么

1. `post-fs-data.sh`：magic mount priv-app 镜像 + 权限白名单 + 静态 RRO；
   并清掉 `/data/adb/axion_recents_clite_state`（本次开机的 C-lite settle 状态）。
2. `boot-completed.sh`（模式判定 —— 原来是看标记文件，v1.2 换成**桥接握手**）：

   ```sh
   BRIDGE_LOG=$(ls -t /data/adb/lspd/log/modules_*.log 2>/dev/null | head -1)
   BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
   bridge_active=0
   bridge_boot=""
   if [ -n "$BRIDGE_LOG" ] && [ -n "$BOOT_ID" ]; then
       bridge_boot=$(grep -a -o 'AxionDesktopBridge active in system_server[^=]*boot=[0-9a-fA-F-]*' "$BRIDGE_LOG" 2>/dev/null | tail -1 | sed 's/.*boot=//')
       if [ -n "$bridge_boot" ] && [ "$bridge_boot" = "$BOOT_ID" ]; then
           bridge_active=1
       fi
       log "bridge probe: log=$BRIDGE_LOG boot_id=$BOOT_ID line_boot=${bridge_boot:-<none>} active=$bridge_active"
   fi
   ```

   这段（`service.sh` 里逐字相同）是新的模式判定，取代原来的 `if [ -f "$STOCK_HOME" ]`：

   * 桥接在 system_server 里载入成功时会调用
     `XposedBridge.log("AxionDesktopBridge active in system_server hooks=" + sHookCount + " boot=" + readBootId())`；
     LSPosed 只有对**调用 `XposedBridge.log()` 的模块**才会把日志落到
     `/data/adb/lspd/log/modules_<本开机时间戳>.log`；
   * 脚本取**最新**的那个 modules 日志，把里面 `boot=` 的值与
     `/proc/sys/kernel/random/boot_id` 比较：一致 ⇒ 本开机的桥接真的在 system_server 里跑着 ⇒ 进 C-lite；
     不一致或读不到 ⇒ 留在默认模式（安全默认）。
   * 因为比的是 boot id，**旧开机留下的日志不可能把本次开机误判成 C-lite**。
   * 桥接自己没法留标记文件：`/data/adb` 是 `drwx------ root root`，system_server（uid 1000）
     写不进去 —— 这是改用日志 + boot id 的原因。

   命中后（C-lite 分支）：
   * 把 settle 状态写成 `pending`（`echo pending > /data/adb/axion_recents_clite_state`），
     并删掉上一次开机的 `/data/adb/axion_recents_stock_home_kept`；
   * 确认我们这条 `apk_path` 还在 LSPosed 的 `modules_config.db` 里（不在就写 WARNING：
     LSPosed 会静默跳过路径失效的模块，权限/显示补丁全部不生效；v1.2 起 LSPosed 会自己同步
     路径，所以正常情况下不会再触发这条）；
   * `HOME role → com.motorola.launcher3`，**重建**原厂桌面进程（`am force-stop` + `am start`）；
   * 功能性探测（最多 12 轮、每轮退避 15 s）：原厂桌面进程活着 + 有焦点 + 无崩溃 +
     **补丁真的进了该进程**（`logcat -s AXMOTO` 里有 `module loaded pkg=com.motorola.launcher3`）；
     这里的 `patch_loaded` 判据就是上面那个握手行 / `AXMOTO granted`；
   * 成功才写 settle 状态 `ok <时间>`、`/data/adb/axion_recents_stock_home_kept` 与健康标记；
     失败写 `failed` 并回退到 v1.0 行为（把 HOME 交给 Axion），保证设备一定能用。
     `_stock_home_kept` 现在只是「本开机确实建起了 C-lite」的**证据**，不再参与模式判定。
3. `service.sh`：先**等 boot-completed settle**（轮询 `_clite_state`，最多 20×15 s = 300 s；
   中途发现 HOME 已不是原厂桌面、或状态是 `failed`，就自己切回旧模式分支），然后才是
   C-lite 看门狗（8×20 s，只看 Axion quickstep 进程、原厂桌面进程、崩溃计数；
   **绝不 force-stop 原厂桌面**），结束后写 `/data/adb/axion_recents_healthy`。

> 为什么 `service.sh` 必须等：看门狗的观察窗口只有 160 s，而上面的探测最多要
> 12 轮 ≈ 4.4 min，两者是**并发**的。早先看门狗在自己的 160 s 窗口里看不到原厂桌面进程
> 就回滚（当时会写 `disable` + 一键重启回原厂），把还没跑完的探测打断 —— 真机
> 踩过一次（18:45 那次开机：探测跑到 #4 就被回滚掐了）。settle 状态文件把这两段串起来。

> **v1.2.2：看门狗只记录，不再动手。** 2026-10-03 又一次真机事故把它彻底关掉了：C-lite 下
> 原厂桌面在开机早期会因为重建进程而换 pid（7849 → 12217 → 13057），看门狗某一次采样恰好
> `pidof` 为空，就判成「原厂桌面进程不在」并回滚 + 写 `disable` + 自动重启；此后每次开机
> `post-fs-data.sh` 见 `_crashloop` 又写一次 `disable` ⇒ KernelSU 里永远显示"未启用"。
> 现在三个看门狗函数只打 `WARN` 行；唯一的救急动作是 `restore_stock_home()`（把 HOME 交回
> 原厂 + 写 `needs_attention` 标记，不停用模块、不重启）。

> 为什么要"重建进程 + 检查补丁"而不是一次性判断：实测开机早期由系统拉起的原厂桌面进程
> **拿不到** LSPosed 补丁（`patch_loaded=0`，uptime 41 s / 63 s / 86 s / 108 s …），要到
> uptime 90 s 以上（慢的一次到 249 s）重建进程才稳定拿到（`patch_loaded=2`）。

## 4. 验证

```bash
adb shell su -c 'grep -E "probe #|done \(c-lite|watchdog\(c-lite\)" /data/adb/axion_recents.log | tail -20'
adb shell su -c 'cmd role get-role-holders --user 0 android.app.role.HOME'        # com.motorola.launcher3
adb shell su -c 'cmd overlay lookup android android:string/config_recentsComponentName'
#   com.android.launcher3/com.android.quickstep.RecentsActivity
adb shell su -c 'dumpsys activity services com.android.quickstep.TouchInteractionService | grep -A2 ServiceRecord'
#   绑定方应是 com.android.systemui（即 Axion 的手势宿主）
adb shell su -c 'logcat -d -s AXMOTO | grep -c granted'                            # > 0
adb shell input keyevent 187                                                        # 出 Axion 堆叠卡
```

期望的开机日志：

```
[boot-completed] bridge probe: log=/data/adb/lspd/log/modules_20260101_120000.log boot_id=9f2c…-… line_boot=9f2c…-… active=1
[boot-completed] C-LITE MODE (bridge enabled in LSPosed): HOME=com.motorola.launcher3 recents=com.android.launcher3
[boot-completed]   probe #1 : moto pid= focused=0 crashes=0 patch_loaded=0 uptime=41s
[boot-completed]   probe #3 : moto pid=11010 focused=1 crashes=0 patch_loaded=2 uptime=91s
[boot-completed] done (c-lite: HOME untouched, recents = com.android.launcher3, healthy marker written)
[service] watchdog(c-lite): t=8x20s axion=3980 moto=11010 launcher_crashes=0 systemui_crashes=0
[service] watchdog(c-lite): window finished after 160s (…)
```

## 5. 已知代价 / 限制

* **转场动画降级**：桌面不是"最近任务组件"，`OverviewComponentObserver` 走
  `FallbackActivityInterface`：上滑只剩"窗口缩小淡出 + 启动 `RecentsActivity`"的一次性转场，
  丢的是**手势连续性**（窗口不跟手、悬停不预览、同手势横滑切换没有），堆叠卡/全部清除/锁定/
  截屏/自由窗口都还在。想要一体化动画就只能让 Axion 同时当桌面（默认模式）。
* **开机早期原厂桌面可能闪崩几次**：补丁注入要等到 uptime ≈90 s（慢的一次 249 s），这之前的
  原厂桌面进程会因为同一处 `MANAGE_ACTIVITY_TASKS` 崩溃反复重启；`boot-completed` 会带退避地
  重建进程直到补丁真的进进程（最多 12 轮 ≈ 4.4 min），成功后即稳定。代价是开机的头几分钟
  桌面可能不可用，且 `service.sh` 的看门狗要等 settle 才开始计时。
* **helper APK 由模块自己维护**：v1.2.2 起 `service.sh` 每次开机读模块根目录的 `helper.prop`
  （桥接自己的版本号），只有**已装版本低于**模块里那份时才重装；版本相同就原样不动。
  v1.2 的做法是比对 sha256，但构建本身不可复现（同样的源码每次产出的 APK 字节都不同），
  于是每次升级都会重装一次 —— 而每次重装都会把 APK 换到新的 `/data/app/~~…/` 路径，
  LSPosed 缓存的旧路径随即失效，它会**静默跳过**这个模块、C-lite 无声失效
  （v1.2 的更新日志里曾写"LSPosed 会自动同步 `apk_path`"，**实测并不会**，见 §6.2）。
  所以现在：桥接版本不变 ⇒ 不重装 ⇒ 路径不动 ⇒ 升级模块不会影响 C-lite。
  本地那个 `_tools/_clite_install.ps1` 现在只是命令行开关（默认开启桥接，`-Off` 关闭），
  等价于在 LSPosed 管理器里点一下。
* 系统 OTA / 重装 KernelSU 之后需要重新做第 2 步。

## 6. 回滚

```bash
# 1) 关掉 C-lite（回到 v1.0 行为：Axion 桌面 + Axion 最近任务）
#    在 LSPosed 管理器里停用「Axion 桌面桥接」，然后重启
#    （v1.1 的 /data/adb/axion_recents_stock_home 已失效，可顺手删掉）
# 2) 想完全回原厂：KernelSU 里停用 axion_recents 模块 + LSPosed 里停用 com.axion.motodesktop，重启
adb shell su -c 'cmd package set-home-activity com.motorola.launcher3/com.android.launcher3.CustomizationPanelLauncher'
```

### 6.1 如果 KernelSU 里显示「未启用」/ 开关弹回去（v1.2.2 已修复根因）

v1.2.1 及更早的模块会自己写 `/data/adb/modules/axion_recents/disable`（看门狗误判崩溃循环时的
自愈动作），KernelSU 只要看到这个文件就认为模块被禁用 —— 于是开关看起来"点了没用"。
v1.2.2 起模块**不再**写它，安装时（`customize.sh`）也会清掉遗留的那份。

如果你手上是旧版误判后卡住的状态，手动清一次再重启即可（**4 个标记必须一起删**，
漏掉 `_bootcount` 的话旧版的守卫会在下次开机再停用一次）：

```bash
adb shell su -c 'rm -f /data/adb/axion_recents_crashloop /data/adb/axion_recents_bootcount \
  /data/adb/axion_recents_rebooted /data/adb/modules/axion_recents/disable'
adb reboot
```

`/data/adb/axion_recents_needs_attention`（v1.2.2 新增）是"本次开机有异常、需要人工看一眼"
的记录，不影响挂载，看到它时去 `/data/adb/axion_recents.log` 末尾找原因即可。

`_tools\_clite_test2.sh`（快速回环：不重启，直接切 HOME 试原厂桌面）、
`_tools\_clite_verify.sh`（开机后一次性打印全部判据）是同目录下的调试脚本。

### 6.2 C-lite 突然失效 / HOME 自己回到 Axion（LSPosed 缓存了旧路径）

**症状**：本来用得好好的，某次升级模块（或手动重装桥接 APK）并重启后：

* KernelSU 里模块是启用状态，日志里挂载、RRO 判定都正常；
* 但 HOME 变成了 Axion 桌面，最近任务也是 Axion 的（退回默认模式）；
* `/data/adb/lspd/log/modules_*.log` 里**一行 `AxionDesktopBridge` 都没有**，
  `service.sh` 的探针打 `not C-lite: no bridge handshake for this boot`。

**原因**：LSPosed 把「第一次加载这个桥接 APK 的路径」记在
`/data/adb/lspd/config/modules_config.db` 里。每次 `pm install` 都会给 APK 换一个
`/data/app/~~<随机字符串>/com.axion.motodesktop-<随机字符串>/base.apk` 路径，旧目录随即被删。
路径一旦不存在，LSPosed 就**静默跳过**这个模块 —— 不报错、不提示，C-lite 直接失效。
（打开 LSPosed 管理器看一眼并不会刷新这条记录；设备上没有 `sqlite3` 二进制，所以模块改用自带的
`helper/lspd-fix.jar`，通过 `app_process` + 框架 `SQLiteDatabase` 改写它，见 §10。）

**修法**（30 秒）：打开 LSPosed 管理器 → 找到 `Axion Desktop Bridge`（`com.axion.motodesktop`）
→ 把开关**关掉再打开** → 重启。管理器这次会把新路径写回它的库，握手就恢复了。

**v1.2.2 起模块自己会尽量避免这件事**：

* 桥接 APK 有独立版本号（模块根目录的 `helper.prop`，由 `helper/build-helper.ps1` 从实际
  产物生成）。`customize.sh` 与 `service.sh` 只在「已装版本 < zip 里的版本」时才重装，
  所以**只改脚本/文档的版本升级不会碰桥接 APK，路径不动，C-lite 不受影响**；
* 真的重装了桥接时，模块会比对 LSPosed 缓存路径与 `pm path` 的实际路径，不一致就**自己修**
  （`helper/lspd-fix.jar` 把真实路径写回并复核，见 §10）；只有修不了才打
  `WARNING: LSPosed cached a stale bridge path ...` 并写
  `/data/adb/axion_recents_needs_attention`，那时再按上面那 30 秒步骤操作即可；
* 只有 `Main.java` / 桥接资源真的变了（`helper.prop` 递增）才会发生一次重装。

## 7. 桌面不出现在最近任务里（build-77 起）

C-lite 下 `config_recentsComponentName` 指向 Axion，而 HOME 是原厂桌面 ⇒ 概览总是走
`OverviewComponentObserver` 的 `FallbackActivityInterface`，宿主是 `FallbackRecentsView`。
上游这段代码为了让"第三方桌面上也能用手势快速切换"，会给 **home 任务造一张临时卡片**，
而且是在**两个**地方造的：

1. `onGestureAnimationStartOnHome()` 记下 `mHomeTask`，随后 `RecentsView.showCurrentTask()`
   （`RecentsView.java:3216-3240`）为运行任务建一个"临时不可见 tile"——`shouldAvoidAddingStubTaskView()`
   返回 false 时就会 `getTaskViewFromPool(SINGLE)` + `bind(new SingleTask(Task.from(...)))`；
   从桌面开始的手势、以及 `applyLoadPlan` 之后的 `showCurrentTask(applyLoadPlan)` 各调一次；
2. `FallbackRecentsView.applyLoadPlan()` 里再 `newList.add(new SingleTask(mHomeTask))`。

两处都注释成"不可见"，但 Axion 的堆叠布局用 `getHomeTaskView()`
（= `getTaskViewByTaskId(mHomeTask.key.id)`）当**栈中心**，于是原厂桌面以一张**透明、无缩略图的
卡**出现在正中，直到 `onPrepareGestureEndAnimation()`（150 ms dismiss）撤掉 —— 用户看到的
就是"从桌面进最近任务，主卡先是一张透明的桌面卡，反应过来后才变成上次打开的应用"。

**只改 `applyLoadPlan()` 不够（build-76 的教训）**：load plan 里本来就没有 home 任务（AMS
的任务列表里那条启动器任务不进 load plan），真正被看见的卡是第 1 处 `showCurrentTask()` 建的
stub。build-76 的日志里仍能看到 `showCurrentTask(onGestureAnimationStart)` 之后紧跟
`TaskView: onBind` + `TaskViewModel: bind … to taskIds: [8055]`（8055 = 启动器任务），
`showCurrentTask(applyLoadPlan)` 之后又一次。

修法（`tree\quickstep\src\com\android\quickstep\fallback\FallbackRecentsView.java`）：

* 新增 `private int mHomeTaskId = INVALID_TASK_ID`，在 `onGestureAnimationStartOnHome()` 里记录、
  在 `onGestureAnimationEnd()` 里清空（**不能**用 `mHomeTask`：同一手势里
  `setCurrentTask(-1)` 会把它置空，于是 `applyLoadPlan` 那次 `showCurrentTask()` 又会退回上游行为）；
* `shouldAvoidAddingStubTaskView()` 在 `groupedTaskInfo.containsTask(mHomeTaskId)` 时返回 true
  ⇒ 永远不为 home 任务建 task view；
* `applyLoadPlan()` 不再追加 home 任务（保留 `mHomeTask` 字段，`setRunningTaskHidden()` 仍在用）。

`AxStackRecentsView` 本来就能处理 `getHomeTaskView() == null`（默认模式一直是 null），
`getStackCenterTaskIndex()`/`isStackTask()` 都是 null-safe；`getTaskIdsForRunningTaskView()`
在 `mRunningTaskViewId == -1` 时返回空数组，也是上游既有的"空最近任务"路径。
结果：**最近任务里只有真实应用的任务卡**。

验证（真机 build-77）：

* 从桌面做起手上滑进最近任务，日志里不再出现 home 任务 id 的 `TaskViewModel: bind`；
  手势中途、抬手瞬间、稳定后三张截图里主卡都是真实应用（无透明卡）；
* 回归：最近任务键（187）、点卡打开应用、全部清除、从桌面快速切换手势、
  **从真实应用上滑**（走的是上游正常路径，运行应用仍有一张 live tile 卡）均正常，无崩溃。

相关 payload：build-77 = 42,969,707 B、md5 `bc29e50ca1c8126ec66ba22627cb978b`
（build-76 备份在 `_tools\payload-build76.apk`，md5 `3364d292f2d3c54acb4bb0f10832cf55`；
设备上 `/data/local/tmp/AxionLauncher3.bak.apk` 是改动前的 11,149,001 B 版本）。

## 8. C-lite 下被 RRO 关掉的两个桌面手势（v1.2.1 起由桥接修复）

原厂桌面的「双击空白处息屏」和「下滑拉出控制中心 / 通知栏」都由 `com.motorola.launcher3` 自己实现，
但**执行端是 `com.android.quickstep.SystemUiProxy`** —— 它只是 Binder 代理，字段 `mSystemUiProxy`
只有在本包的 `com.android.quickstep.TouchInteractionService`（TIS）被 SystemUI 绑定时才会被赋值
（`setProxy(...)` 的唯一调用点是 `TouchInteractionService$TISBinder`，而该 service 在 manifest 里要求
`STATUS_BAR_SERVICE`）。C-lite 下 `config_recentsComponentName` 指向 Axion ⇒ SystemUI 绑的是 Axion 的
TIS ⇒ **原厂桌面进程里 `mSystemUiProxy == null`**，于是：

* **双击息屏**：`WorkspaceTouchListener.lockScreen()` 的前置门控（NORMAL 状态、230 ms 双击窗口、
  位移不超 2×slop）全部通过，最后 `SystemUiProxy.lockDevice(true)` 在 `if (mSystemUiProxy != null)`
  不成立时**静默 return**（连一行日志都没有）；
* **下滑**：控制器注册是无条件的，但 `StatusBarTouchController.canInterceptTouch()` 最后一句是
  `return SystemUiProxy.INSTANCE.get(mLauncher).isActive();` ⇒ ACTION_DOWN 就返回 false，触摸流连拦截
  都进不去（`isActive()` 的实现就是 `mSystemUiProxy != null`）。

v1.2.1 的桥接在**原厂桌面进程**里补了 4 个 hook（源码 `helper/java/com/axion/motodesktop/Main.java`）：

| hook 点 | 行为 |
| --- | --- |
| `SystemUiProxy#isActive()`（before） | 仅在 `mSystemUiProxy == null` 时 `setResult(true)`：放开下滑的拦截门控，NORMAL/浮层/insets 等其它门控不动；proxy 存在时完全不干预 |
| `SystemUiProxy#onStatusBarTouchEvent(MotionEvent)`（before） | proxy 为 null 时不再空转：抬手（ACTION_UP）时按位移改调 `StatusBarManager.expandSettingsPanel(null)` 或 `expandNotificationsPanel()`，然后 `setResult(null)` |
| `SystemUiProxy#lockDevice(boolean)`（before） | proxy 为 null 时改调 `PowerManager.goToSleep(SystemClock.uptimeMillis())`，保留原方法签名（void） |
| `Utilities#isSleepScreenEnabled(Context)`（after） | 原厂已返回 true 时不动；返回 false 且 `put_display_to_sleep`（读 `com.motorola.android.provider.MotorolaSettings$Global`）**完全未设置**时才放开。本机实测原厂值就是 `"1"`，所以这层是纯兜底 |

短滑 vs 长滑的阈值是**从被转发的那段触摸流算起的位移**：原厂
`StatusBarTouchController.onControllerInterceptTouchEvent()` 在 `dy > mTouchSlop` 时会把当前事件改写成
`ACTION_DOWN` 再转发并让窗口 slippery，所以转发流的 `downY` 已经在屏幕中段。真机实测
（`input swipe 600 700 600 700+d 250`，屏幕 1220×2712）：

| 拖动距离 d | 转发流 downY | 位移 travel | 结果 |
| --- | --- | --- | --- |
| 200 px | 未拦截 | — | 无反应（原厂自己的门控；默认模式同样如此） |
| 300 px | 982 | 18 px | 通知栏 |
| 400 px | 977 | 123 px | 通知栏 |
| 500 px | 981 | 219 px | 通知栏 |
| 700 px | 997 | 403 px | 控制中心 |
| 900 px | 1005 | 595 px | 控制中心 |
| 1200 px | 1003 | 897 px | 控制中心 |

即 `CONTROL_CENTRE_TRAVEL_PX = 240f`：屏幕上拖到 300–550 px 之间 ≈ 通知栏，≥ 约 570 px ≈ 控制中心
（等价于原厂「一次连续拖动越过通知区就进控制中心」的手感）。每次抬手都会打一行

```
adb logcat -s AXMOTO:*
I AXMOTO  : swipe down: downY=983.6 travel=316.3px -> control centre
I AXMOTO  : swipe down -> StatusBarManager.expandSettingsPanel
I AXMOTO  : lockDevice -> PowerManager.goToSleep()
```

想改手感就调 `CONTROL_CENTRE_TRAVEL_PX` 这一个常量。

**为什么做不到和原厂 1:1 跟手**：原厂是把每一帧 MotionEvent 经
`ISystemUiProxy.onStatusBarTouchEvent` 交给 SystemUI，再由 SystemUI 自己拖动帷幕（手指到哪帷幕到哪）。
C-lite 下这条通道随 TIS 绑定一起消失，而 SystemUI 实现的 `ISystemUiProxy` 不是系统服务、拿不到
binder（只有 SystemUI 主动绑定时才会拿到），所以桥接只能在**抬手时**二选一展开。

两个权限（`android.permission.DEVICE_POWER`、`android.permission.EXPAND_STATUS_BAR`）原厂桌面 manifest
里都没有，桥接在 system_server 的权限漏斗里对原厂桌面的 uid（appId）放行 —— 与 v1.1 起放行
`recents` 标志权限的做法相同（前者的 enforcement 在 `PowerManagerService`、后者在
`StatusBarManagerService`，都在 system_server 内，正好走已 hook 的
`android.app.ContextImpl.enforceCallingOrSelfPermission`）。

验证（真机 SDK 36，C-lite）：

```bash
adb shell input swipe 600 700 600 2000 300   # → mCurrentFocus=Window{… NotificationShade}
                                             #   AXMOTO: swipe down -> StatusBarManager.expandSettingsPanel
adb shell input tap 450 1750; adb shell input tap 450 1750   # 两次连点（230ms 窗口内）
                                             # → mWakefulness=Dozing
                                             #   AXMOTO: lockDevice -> PowerManager.goToSleep()
```

回归：最近任务键（187）与从桌面起手上滑仍进 Axion `com.android.launcher3/com.android.quickstep.RecentsActivity`，
`logcat -b crash` 里 launcher/systemui 计数为 0；默认模式（桥接停用）行为不变。

更新方式：换新 zip 刷入模块（里面的桥接 APK 只有在**版本比已装的更高**时才会自动覆盖安装，
见 §5），然后重启。只改模块脚本、没动桥接的版本升级**不会**碰桥接 APK，C-lite 不受影响。

## 9. 最近任务 → 桌面的转场动画（build-85 起）

C-lite 下「回到桌面」时，**桌面本身不是我们能动的窗口**：HOME 属于 `com.motorola.launcher3`，
平台把它当作 background app 留在最近任务窗口后面
（`FallbackActivityInterface.java:53-60` 的 `super(false, DEFAULT, BACKGROUND_APP)`），进入最近任务
时把它放大、返回时再自己收回正常大小。Axion 侧拿到的那条 home transition leash
（`RemoteAnimationTarget.leash`）**不是屏幕上真正显示的 surface**：真机上我们确实每帧都写进去了
（`RecentsActivity: home reveal: animating 1 leash(es) from scale=0.05 …`），但
`dumpsys SurfaceFlinger --list` 里那条 leash 连 handle 都没有，录屏逐帧对比也证明屏幕毫无变化。
所以「对 home leash 做 matrix/alpha」这条路在 C-lite 下无效（日志 + SF 层清单 + 录屏三重否证）。

现在的做法是动画**我们自己的** overview —— `RecentsActivity` 的 `mDragLayer`（卡片、操作行、遮罩）：
在转场时长内把它缩放到 `axion_home_reveal_zoom` 并淡出到 `axion_home_reveal_alpha`，桌面则被系统
自己收回，两者叠起来就是「卡片冲出来（或退开），桌面浮现」。

设置（`settings put global …`，改完立即生效，不用重启也不用重装）：

| 键 | 默认 | 含义 |
| --- | --- | --- |
| `axion_home_reveal_enabled` | 1 | 0 = 完全关掉本模块的转场动画 |
| `axion_home_reveal_zoom` | 1.4 | >1 卡片朝观察者冲出来（现有观感）；<1 卡片收小退开；1 = 只淡出 |
| `axion_home_reveal_alpha` | 0 | 转场结束时 overview 的不透明度（0 = 完全淡出） |
| `axion_home_reveal_duration` | 250 | 转场时长（ms）。250 与原生等长，改大会让整段转场变慢 |
| `axion_home_reveal_scale` | 0.85 | 旧参数（写给 home leash 的缩放），C-lite 下无可见效果，仅留作调试 |

```bash
adb shell settings put global axion_home_reveal_zoom 1.4   # 想更猛就 1.6，想温和就 1.15
adb shell settings put global axion_home_reveal_duration 250
adb shell settings put global axion_home_reveal_enabled 0  # 关掉
```

触发路径：最近任务里**按返回键**、或**清空全部任务**时（`fallback/RecentsState.kt:122-135` 的
`onBackInvoked`：`runningTaskView == null || isBeingDismissed` → `recentsView.startHome()`）。
**按 HOME 键从最近任务回桌面不走这条路径**（system_server 直接拉起原厂桌面，不经过
`RecentsActivity.startHome`），那种情况下看到的完全是系统自带的动画，模块无法干预。

实现细节（build-86 修）：转场结束时**不能**立刻把 `mDragLayer` 的 scale/alpha 复位 —— 那个回调
跑在最近任务窗口还留在屏幕上的时候，复位会让整个 overview 闪回一帧（真机 30fps 逐帧量到：动画
结束后 YAVG 从 106 突跳到 113 再落回，肉眼即「回闪一下」）。复位改到 `RecentsActivity.onStart()`
（窗口仍隐藏时执行，下次进最近任务自然是干净状态）。修复后同一段录屏结尾帧差 ≈ 0，不再闪回。

实现细节（build-87）：动画拆成两条曲线 —— scale 仍用
`AxAnimationEngine.HOME_GESTURE_WORKSPACE_INTERPOLATOR`，alpha 用
`PathInterpolator(0.55f, 0f, 1f, 1f)`（后置淡出，先让内容冲出来）；动画期间给 `mDragLayer` 开
`LAYER_TYPE_HARDWARE`，结束/取消时清回 `LAYER_TYPE_NONE`；动画未结束前 `dispatchTouchEvent`
直接吞掉新的 `ACTION_DOWN`，避免在移动的画面上误触卡片。真机 30 fps 逐帧：帧差
17.8→24.5→25.2→32.1→30.0→28.5→23.1→13.9→1.85→0，YAVG 189→194→…→106 单调衰减；
`dumpsys gfxinfo com.android.launcher3` 报 `Total frames rendered: 84 / Janky frames: 0 (0.00%)`、
99th percentile 16 ms、`Number Missed Vsync: 0`。

## 10. LSPosed 缓存路径自愈（v1.2.2 起）

**问题**：LSPosed 把桥接 APK 的加载路径记在 `/data/adb/lspd/config/modules_config.db`
（表 `modules`，列 `module_pkg_name` / `apk_path`）里。`pm install` 会换一个
`/data/app/~~<随机>/com.axion.motodesktop-<随机>/base.apk` 路径，旧路径一被删，LSPosed 就静默
跳过该模块（现象见 §6.2）。设备上没有 `sqlite3` 二进制，模块脚本原本只能报警告。

**做法**：模块自带 `helper/lspd-fix.jar`（源 `helper/lspd-fix/com/axion/recents/LspdPathFix.java`，
由 `tools/build-lspd-fix.ps1` 用 javac → jar → d8 打成只含 `classes.dex` 的包），用
`app_process` 借系统 framework 的 `android.database.sqlite.SQLiteDatabase` 直接读写这个库
（WAL 由 SQLite 自身处理，不需要 `wal_checkpoint`）。用法：

```bash
# 读缓存路径（比 grep 可靠：grep 可能命中已释放页里的旧路径副本）
CLASSPATH=/data/adb/modules/axion_recents/helper/lspd-fix.jar \
  app_process /system/bin com.axion.recents.LspdPathFix -get <db> com.axion.motodesktop

# 写真实路径并复核（打开库带 10×200 ms 重试）
CLASSPATH=... app_process /system/bin com.axion.recents.LspdPathFix <db> com.axion.motodesktop <实际路径>
```

`service.sh`（`:431` 起）的接法：`lsposed_cached_path()` 先调 `-get`，输出为空/失败才回落到
`grep -a -o '/data/app/[^/]*/com\.axion\.motodesktop-[^/]*/base\.apk' "$LSPD_DB"`；
`check_lsposed_path()` 发现缓存 ≠ `pm path` 的**实际路径**时调 `repair_lsposed_path()` 写好并复核，
成功只记 `fixed : the cached path now matches the installed bridge`，失败才打 WARNING + 写
`/data/adb/axion_recents_needs_attention`。

**真机验证**（用 `/data/local/tmp` 里的 DB 副本，跑的是 `service.sh :361-424` 原样抽出的函数）：

```
[test]   LSPosed cached a stale bridge path so it would keep skipping the module:
[test]     cached : /data/app/~~STALE==/com.axion.motodesktop-STALE==/base.apk
[test]     actual : /data/app/~~nIq-nzmKU4fGSIyoqnSwqA==/com.axion.motodesktop-lBFT63ZK-X_7OtFp5eVWWg==/base.apk
[test]     repair : rc=0 fixed: com.axion.motodesktop /data/app/~~STALE==/… -> /data/app/~~nIq-…==/…
[test]     fixed  : the cached path now matches the installed bridge
```

DB 正常时再跑一次只留标题行（静默），也不写 `needs_attention`。注意：实测这个 LSPosed 版本在
`pm install -r` 之后**自己也会更新**这条记录，所以该失败模式不一定还能自然复现 —— 自愈是兜底。

**时序限制**：`service.sh` 的桥接检查排在被动看门狗（约 3–5 个 20 s 采样）之后，而 LSPosed 读库
发生在开机更早的时候，所以修好的路径通常要**下一次开机**才对桥接生效。

## 11. 从原厂桌面直接上滑进最近任务（build-88 起）

**问题**：C-lite 下 HOME 角色由原厂 `com.motorola.launcher3` 持有，最近任务容器是我们自己的
`RecentsActivity`。从原厂桌面上滑时，手势走 `InputConsumerUtils.newBaseConsumer()` 最后一个
`else` → `OtherActivityInputConsumer`：平台会启动一段**交互式** recents 动画，按手指位移拖动
**原厂桌面的窗口**，手指停在哪动画就停在哪（实测 400 px 短上滑只拉开一点又弹回），观感与我们自己
桌面进最近任务完全不同。

**做法**：只在「`runningTask.isHomeTask` 且 `overviewComponentObserver.isHomeAndOverviewSame()`
为 false」（即 HOME 与最近任务不是同一个 App，只有 C-lite 成立）时，`OtherActivityInputConsumer`
在首次越过 slop 的那次 `ACTION_MOVE` 里直接调
`mOverviewCommandHelper.addCommand(OverviewCommandHelper.CommandType.TOGGLE, displayId)`
（= 最近任务键 / `KEYCODE_APP_SWITCH` 的那条路），然后 `break` 掉本帧后续处理 ⇒ 不启动交互式动画、
不把位移喂给 handler，手指位置彻底失效。斜向/水平 swipe（`swipeWithinQuickSwitchRange`，与水平面
夹角 ≤ `OVERVIEW_MIN_DEGREES` = 15°）与触控板手势保持原行为。

改动位置：`inputconsumers/OtherActivityInputConsumer.java`（新增 `mDirectToOverview` /
`mOverviewCommandHelper` / `mDirectOverviewHandled` 字段与 `handleDirectOverview()`）、
`InputConsumerUtils.kt`（`newBaseConsumer()` 与 `createOtherActivityInputConsumer()` 透传
`overviewCommandHelper`）。默认模式（home == overview）走不到这个分支，行为不变。

**真机验证**（build-88，logcat 全在 `com.android.launcher3` 进程内）：

```
OtherActivityInputConsumer: ACTION_DOWN: mIsDeferredDownTarget=true
OtherActivityInputConsumer: axion: home task owned by another launcher, entering overview
                            directly (finger position ignored)
OverviewCommandHelper: command added: CommandInfo(type=TOGGLE …)
OverviewCommandHelper: switching via recents animation … with end target: RECENTS
OverviewCommandHelper: command executed successfully
finishTouchTracking: mPassedWindowMoveSlop=false, mInteractionHandler=null, mActiveCallbacks=null
```

全程没有 `startTouchTrackingForWindowAnimation`、没有逐帧 `updateDisplacement` ⇒ 手指确实不参与；
400 px 短上滑也直接**完整**进入最近任务（截图确认卡片、锁定/分屏/截屏、全部清除都在）。

**回归**：从**应用**上滑（先用 `mCurrentFocus` 确认 App 真的在前台）仍是
`startTouchTrackingForWindowAnimation` + 逐帧跟手动画，没有 `axion:` 行；原厂桌面上横向 swipe
（`passedSlop` 后走原分支）同样保持原行为。
