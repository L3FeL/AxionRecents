# How it works

本模块要在这台 Motorola Android 16 机器上做到一件事：**让最近任务由 Axion 的 Quickstep 提供，
并且桌面就是这个包本身**，同时不改写原厂的任何文件。

下面按开机顺序拆开讲，最后是踩过的两个硬坑。

---

## 1. 静态 RRO：把 `config_recentsComponentName` 拿回来

原厂 `/product/overlay/framework-rro-launcher3.apk`（包 `com.motorola.overlay.launcher3`，
`priority 1`，`targetPackage android`）把 `android:string/config_recentsComponentName` 改成了
`com.motorola.launcher3/com.android.quickstep.RecentsActivity`。

本模块的 `payload/AxionRecentsOverlay.apk` 覆盖同一个资源，指回
`com.android.launcher3/com.android.quickstep.RecentsActivity`：

```xml
<overlay android:targetPackage="android" android:isStatic="true" android:priority="100"/>
```

两条都是 **static RRO**，靠 `priority` 决胜（100 > 1）。framework-res 的原始默认值本来就是
`com.android.launcher3/…`，所以这一步只是把 Moto 的改动盖回去。

签名不需要与目标一致：这台机器的原厂 overlay 与 framework-res.apk 就是不同证书签的，
自签名完全可用（`payload/AxionRecentsOverlay.apk` 用 `tools/axion-recents.jks` 签）。

**故意不覆盖**：`config_recentsComponentNameForCli`（Moto Smart Connect 的 CLI 形态）仍指
`com.android.systemui/com.motorola.systemui.cli.navgesture.CliRecentsActivity` —— 本 port 没有
对应的 CLI recents activity 可以指。

## 2. priv-app 镜像：为什么不去动原厂目录

`com.android.launcher3` 必须是一个 **system/priv-app** 包（它需要 `signature|recents` 等
签名级权限），所以必须出现在 `/system_ext/priv-app/` 下。

`post-fs-data.sh`（zygote/system_server 起来之前）做的是**目录级 tmpfs 镜像**：
把原厂的
`/system_ext/priv-app/`、`/system_ext/etc/permissions/` 复制进 tmpfs，在副本里加上

* `/system_ext/priv-app/AxionLauncher3/AxionLauncher3.apk`（`payload/AxionLauncher3.apk`）
* `/system_ext/etc/permissions/privapp-permissions-com.android.launcher3.xml`

再把整个目录 bind 到原位。原厂目录（含 `/system_ext/priv-app/Launcher3QuickStep/`）**一个字节都没改**，
OTA/还原都不需要救砖。

privapp 白名单是必须的：`ro.control_privapp_permissions=enforce` 下，任何带 `privileged` 标志的
权限没被列出都会直接让开机失败。白名单只列特权权限（`ACCESS_CONTEXTUAL_SEARCH`、
`BIND_APPWIDGET`、`WRITE_SECURE_SETTINGS` …），`signature|recents` / `signature|role` /
`signature|preinstalled` 这些由 AOSP 自己授予，**不能**列进去。

## 3. HOME 交接：为什么必须把桌面也交出去

PMS 只在开机时按 `config_recentsComponentName` 算一次“recents 包”，而
`signature|recents` 的 `android.permission.MANAGE_ACTIVITY_TASKS` **只授予那个包**。

于是模块生效的那次开机里：

* `com.android.launcher3` 拿到 `MANAGE_ACTIVITY_TASKS`，可以用 Quickstep 的转场；
* `com.motorola.launcher3` 拿不到，它的 `QuickstepLauncher` 一启动就在
  `RecentsAnimationDeviceState.<init>` 抛 `SecurityException: getRootTaskInfo() … requires
  android.permission.MANAGE_ACTIVITY_TASKS`。

如果这时 HOME 还留给原厂桌面，就会变成“桌面一起就崩”的循环。所以
`service.sh` / `boot-completed.sh` 在确认 RRO 真的生效（查 OMS 的实际取值，不是查文件是否存在）
之后，用 `cmd role add-role-holder --user 0 android.app.role.HOME com.android.launcher3`
把 HOME 接过来，并把原厂桌面 force-stop 掉（它此刻是坏状态）。

对应地，**回原厂桌面就是停用模块 + 重启**：那时我们的 RRO 不存在，`MANAGE_ACTIVITY_TASKS`
自然回到 `com.motorola.launcher3`。

## 4. 两道安全网

* **开机计数 / 熔断**（`post-fs-data.sh`）：每次模块生效的开机 +1，只有上一次开机被判定健康
  才清零。连续 3 次不健康就自动写 `disable` 并跳过所有挂载 ⇒ 下次重启自动回原厂。
  （健康判定不看 `sys.boot_completed`：曾出现 boot_completed 之后 SystemUI 才崩的情况。）
* **崩溃循环看门狗**（`service.sh`）：开机后 160 s 窗口里统计 launcher / SystemUI 崩溃与
  桌面进程存活；判定崩溃循环就把 HOME 还给原厂桌面、停用模块，并安排一次自动重启到干净状态。

日志落在 `/data/adb/axion_recents.log` 与 `/data/adb/axion_recents_diag.log`。

## 5. 硬坑一：Shell 的 runner 回调 parcel 读不对（bug：从 app 进不去最近任务）

现象：上滑后 Shell 正常发起转场（`RecentsController.start`），但 app 窗口不动、随即被取消。

原因链：

1. 设备的 boot classpath 里**已经有** `android.window.IRecentsAnimationRunner`
   （Moto Android 16 / SDK 36 的 framework 里声明了它），运行期 boot 类胜出 ——
   所以我们编译进 APK 的 AIDL 副本不参与实际调用，**事务码与 parcel 布局都以设备为准**。
2. 设备侧 `IRecentsAnimationRunner$Stub$Proxy.onAnimationStart` 的写序是：
   `writeInterfaceToken(...)` → `writeStrongInterface(controller)` →
   `writeTypedArray(apps)` → `writeTypedArray(wallpapers)` → `writeTypedObject(homeContentInsets)` →
   `writeTypedObject(minimizedHomeBounds)` → `writeTypedObject(extras)` → `writeTypedObject(info)` → `transact(3, …, FLAG_ONEWAY)`。
3. 生成的 `Stub.onTransact` 里 `enforceInterface()` 之后的读取位置与发送方的对象表**对不齐**：
   `readStrongBinder()` 在错位处返回 `null` 且不前进，后面所有字段整体错位，读到第一个
   `flat_binder_object`（24 字节）内部时 libbinder 直接拒绝：

   ```
   E Parcel : Attempt to read or write from protected data in Parcel …
              pos: 96, nextObject: 0, object offset: 96, object size: 24
   ```

   返回 `PERMISSION_DENIED`；因为这是 **oneway** 事务，异常在发送方被静默吞掉 ——
   我们的 `onAnimationStart` 从来没被调用，Shell 等不到 runner，转场随即取消。
4. 修法（`SystemUiProxy.kt` 的 `RecentsAnimationListenerStub`）：**自己解析这个 parcel**。
   先按 4 字节对齐扫描找出接口描述符字符串的位置，再从那里按 4 字节槽位扫描
   `readStrongBinder()`，优先取 `interfaceDescriptor == "android.window.IRecentsAnimationController"`
   的那个；定位到 controller 之后，按上面的固定字段顺序读 apps / wallpapers / insets /
   minimizedHomeBounds / extras / info，校验合法再交给 listener。失败时把位置复位后回退
   `super.onTransact`（最差退回原症状）。

## 6. 硬坑二：同样的错位也毁掉另外两个回调（bug：切换到另一张卡卡死）

事务码 **2**（`onAnimationCanceled(int[] taskIds, TaskSnapshot[] snapshots)`）与
**4**（`onTasksAppeared(RemoteAnimationTarget[] apps, TransitionInfo info)`）走的是同一个
`onTransact`，所以同样读不到。用户在 Overview 里点另一张卡时，Shell 会：

```
RecentsController.merge → opening new leaf taskId=… → merge: consuming merge → calling onTasksAppeared
```

而这次回调到不了 launcher ⇒ 没有 `finishRecentsAnimation`/`onRecentsAnimationComplete`
⇒ 输入消费者停在 recents 模式，表现为画面“卡死不动”。修法同上：2 和 4 也各自手工解析
（`createIntArray` + `createTypedArray(TaskSnapshot.CREATOR)` / `createTypedArray(RemoteAnimationTarget.CREATOR)`
+ `readTypedObject(TransitionInfo.CREATOR)`）。

## 7. 硬坑三：牌堆模式远处卡片不预载（bug：远处的卡片不渲染）

Axion 的牌堆布局里，`AxStackLayout.TASK_PRELOAD_RANGE = 5`（`isDistanceActive` 判定
`distance >= -5 && distance <= 4`），但 `AxStackRecentsView` 早期版本重写了
`getTaskViewVisibleRange()` 并加了一个 `loadVisibleTaskData` 守卫，导致可见窗口固定在最前面
几张卡上：远处的卡只有 `BackgroundOnly`（纯色占位），要滑到它附近才去加载缩略图。

修法：删掉那个 `loadVisibleTaskData` 守卫（`RecentsView.computeScrollHelper()` 会在滚动时
每帧刷新可见窗口），`getTaskViewVisibleRange()` 返回 `TASK_PRELOAD_RANGE + 1`（即 6），
让牌堆里的卡片提前进入加载窗口。

---

## 附：为什么模块树里必须保留 `system/product/overlay/AxionRecentsOverlay.apk`

`post-fs-data.sh` 会检查这个文件是否存在（8339 字节）来判定“RRO 已就位”。如果它被拿掉、
而模块仍然启用，就会出现 **HOME 归 Axion、recents 仍归原厂** 的不一致状态 ⇒ Axion 桌面缺
`MANAGE_ACTIVITY_TASKS` ⇒ 崩溃循环 ⇒ 看门狗回滚并停用模块。正常安装不会缺这个文件；
`tools/build-zip.ps1` 的自检也会断言它在 zip 里。
