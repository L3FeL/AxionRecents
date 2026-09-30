#!/system/bin/sh
# Axion Recents - phase 3 (boot-completed): enable our launcher and take the HOME role
# as early as possible.
#
# 为什么必须在这里换 HOME：
#   我们的静态 RRO 已把 config_recentsComponentName 指到 com.android.launcher3。
#   PMS 只在开机构造时按这个值算一次 mRecentsPackage，**只有它**能拿到
#   signature|recents 的 MANAGE_ACTIVITY_TASKS。原厂 com.motorola.launcher3 因此
#   失去该权限，它的 QuickstepLauncher 一启动就在 RecentsAnimationDeviceState.<init>
#   抛 SecurityException（v1.2 实测的崩溃循环）。所以在同一次开机里必须把 HOME 交给
#   com.android.launcher3；由 service.sh 负责在它起不来时自动停用模块。
#
# 安全分支：
#   * 忘记 pm enable：新出现的系统包可能被扫成 stopped。
#   * 如果 PMS 根本没装上 com.android.launcher3（RRO 已指向它 = 没有包持有
#     signature|recents ⇒ 原厂桌面会崩），立刻 touch disable 并尝试关掉我们的 RRO，
#     让下一次重启回到原厂。
MODDIR=${0%/*}
LOG=/data/adb/axion_recents.log
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [boot-completed] $*" >> "$LOG" 2>/dev/null; }

log "boot completed"
if [ -f /data/adb/axion_recents_probe_no_recents ]; then
    log "PROBE MODE: recents/HOME intentionally stay with the stock launcher this boot"
    log "            our RRO withdrawn=$( [ -f "$MODDIR/_rro_withdrawn.apk" ] && echo yes || echo no )"
fi

# --- 本模块没有“切回原厂桌面”这条分支 -----------------------------------------------
# 要回原厂桌面就在 KernelSU 里**停用本模块**（或移除它）+ 重启 —— 那时本脚本根本不会跑，
# 我们的静态 RRO 也不存在，PMS 会像装机前一样把 signature|recents 的
# MANAGE_ACTIVITY_TASKS 给 com.motorola.launcher3。
# 本脚本只在模块启用时运行，一律把 HOME 交给 Axion（下面那条路）。


pkg=$(pm path com.android.launcher3 2>&1)
log "axion path: $pkg"
if ! echo "$pkg" | grep -q 'AxionLauncher3.apk'; then
    log "FATAL: com.android.launcher3 not installed from our package dir - disabling module"
    log "       (recents config points at a missing package; reboot will restore stock)"
    cmd overlay disable com.axion.recents.overlay >> "$LOG" 2>&1
    touch "$MODDIR/disable"
    rm -f /data/adb/axion_recents_home_granted
    exit 0
fi

# RRO 必须已经生效：recents 配置指向 com.android.launcher3 之后，只有它能拿到
# signature|recents 的 MANAGE_ACTIVITY_TASKS。RRO 没生效就换 HOME 会得到
# “HOME 是 Axion、上滑却调用原厂 recents”的混合状态，所以此时什么都不做。
# 判定用 OMS 的**实际生效值**（config_recentsComponentName 的资源查询结果），
# 而不是 post-fs-data 写下的前提标记：那个标记只证明模块树里有那份 RRO，
# metamodule 灌注 /product/overlay 的时间点晚于 post-fs-data。
recents=$(cmd overlay lookup android android:string/config_recentsComponentName 2>&1)
rro_ok=$(cat /data/adb/axion_recents_rro_ok 2>/dev/null)
log "recents config: $recents (staged marker=$rro_ok)"
case "$recents" in
    com.android.launcher3/*) rro_eff=1 ;;
    *)                       rro_eff=0 ;;
esac
if [ "$rro_eff" != "1" ]; then
    log "SKIP: recents config does not point at com.android.launcher3 - leaving HOME with the stock launcher"
    log "      priv-app/permissions mirrors are up, so Axion is installed but not HOME; check the log"
    rm -f /data/adb/axion_recents_home_granted
    exit 0
fi

# v1.10：接管前后各停一次原厂 com.motorola.launcher3。
# 根因更正（v1.10 离线字节码复核）：v1.9 曾把 SystemUI 的气泡 NPE 归因于原厂桌面的
# moveDraggedBubbleToFullscreen 客户端调用，**这个结论是错的** —— 真正的触发者是我们自己的
# launcher：旧 fork 的 IBubbles.aidl 把 setHasBubbleBar 声明成 id 16（编译后事务码 17），
# 而设备 AOSP 16 的 SystemUI 把 17 当作 moveDraggedBubbleToFullscreen(String,Point)，布尔
# 载荷被 readString() 读成 null key ⇒ BubbleController 拿到 null Bubble ⇒ NPE ⇒ SystemUI 崩溃
# 循环。该错位已在 v1.10 修正（IBubbles.aidl 与 AOSP 16 对齐，setHasBubbleBar 不再发 binder）。
# 仍然停原厂桌面：接管 HOME/recents 后它失去 signature|recents 的 MANAGE_ACTIVITY_TASKS，
# 本身就是坏状态（v1.2 实测它会在 RecentsAnimationDeviceState.<init> 抛 SecurityException）。
log "apps before takeover: $(ps -A -o NAME 2>/dev/null | grep -E 'launcher|desktop|systemui' | tr '\n' ' ')"
log "force-stop moto (pre) : $(am force-stop com.motorola.launcher3 2>&1 | tr '\n' ' ')"

# 新系统包可能被扫成 stopped
# v1.10: 本开机的 HOME 标记从头开始算（service.sh 的看门狗用它兜底判定归属）。
rm -f /data/adb/axion_recents_home_granted
log "pm enable : $(pm enable com.android.launcher3 2>&1 | tr '\n' ' ')"

log "HOME before: $(cmd role get-role-holders --user 0 android.app.role.HOME 2>&1 | tr '\n' ' ')"
if ! cmd role get-role-holders --user 0 android.app.role.HOME 2>/dev/null | grep -q com.android.launcher3; then
    log "granting HOME to com.android.launcher3: $(cmd role add-role-holder --user 0 android.app.role.HOME com.android.launcher3 2>&1)"
fi
log "HOME after : $(cmd role get-role-holders --user 0 android.app.role.HOME 2>&1 | tr '\n' ' ')"
# v1.10: 记录“本开机 HOME 已在 Axion 手里”，供 service.sh 在 `cmd role` 因 system_server
# 重启而失效时兜底判定 HOME 归属（否则看门狗会误走被动分支，只写下次开机才生效的 disable）。
if cmd role get-role-holders --user 0 android.app.role.HOME 2>/dev/null | grep -q com.android.launcher3; then
    date '+%Y-%m-%d %H:%M:%S' > /data/adb/axion_recents_home_granted
    log "home_granted marker written"
else
    log "WARN: HOME is still not com.android.launcher3 after the grant attempt"
fi
log "axion pid: $(pidof com.android.launcher3 2>&1)"
log "moto  pid: $(pidof com.motorola.launcher3 2>&1)"
log "recents  : $(cmd overlay lookup android android:string/config_recentsComponentName 2>&1)"
# v1.9：第二次清扫（见上面 force-stop 的长注释）。原厂桌面可能在接管瞬间被
# Motorola 的 mobiledesktop / appprediction 之类重新拉起，这里再停一次并记录现场。
sleep 3
log "force-stop moto (post): $(am force-stop com.motorola.launcher3 2>&1 | tr '\n' ' ')"
log "apps after takeover : $(ps -A -o NAME 2>/dev/null | grep -E 'launcher|desktop|systemui' | tr '\n' ' ')"
log "done"
