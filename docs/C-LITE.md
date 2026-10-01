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
之后 `service.sh` 每次开机都会调用 `ensure_helper_installed()`，比较
`extras/motodesktop-helper.apk` 与已装 `pm path com.axion.motodesktop` 的 base.apk 的 sha256，
不一致才 `pm install -r -d` 重装 —— 所以模块升级时桥接会**自动更新到 extras/ 里那一份**。
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
   **绝不 force-stop 原厂桌面**），健康则写 `/data/adb/axion_recents_healthy`。

> 为什么 `service.sh` 必须等：看门狗的观察窗口只有 160 s，而上面的探测最多要
> 12 轮 ≈ 4.4 min，两者是**并发**的。早先看门狗在自己的 160 s 窗口里看不到原厂桌面进程
> 就直接 `ax_rollback`（写 `disable` + 一键重启回原厂），把还没跑完的探测打断 —— 真机
> 踩过一次（18:45 那次开机：探测跑到 #4 就被回滚掐了）。settle 状态文件把这两段串起来。

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
[service] watchdog(c-lite): healthy after 160s (…)
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
* **helper APK 由模块自己维护**：v1.2 起 `service.sh` 每次开机会核对 `extras/` 里那份与已装
  `com.axion.motodesktop` 的 sha256，不一致就自动重装升级；LSPosed 也会**自动同步数据库里的
  `apk_path`**（实测 `pm install -r` 之后约 6 秒就指到新的 base.apk）。所以重装/更新桥接之后
  **不再需要**重跑 `_clite_install.ps1`。本地那个 `_tools/_clite_install.ps1` 现在只是命令行开关
  （默认开启桥接，`-Off` 关闭），等价于在 LSPosed 管理器里点一下。
* 系统 OTA / 重装 KernelSU 之后需要重新做第 2 步。

## 6. 回滚

```bash
# 1) 关掉 C-lite（回到 v1.0 行为：Axion 桌面 + Axion 最近任务）
#    在 LSPosed 管理器里停用「Axion 桌面桥接」，然后重启
#    （v1.1 的 /data/adb/axion_recents_stock_home 已失效，可顺手删掉）
# 2) 想完全回原厂：KernelSU 里停用 axion_recents 模块 + LSPosed 里停用 com.axion.motodesktop，重启
adb shell su -c 'cmd package set-home-activity com.motorola.launcher3/com.android.launcher3.CustomizationPanelLauncher'
```

`_tools\_clite_test2.sh`（快速回环：不重启，直接切 HOME 试原厂桌面）、
`_tools\_clite_verify.sh`（开机后一次性打印全部判据）是同目录下的调试脚本。

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
