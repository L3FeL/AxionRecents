#!/system/bin/sh
# Axion Recents - phase 2 (late_start service): wait for boot, verify the mounts and the
# two packages, make sure the Axion launcher is HOME and healthy, and write the report to
# /data/adb/axion_recents.log
#
# RRO 判定的口径（v1.4 修正）：看 OMS 的**实际生效值**
# （cmd overlay lookup android android:string/config_recentsComponentName 是否指向
# com.android.launcher3/*），而不是 post-fs-data 写下的 /data/adb/axion_recents_rro_ok ——
# 那个标记只表示“模块树里备好了那份 RRO”，metamodule 灌注 /product/overlay 更晚。
#
# 关键安全网（v1.4 新增）：如果 com.android.launcher3 没起来（或者起来后立刻崩），说明
# recents 配置已指向它、而承载 QuickStep 的包不可用 —— 此时唯一安全的动作是停用模块，
# 让用户重启回到原厂桌面。日志里会写清楚。
MODDIR=${0%/*}
LOG=/data/adb/axion_recents.log
PRIV=/system_ext/priv-app
NEWPKG="$PRIV/AxionLauncher3"
PERM_DIR=/system_ext/etc/permissions
RRO_MAGIC=/product/overlay/AxionRecentsOverlay.apk
RRO_STOCK=/product/overlay/framework-rro-launcher3.apk   # 原厂静态 RRO (com.motorola.overlay.launcher3, 8542 B) -绝对不能覆盖
RRO_BYTES=8339
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [service] $*" >> "$LOG" 2>/dev/null; }

# ---------------------------------------------------------------------------
# v1.7 崩溃循环熔断（v1.6 真机事故的直接修复）
#   事故：v1.6 的 payload 在 Android 16 上抛
#     java.lang.NoClassDefFoundError: Lcom/android/window/flags/Flags;
#   桌面被设为 HOME 后反复崩溃、system_server 跟着重启、负载飙到 ~25，
#   用户只能长按电源强关（“开机进系统秒关机”）。当时 v1.6 的 service.sh 只在
#   `cmd overlay lookup` 成功且 pidof 为空时回滚，而这台机器在 system_server
#   重启期间 `cmd` 服务不可用，脚本走了 SKIP 分支 ⇒ 没有任何回滚。
#   现在的口径：只要 Axion 是 HOME 持有者，就在 120 秒窗口内持续观察它，
#   崩溃（logcat crash buffer 里 >=2 条）或连续两次取不到 pid ⇒ 强制回滚：
#     ① 关掉我们的 RRO  ② 把 HOME 交还原厂桌面并拉起它
#     ③ 写 disable 与 crashloop 熔断标记（post-fs-data 下次开机直接不挂载）
#     ④ 一次性自动重启，回到干净的原厂状态（同一次开机内 PMS 的
#        mRecentsPackage 不会因关 RRO 而重算，所以必须重启）
#   健康通过则删掉 rebooted 标记，允许将来再次自动重启。
# ---------------------------------------------------------------------------
ax_crashes()     { logcat -b crash -d 2>/dev/null | grep -c 'Process: com.android.launcher3'; }
# v1.9：v1.8 那轮一条 launcher 崩溃都没有，崩的是设备自带 SystemUI
# （BubbleTransitions$DraggedBubbleIconToFullscreen 拿到 null Bubble 的 NPE，见 v1.9 记录）。
# 只看 launcher 的看门狗对这种情况完全失明 ⇒ 必须同时数 SystemUI。
ax_sui_crashes() { logcat -b crash -d 2>/dev/null | grep -c 'Process: com.android.systemui'; }

# v1.9 诊断快照：把崩溃/气泡/桌面/权限拒绝的证据落到 /data（重启也不丢）。
# v1.8 只做了 logcat crash buffer 的 grep，气泡 NPE 的“谁触发了这次转场”完全没有证据。
DIAG=/data/adb/axion_recents_diag.log
# v1.2：诊断快照只追加、每次开机都涨（v1.1 实测 1.6 MB / 7871 行且永不回收）。超过 512 KB 就
# 滚一代到 <file>.old（只保留两代），避免 /data 被诊断日志慢慢吃满。
diag_rotate() {
    [ -f "$DIAG" ] || return 0
    sz=$(stat -c %s "$DIAG" 2>/dev/null || echo 0)
    if [ "$sz" -gt 524288 ] 2>/dev/null; then
        mv -f "$DIAG" "$DIAG.old" 2>/dev/null
        log "diag log rotated ($sz bytes -> $DIAG.old)"
    fi
}
dump_diag() {
    diag_rotate
    {
        echo "===== diag snapshot: $1 @ $(date '+%Y-%m-%d %H:%M:%S') ====="
        echo "-- pids: systemui=$(pidof com.android.systemui) system_server=$(pidof system_server) axion=$(pidof com.android.launcher3) moto=$(pidof com.motorola.launcher3) mobiledesktop=$(pidof com.motorola.mobiledesktop)"
        echo "-- crash buffer: launcher=$(ax_crashes) systemui=$(ax_sui_crashes) --"
        echo "-- who runs: $(who_runs)"
        logcat -b crash -d 2>/dev/null | tail -200
        echo "-- logcat(bubble|desktop|taskbar|crash|watchdog) --"
        logcat -b all -d 2>/dev/null | grep -iE 'bubble|desktop|mobiledesktop|taskbar|AndroidRuntime|WATCHDOG|am_crash|am_proc_died|am_anr|WM_Shell' | tail -250
        echo "-- window desktop/bubble/focus --"
        dumpsys window 2>/dev/null | grep -iE 'desktop|bubble|mCurrentFocus|mFocusedApp' | head -40
        echo "-- activities --"
        dumpsys activity activities 2>/dev/null | grep -E 'Hist #|mResumedActivity|mLastPausedActivity' | head -20
        echo "-- selinux denials --"
        dmesg 2>/dev/null | grep -iE 'avc: *denied|audit' | tail -40
        echo "-- boot reason --"
        echo "ro.boot.bootreason=$(getprop ro.boot.bootreason) sys.boot.reason=$(getprop sys.boot.reason)"
        echo "===== end snapshot ====="
    } >> "$DIAG" 2>&1
}

# 健康标记：只由看门狗在“观察满窗口、没有崩溃”时写入。
# post-fs-data.sh 只有在看到它时才会把开机计数归 1 并继续挂载（见那里的守卫说明）。
HEALTHY=/data/adb/axion_recents_healthy

# v1.10：本开机里我们“确实把 HOME 拿在手里”的证据。
# v1.9 实测的漏洞：SystemUI 崩溃循环时 system_server 一起重启，`cmd role` 返回
# "Can't find service: role" ⇒ 脚本误判成“Axion 不是 HOME 持有者”走了被动分支，
# 只写了 disable（下次开机才生效），本次开机继续崩。现在 boot-completed.sh / 本脚本
# 在授到 HOME 后写这个标记，判定 HOME 归属时把“role 服务取不到 + 标记在 + 我们的
# launcher 在跑”也算作持有者 ⇒ 主动看门狗会真正回滚（还原原厂 HOME + 重启）。
HOME_GRANTED=/data/adb/axion_recents_home_granted

watchdog() {
    p0=$(pidof com.android.launcher3)
    m0=$(pidof com.motorola.launcher3)
    c0=$(ax_crashes); s0=$(ax_sui_crashes)
    log "watchdog: start (pid=${p0:-none} moto=${m0:-none} launcher_crashes=$c0 systemui_crashes=$s0)"
    miss=0
    i=0
    while [ $i -lt 8 ]; do
        sleep 20
        i=$((i + 1))
        p1=$(pidof com.android.launcher3)
        m1=$(pidof com.motorola.launcher3)
        c1=$(ax_crashes); s1=$(ax_sui_crashes)
        if [ -n "$p1" ]; then miss=0; else miss=$((miss + 1)); fi
        log "watchdog: t=${i}x20s pid=${p1:-none} moto=${m1:-none} launcher_crashes=$c1 systemui_crashes=$s1 miss=$miss"
        # v1.9：原厂桌面在接管后处于坏状态（没有 signature|recents 的 MANAGE_ACTIVITY_TASKS），
        # 而它是设备上唯一含气泡拖拽客户端代码的进程 ⇒ 它每被拉起一次都有机会用失效 key
        # 触发 SystemUI 的 BubbleController NPE。这里在整个观察窗口里反复清掉它。
        if [ -n "$m1" ]; then
            log "watchdog: stock launcher reappeared (pid=$m1) -> force-stopping it"
            am force-stop com.motorola.launcher3 >> "$LOG" 2>&1
        fi
        if [ "$c1" -ge 2 ] || [ "$miss" -ge 2 ]; then
            log "watchdog: UNHEALTHY - the Axion launcher is crash-looping"
            return 1
        fi
        if [ "$s1" -ge 3 ]; then
            log "watchdog: UNHEALTHY - SystemUI is crash-looping ($s1 crashes in this boot)"
            return 1
        fi
    done
    log "watchdog: healthy after $((i * 20))s (pid=${p1:-none} launcher_crashes=${c1:-0} systemui_crashes=${s1:-0})"
    date '+%Y-%m-%d %H:%M:%S' > "$HEALTHY"
    rm -f /data/adb/axion_recents_bootcount /data/adb/axion_recents_rebooted
    return 0
}

# v2.0 C-lite 看门狗：HOME 留在原厂 Moto 桌面，Axion 只当最近任务组件时用。
# 判据与旧模式不同：
#   * 两个进程都必须活着 —— Axion 是 QuickStep/recents 提供者（SystemUI 绑它的
#     TouchInteractionService），原厂桌面是 HOME 持有者（我们的 LSPosed 补丁把
#     signature|recents 的权限补回给它；补丁没生效时原厂桌面会崩，这就是要看 pid 的原因）。
#   * 崩溃计数照旧：launcher(Axion) >=2 或 SystemUI >=3 ⇒ 不健康。
#   * **不** force-stop 原厂桌面 —— C-lite 下它必须活着。
watchdog_clite() {
    p0=$(pidof com.android.launcher3); m0=$(pidof com.motorola.launcher3)
    c0=$(ax_crashes); s0=$(ax_sui_crashes)
    log "watchdog(c-lite): start (axion=${p0:-none} moto=${m0:-none} launcher_crashes=$c0 systemui_crashes=$s0)"
    i=0
    while [ $i -lt 8 ]; do
        sleep 20
        i=$((i + 1))
        p1=$(pidof com.android.launcher3); m1=$(pidof com.motorola.launcher3)
        c1=$(ax_crashes); s1=$(ax_sui_crashes)
        log "watchdog(c-lite): t=${i}x20s axion=${p1:-none} moto=${m1:-none} launcher_crashes=$c1 systemui_crashes=$s1"
        if [ -z "$p1" ]; then
            log "watchdog(c-lite): UNHEALTHY - the Axion quickstep process is not running"
            return 1
        fi
        if [ -z "$m1" ]; then
            log "watchdog(c-lite): UNHEALTHY - the stock HOME process is not running"
            return 1
        fi
        if [ "$c1" -ge 2 ] || [ "$s1" -ge 3 ]; then
            log "watchdog(c-lite): UNHEALTHY - crash loop (launcher=$c1 systemui=$s1)"
            return 1
        fi
    done
    log "watchdog(c-lite): healthy after $((i * 20))s (axion=${p1:-none} moto=${m1:-none} launcher_crashes=${c1:-0} systemui_crashes=${s1:-0})"
    date '+%Y-%m-%d %H:%M:%S' > "$HEALTHY"
    rm -f /data/adb/axion_recents_bootcount /data/adb/axion_recents_rebooted
    return 0
}

# v1.9 被动看门狗：探针模式 / SKIP 分支（Axion 不是 HOME 持有者）下用。
# 这里不期待 launcher 存活，只观察 SystemUI；结论同样写健康标记，否则守卫会把
# 这次“本来安全的开机”算成失败，下一次就不敢挂载了。
watchdog_passive() {
    s0=$(ax_sui_crashes)
    log "watchdog(passive): start (systemui_crashes=$s0, no launcher expected)"
    i=0
    while [ $i -lt 5 ]; do
        sleep 20
        i=$((i + 1))
        s1=$(ax_sui_crashes)
        log "watchdog(passive): t=${i}x20s systemui_pid=$(pidof com.android.systemui) moto=$(pidof com.motorola.launcher3) systemui_crashes=$s1"
        if [ "$s1" -ge 3 ]; then
            log "watchdog(passive): UNHEALTHY - SystemUI is crash-looping even without our recents/HOME takeover"
            return 1
        fi
    done
    log "watchdog(passive): healthy after $((i * 20))s (systemui_crashes=${s1:-0})"
    date '+%Y-%m-%d %H:%M:%S' > "$HEALTHY"
    rm -f /data/adb/axion_recents_bootcount /data/adb/axion_recents_rebooted
    return 0
}

ax_rollback() {
    dump_diag "rollback"
    log "ROLLBACK: restoring the stock launcher and disabling this module"
    log "  overlay : $(cmd overlay disable com.axion.recents.overlay 2>&1)"
    log "  set-home: $(cmd package set-home-activity --user 0 com.motorola.launcher3/com.android.launcher3.CustomizationPanelLauncher 2>&1)"
    log "  start   : $(am start -a android.intent.action.MAIN -c android.intent.category.HOME 2>&1 | tr '\n' ' ')"
    sleep 3
    log "  HOME    : $(cmd role get-role-holders --user 0 android.app.role.HOME 2>&1 | tr '\n' ' ')"
    log "  moto pid: $(pidof com.motorola.launcher3 2>&1)"
    touch "$MODDIR/disable"
    date '+%Y-%m-%d %H:%M:%S' > /data/adb/axion_recents_crashloop
    log "  wrote $MODDIR/disable and /data/adb/axion_recents_crashloop"
    log "  NOTE: post-fs-data.sh will skip ALL mounts while the crashloop marker exists"
    if [ ! -f /data/adb/axion_recents_rebooted ]; then
        date '+%Y-%m-%d %H:%M:%S' > /data/adb/axion_recents_rebooted
        log "  one-shot reboot to a clean stock state"
        sync
        sleep 2
        reboot
    else
        log "  already rebooted once for this payload - leaving the device on stock without another reboot"
    fi
}

# v1.9 全程 logcat 环形记录 —— 必须在 boot_completed **之前**就开始：
# v1.8 那轮 SystemUI 的第一次崩溃发生在 boot_completed 之后 1~2 秒
# （13:15:28 boot-completed → 13:15:30 第一崩），晚启动的捕手什么也抓不到。
# 文件落在 /data 上，中途被系统重启也不会丢。
LOGCAT_RING=/data/adb/axion_logcat.txt
logcat -b main,system,crash,events -f "$LOGCAT_RING" -r 8192 -n 3 &
LOGCAT_PID=$!
log "logcat ring started (pid=$LOGCAT_PID -> $LOGCAT_RING, 3 x 8MB)"

# v1.9 辅助：谁在跑（launcher/桌面栈），用来判定 SystemUI 崩溃时是不是
# 原厂 com.motorola.launcher3 还活着 —— 它是设备上唯一含
# SystemUiProxy.moveDraggedBubbleToFullscreen 客户端调用的进程。
who_runs() {
    ps -A -o PID,NAME 2>/dev/null | grep -E 'launcher|desktop|systemui' | grep -v grep | tr '\n' ' '
}

log "waiting for sys.boot_completed"
i=0
until [ "$(getprop sys.boot_completed)" = "1" ] || [ $i -gt 120 ]; do sleep 5; i=$((i + 1)); done
sleep 20

# v1.9：boot_completed 到了**不算**健康 —— v1.8 实测：SystemUI 崩溃循环下 boot_completed
# 照样置位，而旧代码就在这里清掉开机计数，于是“崩溃 → 系统自行重启 → 第二次照样挂载”
# 变成无限循环。现在开机计数保留给 post-fs-data 的守卫，健康标记只由看门狗写。
log "boot_completed seen; keeping the boot count for the guard (healthy marker comes only from the watchdog)"

# v1.9：环形记录已经在上面（boot_completed 等待之前）启动，这里不再重复启动 ——
# 否则会有两个 logcat 进程抢同一个文件。

if [ -f /data/adb/axion_recents_probe_no_recents ]; then
    log "PROBE MODE: probe marker present - our RRO should be withdrawn, recents/HOME stay stock this boot"
fi

log "=== mounts (expect 2 tmpfs + 1 bind + N pours) ==="
mount 2>/dev/null | grep -E 'priv-app|etc/permissions|AxionRecentsOverlay|framework-rro-launcher3' | while read -r l; do log "MNT $l"; done

log "=== app-namespace visibility (through SystemUI's mount namespace) ==="
p=$(pidof com.android.systemui)
if [ -n "$p" ]; then
    log "systemui pid=$p ns=$(readlink /proc/$p/ns/mnt 2>&1)"
    log "priv-app entries by app : $(ls /proc/$p/root/system_ext/priv-app/ 2>&1 | wc -l) (expect stock+1)"
    log "  listing               : $(ls /proc/$p/root/system_ext/priv-app/ 2>/dev/null | tr '\n' ' ')"
    # v1.5: the payload APK is whatever build-17 produced, so compare against the module's own
    # copy instead of the v1.4 literal 21095922 - a stale literal here reads like a failed install.
    log "  axion apk bytes       : $(wc -c < /proc/$p/root/system_ext/priv-app/AxionLauncher3/AxionLauncher3.apk 2>&1) (module payload: $(wc -c < "$MODDIR/payload/AxionLauncher3.apk" 2>&1))"
    log "  moto  apk bytes       : $(wc -c < /proc/$p/root/system_ext/priv-app/Launcher3QuickStep/Launcher3QuickStep.apk 2>&1) (expect 15737130)"
    log "  systemui apk bytes    : $(wc -c < /proc/$p/root/system_ext/priv-app/SystemUI/SystemUI.apk 2>&1) (expect 55758898)"
    log "permissions dir by app  : $(ls /proc/$p/root/system_ext/etc/permissions/ 2>/dev/null | wc -l) (expect 77)"
    log "  our allowlist bytes   : $(wc -c < /proc/$p/root/system_ext/etc/permissions/privapp-permissions-com.android.launcher3.xml 2>&1) (module payload: $(wc -c < "$MODDIR/payload/privapp-permissions-com.android.launcher3.xml" 2>&1))"
    log "  moto allowlist bytes  : $(wc -c < /proc/$p/root/system_ext/etc/permissions/privapp-permissions-com.motorola.launcher3.xml 2>&1) (expect 1853)"
    log "  rro magic path by app : $(wc -c < /proc/$p/root$RRO_MAGIC 2>&1) (app 看不到也没关系; OMS 在 system_server 里读)"
    log "  rro stock path by app : $(wc -c < /proc/$p/root$RRO_STOCK 2>&1) (原厂 com.motorola.overlay.launcher3, 期望 8542)"
    log "  rro magic (root ns)   : $(wc -c < $RRO_MAGIC 2>&1) (期望 $RRO_BYTES; /product/overlay 是 metamodule 的 ro tmpfs)"
else
    log "no systemui pid"
fi

log "=== overlay ==="
log "lookup    : $(cmd overlay lookup android android:string/config_recentsComponentName 2>&1)"
log "dump      : $(cmd overlay dump com.axion.recents.overlay 2>&1 | grep -E 'mState|mIsEnabled|mIsMutable|mPriority|mBaseCodePath' | tr -s ' ' | tr '\n' ' ')"
log "moto_rro  : $(cmd overlay dump com.motorola.overlay.launcher3 2>&1 | grep -E 'mState|mIsEnabled|mPriority|mBaseCodePath' | tr -s ' ' | tr '\n' ' ')"

log "=== packages (both should exist now: independent clusters) ==="
log "axion path: $(pm path com.android.launcher3 2>&1 | tr '\n' ' ')"
log "moto  path: $(pm path com.motorola.launcher3 2>&1 | tr '\n' ' ')"
log "axion codePath/version: $(dumpsys package com.android.launcher3 2>/dev/null | grep -E 'codePath|versionName|lastUpdateTime|pkgFlags|privateFlags' | tr -s ' ' | tr '\n' '|')"
log "moto  codePath/version: $(dumpsys package com.motorola.launcher3 2>/dev/null | grep -E 'codePath|versionName|lastUpdateTime' | tr -s ' ' | tr '\n' '|')"
log "axion privileged perms : $(dumpsys package com.android.launcher3 2>/dev/null | grep -E 'ACCESS_CONTEXTUAL_SEARCH|ACCESS_HIDDEN_PROFILES_FULL|ALLOW_SLIPPERY_TOUCHES|BIND_APPWIDGET|BROADCAST_CLOSE_SYSTEM_DIALOGS|CONTROL_REMOTE_APP_TRANSITION_ANIMATIONS|START_TASKS_FROM_RECENTS|STATUS_BAR:|STOP_APP_SWITCHES|WRITE_SECURE_SETTINGS|MANAGE_ACTIVITY_TASKS' | tr -s ' ' | tr '\n' '|')"
log "granted=true count (expect 73+) : $(dumpsys package com.android.launcher3 2>/dev/null | grep -c 'granted=true')"
log "moto granted count (expect 73)  : $(dumpsys package com.motorola.launcher3 2>/dev/null | grep -c 'granted=true')"

log "=== allowlist / boot safety (the v1.1 killer) ==="
log "$(logcat -d 2>/dev/null | grep -iE 'not in privileged permission allowlist|privapp|IllegalStateException|no longer exists|Failed to parse|Inconsistent package' | tail -10 | cut -c1-240 | tr '\n' '|')"

log "=== quickstep providers (expect 2: ours + moto) ==="
log "$(cmd package query-services --brief -a android.intent.action.QUICKSTEP_SERVICE 2>&1 | tr '\n' ' ')"

# RRO 是否真的生效 —— 用 OMS 的实际值判定（不看前提标记）
recents=$(cmd overlay lookup android android:string/config_recentsComponentName 2>&1)
rro_ok=$(cat /data/adb/axion_recents_rro_ok 2>/dev/null)
case "$recents" in
    com.android.launcher3/*) rro_eff=1 ;;
    *)                       rro_eff=0 ;;
esac
log "=== HOME role (recents=$recents | staged marker=$rro_ok) ==="
# v1.2 C-lite 判定：桥接模块是否在 LSPosed 里启用（v1.2 起不再需要任何标记文件）。
# 判据与 boot-completed.sh 完全一致：桥接在 system_server 里加载时用 XposedBridge.log() 写下
# 带**本开机 boot_id** 的握手行，LSPosed 把它落到 /data/adb/lspd/log/modules_<boot>.log。
# 桥接启用但 boot-completed 的探测失败时，它会写 `failed` 到 CLITE_STATE，下面的等待循环照样切回旧模式。
BRIDGE_LOG=$(ls -t /data/adb/lspd/log/modules_*.log 2>/dev/null | head -1)
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
clite=0
if [ -n "$BRIDGE_LOG" ] && [ -n "$BOOT_ID" ]; then
    bridge_boot=$(grep -a -o 'AxionDesktopBridge active in system_server.*boot=[0-9a-fA-F-]*' "$BRIDGE_LOG" 2>/dev/null | tail -1 | sed 's/.*boot=//')
    if [ -n "$bridge_boot" ] && [ "$bridge_boot" = "$BOOT_ID" ]; then
        clite=1
        log "C-LITE mode: bridge handshake for this boot (log=$BRIDGE_LOG boot_id=$BOOT_ID)"
    else
        log "not C-lite: no bridge handshake for this boot (log=$BRIDGE_LOG line_boot=${bridge_boot:-<none>} boot_id=$BOOT_ID)"
    fi
fi
# v2.0：boot-completed.sh 要带退避地重建原厂桌面进程、确认补丁真的进了进程（最多 12 轮 ≈ 4.4 分钟）
# 才算把 C-lite 建立起来；而本脚本的健康看门狗跟它的探测循环是**并发**的。早先看门狗只用 160 秒
# 就判定“原厂桌面没起来”并 ax_rollback（写 disable + 自动重启），把还没跑完的探测直接打断 —— 18:45
# 那次开机就是这么挂的。所以先等 boot-completed settle（CLITE_STATE 写成 ok / failed），最多等 5 分钟。
CLITE_STATE=/data/adb/axion_recents_clite_state
if [ "$clite" = "1" ]; then
    w=0
    while [ "$w" -lt 20 ]; do
        case "$(cat "$CLITE_STATE" 2>/dev/null)" in
            ok*)
                log "C-LITE settle: boot-completed finished the switch ($(cat "$CLITE_STATE" 2>/dev/null))"
                break
                ;;
            failed)
                log "C-LITE settle: boot-completed reported failure -> old mode"
                clite=0
                break
                ;;
        esac
        if ! cmd role get-role-holders --user 0 android.app.role.HOME 2>/dev/null | grep -q com.motorola.launcher3; then
            log "C-LITE settle: HOME role is no longer the stock launcher -> boot-completed fell back to the old mode"
            clite=0
            break
        fi
        sleep 15
        w=$((w + 1))
    done
    if [ "$clite" = "1" ] && [ "$w" -ge 20 ]; then
        log "C-LITE WARN: boot-completed did not settle within 300s (state: $(cat "$CLITE_STATE" 2>/dev/null)) - the watchdog will judge as-is"
    fi
fi
# 回原厂桌面的唯一办法是在 KernelSU 里停用本模块：那样本脚本不会运行、我们的 RRO 也不存在，
# PMS 会把 recents 组件还给 com.motorola.launcher3。
if [ "$rro_eff" != "1" ]; then
    log "SKIP: recents config does not point at com.android.launcher3 -> not taking HOME and not disabling the module"
    log "      (Axion is installed as a system app but the system still treats the stock launcher as recents)"
    log "HOME  : $(cmd role get-role-holders --user 0 android.app.role.HOME 2>&1 | tr '\n' ' ')"
    rm -f "$HOME_GRANTED"   # v1.10: HOME was never taken this boot - no stale marker
    log "done"
elif [ "$clite" = "1" ]; then
    log "=== C-LITE: HOME stays with the stock launcher, Axion provides the recents ==="
    # 判据不能用 dumpsys：recents 标志权限的放行发生在运行期（AMS/ATMS 的 checkPermission 漏斗），
    # dumpsys 只反映开机扫描时的清单授权，`MANAGE_ACTIVITY_TASKS: granted=true` 永远不会出现
    # （v2.0 实测踩过）。这里改成看补丁自己打的运行期日志。
    granted=$(logcat -d -s AXMOTO 2>/dev/null | grep -c granted)
    log "  LSPosed patch effect (AXMOTO runtime grant lines): $granted"
    log "  HOME      : $(cmd role get-role-holders --user 0 android.app.role.HOME 2>&1 | tr '\n' ' ')"
    log "  pids      : axion=$(pidof com.android.launcher3) moto=$(pidof com.motorola.launcher3)"
    log "  bound     : $(dumpsys activity services com.android.quickstep.TouchInteractionService 2>/dev/null | grep -cE 'c:com.android.systemui') systemui client(s) on a quickstep service"
    if [ "$granted" -lt 1 ]; then
        log "WARN: no AXMOTO grant lines in logcat (the ring buffer may just have rotated; boot-completed"
        log "      verified the patch functionally before leaving C-lite mode - check /data/adb/lspd/log if worried)"
    fi
    rm -f "$HOME_GRANTED"
    log "done (c-lite)"
else
    log "before: $(cmd role get-role-holders --user 0 android.app.role.HOME 2>&1 | tr '\n' ' ')"
    rm -f "$HOME_GRANTED"
    if ! cmd role get-role-holders --user 0 android.app.role.HOME 2>/dev/null | grep -q com.android.launcher3; then
        log "granting HOME to com.android.launcher3: $(cmd role add-role-holder --user 0 android.app.role.HOME com.android.launcher3 2>&1)"
        sleep 2
    fi
    log "after : $(cmd role get-role-holders --user 0 android.app.role.HOME 2>&1 | tr '\n' ' ')"
    # v1.10: 记录“本开机 HOME 已在我们手里”，供 watchdog 分支在 `cmd role` 失效时兜底判定。
    if cmd role get-role-holders --user 0 android.app.role.HOME 2>/dev/null | grep -q com.android.launcher3; then
        date '+%Y-%m-%d %H:%M:%S' > "$HOME_GRANTED"
        log "home_granted marker written ($HOME_GRANTED)"
    fi

    log "=== axion launcher health check ==="
    sleep 15
    apid=$(pidof com.android.launcher3)
    log "axion pid: $apid"
    log "moto  pid: $(pidof com.motorola.launcher3 2>&1)"
    log "$(logcat -b crash -d 2>/dev/null | grep -A3 -iE 'com.android.launcher3' | tail -20 | cut -c1-250 | tr '\n' '|')"
    if [ -z "$apid" ]; then
        log "FATAL: com.android.launcher3 is not running after the HOME grant"
        log "       restoring the stock launcher as HOME so the device stays usable without a reboot"
        log "set-home  : $(cmd package set-home-activity --user 0 com.motorola.launcher3/com.android.launcher3.CustomizationPanelLauncher 2>&1)"
        sleep 2
        log "home start: $(am start -a android.intent.action.MAIN -c android.intent.category.HOME 2>&1 | tr '\n' ' ')"
        sleep 3
        log "HOME      : $(cmd role get-role-holders --user 0 android.app.role.HOME 2>&1 | tr '\n' ' ')"
        log "moto pid  : $(pidof com.motorola.launcher3 2>&1)"
        log "       disabling this module - REBOOT to unload the priv-app mirror and the overlay"
        cmd overlay disable com.axion.recents.overlay >> "$LOG" 2>&1
        touch "$MODDIR/disable"
    fi
    log "done"
fi

# --- v1.7 / v1.9 崩溃循环看门狗调用点（无论上面走哪条分支都要跑）----------------
# 只在 Axion 真的是 HOME 持有者时才用“launcher 存活”口径观察；否则“取不到 pid”
# 本来就是正常状态（探针模式 / SKIP 分支下原厂桌面继续持有 HOME，Axion 只是被安装进来）。
# 这一段覆盖了 v1.6 漏掉的那条路径：即使 `cmd overlay lookup` 因为 system_server
# 正在重启而失败、脚本走了 SKIP 分支，只要 HOME 已经在 Axion 手里，照样观察+回滚。
dump_diag "before watchdog"
# v1.10: HOME 归属判定要能扛住 system_server 重启（`cmd role` 会返回
# "Can't find service: role"）。此时若本开机我们写下了 home_granted 标记、而且我们的
# launcher 进程确实在跑，就按“Axion 是 HOME 持有者”处理 ⇒ 走主动看门狗，崩溃循环会被
# 真正回滚（还原原厂 HOME + disable + 重启），而不是只写一个下次开机才生效的 disable。
ax_is_home=0
if cmd role get-role-holders --user 0 android.app.role.HOME 2>/dev/null | grep -q com.android.launcher3; then
    ax_is_home=1
elif [ -f "$HOME_GRANTED" ] && [ -n "$(pidof com.android.launcher3)" ]; then
    log "watchdog: 'cmd role' unavailable (system_server restarting) but $HOME_GRANTED is set and our launcher is running -> treating Axion as the HOME holder"
    ax_is_home=1
fi
# v2.0 C-lite：HOME 留在原厂桌面，Axion 只当 recents —— 判据是“两个进程都活着 + 没有崩溃循环”，
# 绝不 force-stop 原厂桌面；失败时照旧全量回滚（还原原厂 HOME、disable、重启）。
if [ "$clite" = "1" ]; then
    log "=== crash-loop watchdog (c-lite: HOME = com.motorola.launcher3, Axion = recents, 160s window) ==="
    if watchdog_clite; then
        dump_diag "c-lite watchdog healthy"
    else
        dump_diag "c-lite watchdog unhealthy"
        ax_rollback
    fi
elif [ "$ax_is_home" = "1" ]; then
    log "=== crash-loop watchdog (HOME holder = com.android.launcher3, 160s window) ==="
    if watchdog; then
        dump_diag "watchdog healthy"
    else
        dump_diag "watchdog unhealthy"
        ax_rollback
    fi
else
    log "watchdog: passive - com.android.launcher3 is not the HOME role holder (probe / SKIP branch)"
    if watchdog_passive; then
        dump_diag "passive healthy"
    else
        dump_diag "passive unhealthy"
        if [ -f "$HOME_GRANTED" ]; then
            log "PASSIVE FAIL: HOME was granted to Axion this boot -> full rollback (restore stock HOME, disable, reboot)"
            ax_rollback
        else
            log "PASSIVE FAIL: SystemUI crash-loops even with only our priv-app mirror mounted"
            log "             -> disabling the module (no auto reboot needed: recents/HOME were never taken)"
            touch "$MODDIR/disable"
            date '+%Y-%m-%d %H:%M:%S' > /data/adb/axion_recents_crashloop
        fi
    fi
fi
# v1.2 维护阶段：桥接 APK 由模块自己安装/升级，用户不需要再手动 `pm install`。
# 判据是内容哈希：已装的那份和 extras/ 里的一致就什么都不做（免得每次开机都替换包，让 LSPosed
# 重新加载模块）。必须用 `pm install -r`；**不要**用 adb install 的增量安装（路径会变得不可预测）。
HELPER_SRC="$MODDIR/extras/motodesktop-helper.apk"
HELPER_PKG=com.axion.motodesktop
ensure_helper_installed() {
    [ -f "$HELPER_SRC" ] || { log "helper: $HELPER_SRC missing in the module - skipping"; return 0; }
    sum_src=$(sha256sum "$HELPER_SRC" 2>/dev/null | cut -d' ' -f1)
    have=$(pm path "$HELPER_PKG" 2>/dev/null | head -1 | sed 's/^package://')
    sum_have=""
    [ -n "$have" ] && sum_have=$(sha256sum "$have" 2>/dev/null | cut -d' ' -f1)
    if [ -n "$sum_src" ] && [ "$sum_src" = "$sum_have" ]; then
        return 0
    fi
    if [ -n "$have" ]; then
        log "helper: updating $HELPER_PKG ($have ${sum_have:-?} -> ${sum_src:-?})"
    else
        log "helper: installing $HELPER_PKG from $HELPER_SRC"
    fi
    log "  pm install : $(pm install -r -d "$HELPER_SRC" 2>&1 | tr '\n' ' ')"
    have2=$(pm path "$HELPER_PKG" 2>/dev/null | head -1 | sed 's/^package://')
    log "  installed  : ${have2:-<none>}"
    if [ -n "$have2" ] && [ "$(sha256sum "$have2" 2>/dev/null | cut -d' ' -f1)" != "$sum_src" ]; then
        log "  WARNING: the installed helper still differs from the module copy - reinstall from KernelSU"
    fi
    log "  NOTE: enable $HELPER_PKG in LSPosed (scope: system framework + Moto launcher) and reboot for C-lite"
}

kill $LOGCAT_PID 2>/dev/null
log "logcat ring stopped (pid=$LOGCAT_PID)"
# v1.2：环形记录停了就删掉文件（v1.1 实测残留 3 x 8 MB ≈ 26 MB 且永不回收）。需要的证据已经由
# dump_diag() 摘录进 $DIAG，这里不必再留一份原始日志。
rm -f "$LOGCAT_RING" "$LOGCAT_RING".* 2>/dev/null
log "logcat ring files removed"
ensure_helper_installed
log "service.sh finished"
