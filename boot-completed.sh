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

# --- v2.0 C-lite 模式：原厂 Moto 桌面保留 HOME，Axion 只提供最近任务 --------------------
# 标记：/data/adb/axion_recents_stock_home（存在即启用本模式）
#
# 为什么必须配一个 LSPosed 补丁：我们的静态 RRO 把 config_recentsComponentName 指到
# com.android.launcher3 之后，PMS 只把带 recents 保护标志的权限（MANAGE_ACTIVITY_TASKS /
# REMOVE_TASKS / ROTATE_SURFACE_FLINGER …）授给"recents 包"⇒ 原厂 com.motorola.launcher3
# 失去它们，它的 QuickstepLauncher 一启动就在 RecentsAnimationDeviceState.<init> 抛
# SecurityException（v1.2 真机实测的崩溃循环）。补丁模块 com.axion.motodesktop 在
# system_server 里按 uid 把这些权限补回给原厂桌面（hook PermissionManagerServiceImpl.
# shouldGrantPermissionByProtectionFlags）。原厂桌面还有第二处崩溃：它用 application context
# 预热 task view pool，Android 12+ 的 ContextImpl.getDisplay() 对非视觉 context 直接抛
# UnsupportedOperationException ⇒ FATAL EXCEPTION: ViewPool-init（TaskThumbnailView）⇒ 崩溃循环；
# 补丁在应用进程里挂 android.app.ContextImpl#getDisplay 兜底返回默认显示器。
# 所以本模式**必须**先确认补丁真的生效。判据不能用 dumpsys：
#   recents 标志权限的放行发生在运行期（AMS/ATMS 的 checkPermission 漏斗），dumpsys 只反映
#   开机扫描时的清单授权，`MANAGE_ACTIVITY_TASKS: granted=true` 永远不会出现（v2.0 实测踩过）。
# 改用功能性探测：把 HOME 交给原厂桌面 → 看它的主进程是否稳定存活 + 拿到焦点 + 没有新崩溃。
# 不生效就退回旧行为（把 HOME 交给 com.android.launcher3），保证设备可用。
STOCK_HOME=/data/adb/axion_recents_stock_home
HEALTHY=/data/adb/axion_recents_healthy
BOOTCOUNT=/data/adb/axion_recents_bootcount
CLITE_STATE=/data/adb/axion_recents_clite_state
PATCH_PKG=com.axion.motodesktop
if [ -f "$STOCK_HOME" ]; then
    log "C-LITE MODE ($STOCK_HOME): the stock Moto launcher keeps HOME, Axion only serves recents"
    # 告诉 service.sh“切换正在进行”，别让它的健康看门狗在这里还没 settle 时就抢跑回滚（v2.0 踩过：
    # 看门狗 160 秒就下结论，而本探测最多要 12 轮 ≈ 4.4 分钟）。
    echo pending > "$CLITE_STATE"
    rm -f /data/adb/axion_recents_stock_home_kept
    APK_PATH=$(pm path $PATCH_PKG 2>/dev/null | head -1 | cut -d: -f2)
    log "  patch apk : $APK_PATH"
    # LSPosed 的 modules_config.db 是二进制 sqlite：只在里面找“我们这条 apk_path 是否还在”。
    # （早先用 `grep -ao '/data/app/[^"]*motodesktop[^"]*base\.apk'` 抽路径，DB 里没有 `"` 字节，
    #   匹配会一路吃到后续记录的二进制垃圾 ⇒ 每次都误报“路径已过期”。）
    if [ -n "$APK_PATH" ] && ! grep -aq "$APK_PATH" /data/adb/lspd/config/modules_config.db 2>/dev/null; then
        log "  WARNING: LSPosed 记的模块路径已过期（它会静默跳过该模块，权限/显示补丁都不生效）"
        log "           处理：在 LSPosed 管理器里把 $PATCH_PKG 关掉再打开，或重跑安装脚本"
    fi
    log "  recents   : $recents"
    log "  pm enable moto: $(pm enable com.motorola.launcher3 2>&1 | tr '\n' ' ')"
    if ! cmd role get-role-holders --user 0 android.app.role.HOME 2>/dev/null | grep -q com.motorola.launcher3; then
        log "  HOME -> moto : $(cmd role add-role-holder --user 0 android.app.role.HOME com.motorola.launcher3 2>&1)"
    fi
    # 关键（v2.0 实测）：LSPosed 的模块注入在开机后有一段时间不可用 —— 开机早期由系统自己拉起的
    # 原厂桌面进程拿不到补丁（18:26 / 18:31 两次 patch_loaded=0），同一开机晚些再重建进程就稳定拿到
    # （18:30 实测 AXMOTO 31 行、18:36 实测 2 行 + granted 行）。已经存在的进程不会补挂模块，
    # 所以只能"重建进程 + 检查补丁是否真的进了进程"这样带退避地重试，直到成功或超预算。
    # 每次重试前清一次 crash 缓冲：只统计本次重建之后的崩溃（开机早期原厂桌面可能已经在崩）。
    moto_ok=0
    i=1
    while [ "$i" -le 12 ]; do
        am force-stop com.motorola.launcher3 >/dev/null 2>&1
        logcat -b crash -c 2>/dev/null
        sleep 2
        # 显式启动原厂桌面的 activity（不依赖 HOME 解析），再补一个 HOME intent。
        am start -n com.motorola.launcher3/com.android.launcher3.CustomizationPanelLauncher >/dev/null 2>&1
        am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null 2>&1
        sleep 5
        p2=$(pidof com.motorola.launcher3)
        focused=$(dumpsys window 2>/dev/null | grep -c 'mCurrentFocus=.*com.motorola.launcher3')
        crashes=$(logcat -d -b crash 2>/dev/null | grep -c 'com.motorola.launcher3')
        axmoto=$(logcat -d -s AXMOTO 2>/dev/null | grep -c 'module loaded pkg=com.motorola.launcher3')
        log "  probe #$i : moto pid=$p2 focused=$focused crashes=$crashes patch_loaded=$axmoto uptime=$(cut -d. -f1 /proc/uptime)s"
        if [ -n "$p2" ] && [ "$focused" -ge 1 ] && [ "$crashes" -eq 0 ] && [ "$axmoto" -ge 1 ]; then
            moto_ok=1
            break
        fi
        i=$((i + 1))
        sleep 15
    done
    if [ "$moto_ok" = "1" ]; then
        log "  HOME after   : $(cmd role get-role-holders --user 0 android.app.role.HOME 2>&1 | tr '\n' ' ')"
        log "  pids         : axion=$(pidof com.android.launcher3) moto=$(pidof com.motorola.launcher3)"
        date '+%Y-%m-%d %H:%M:%S' > /data/adb/axion_recents_stock_home_kept
        rm -f /data/adb/axion_recents_home_granted
        # 探测已经功能性验证过（原厂桌面主进程稳定 + 有焦点 + 没有新崩溃），等于本开机是健康的：
        # 立刻补上健康标记，否则 post-fs-data 的崩溃守卫会把"还没等到 service.sh 看门狗写标记的正常开机"
        # 判成失败，连续两次就 touch disable 停用整个模块（v2.0 重启验证踩过这个坑）。
        date '+%Y-%m-%d %H:%M:%S' > "$HEALTHY"
        rm -f "$BOOTCOUNT" /data/adb/axion_recents_rebooted
        echo "ok $(date '+%Y-%m-%d %H:%M:%S')" > "$CLITE_STATE"
        log "done (c-lite: HOME untouched, recents = com.android.launcher3, healthy marker written)"
        exit 0
    fi
    echo failed > "$CLITE_STATE"
    log "  PATCH NOT EFFECTIVE or stock launcher unstable -> falling back to the old behaviour (hand HOME to com.android.launcher3)"
    log "  check that LSPosed has $PATCH_PKG enabled with the system framework in scope"
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
