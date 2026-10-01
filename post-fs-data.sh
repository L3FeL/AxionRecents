#!/system/bin/sh
# Axion Recents - phase 1 (post-fs-data, before zygote/system_server)
#
# ---------------------------------------------------------------------------
# v1.4 相对 v1.3.1 只改一件事：**不再把我们的 APK 放进 Moto 的包目录**。
#
# v1.3.1 开机实测（AOSP android16-release 源码已定论）：
#   /system_ext/priv-app/<子目录> = **一个包（cluster）**。PMS 用
#   ApkLiteParseUtils.parseClusterPackageLite() 扫描目录；同一目录里出现第二个
#   base APK 时返回 INSTALL_PARSE_FAILED_BAD_MANIFEST ("Inconsistent package ...")
#   ⇒ **整个目录都不被扫描** ⇒ com.motorola.launcher3 与 com.android.launcher3
#   双双消失，InstallPackageHelper.prepareSystemPackageCleanUp() 按包名对账后打印
#   "System package com.motorola.launcher3 no longer exists; its data will be wiped"。
#   扫描路径里没有任务基于挂载点/文件系统/只读/verity 的跳过逻辑（路径判定只是
#   canonical 前缀比较），所以“挂载方式”从来不是问题，“一个目录两个 APK”才是。
#
# 另一个实测教训（探针那次开机崩溃）：
#   只读系统目录里**做文件 bind 只能盖住已存在的文件，不可能新增**。
#   把我们的 APK 放进 priv-app ⇒ 它被当作特权应用 ⇒ 必须有
#   /system_ext/etc/permissions/privapp-permissions-com.android.launcher3.xml，
#   该文件原厂不存在 ⇒ bind 失败 ⇒ 白名单缺失 ⇒ system_server 在 onSystemReady
#   抛 "Signature|privileged permissions not in privileged permission allowlist"
#   ⇒ 系统崩溃循环。要“新增”条目，只有目录级挂载（tmpfs + 逐项 bind 回来）。
#
# v1.4 的做法（全部是手工挂载，不用 KernelSU magic mount —— 实测 magic mount 对
# app 进程的 mount namespace 不可见，而 root 自己做的挂载可见）：
#
#   1) /system_ext/etc/permissions  挂 tmpfs(16m)，把 76 个原厂 *.xml 逐份拷进去，
#      再加我们的 privapp-permissions-com.android.launcher3.xml（10 条特权权限）。
#   2) /system_ext/priv-app         挂 tmpfs(16m)，把原厂 63 个子目录**逐个 bind**
#      回去（挂 tmpfs 之前先各自 bind 到 /data 暂存，避免传播陷阱：直接 bind 父目录
#      会继承 shared 传播组，随后挂 tmpfs 会反向污染暂存源 ⇒ 全部空目录；
#      本机 toybox 的 mount --make-private 不可用），再新增**兄弟目录**
#         /system_ext/priv-app/AxionLauncher3/AxionLauncher3.apk   （独立 cluster）
#      Moto 的 Launcher3QuickStep/ 目录原样保留 ⇒ 两个桌面包同时存在。
#   3) 静态 RRO 交给 KernelSU magic mount：本模块树里的
#         system/product/overlay/AxionRecentsOverlay.apk
#      会被 metamodule（magic_mount_rs，本机因为 Iconify 一直在给 /product/overlay
#      做 tmpfs）挂成 /product/overlay/AxionRecentsOverlay.apk。本脚本**不做任何
#      RRO 挂载**（实测教训见第 4 节的注释：手工 bind 老路径会把原厂 RRO
#      com.motorola.overlay.launcher3 盖掉，而且 metamodule 灌注老路径的时间点晚于
#      本脚本，bind 常常直接失败）。OMS 在 system_server 里解析 RRO，app 命名空间
#      看不见也没关系。
#
# 安全规则（v1.4 的核心）：
#   * 暂存不完整 ⇒ 一个挂载都不做（完全原厂）。
#   * 权限目录镜像失败 ⇒ 不做 priv-app 镜像（否则“特权应用无白名单”崩系统）。
#   * priv-app 镜像校验不过 ⇒ 拆掉两个镜像（保持原厂 recents 配置）。
#   * RRO 一旦生效，recents 就指给我们的包，原厂 Moto 桌面因此失去 signature|recents
#     的 MANAGE_ACTIVITY_TASKS（v1.2 已验证的后果），所以 boot-completed.sh /
#     service.sh 必须在同一次开机里把 HOME 交给 com.android.launcher3，并在它起不来时
#     自动停用模块。RRO 是否真的生效由这两个阶段用 OMS 查询判定，不看本脚本的标记。
#
# 停用模块 + 重启 = 完全恢复原厂（磁盘上原厂文件从未被改动）。
# ---------------------------------------------------------------------------

MODDIR=${0%/*}
P="$MODDIR/payload"
LOG=/data/adb/axion_recents.log
STAGE=/data/local/tmp/axion-stage
PRIV=/system_ext/priv-app
NEWPKG="$PRIV/AxionLauncher3"
PERM_DIR=/system_ext/etc/permissions
STOCK_APK="$PRIV/Launcher3QuickStep/Launcher3QuickStep.apk"
MOTO_XML="$PERM_DIR/privapp-permissions-com.motorola.launcher3.xml"
RRO_SRC="$MODDIR/system/product/overlay/AxionRecentsOverlay.apk"  # 我们交给 metamodule 的源文件（模块树里）
RRO_MAGIC=/product/overlay/AxionRecentsOverlay.apk        # metamodule 把它挂到这里（system_server 可见）
RRO_STOCK=/product/overlay/framework-rro-launcher3.apk     # 原厂静态 RRO（com.motorola.overlay.launcher3, priority 1）——绝对不要覆盖
RRO_BYTES=8339                                            # 我们的 RRO 大小，用来确认挂上的是我们的文件

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [post-fs-data] $*" >> "$LOG"; }

log "start MODDIR=$MODDIR"

# --- 本模块没有“切换启动器”开关 ------------------------------------------------------
# 回原厂桌面 = 在 KernelSU 管理器里停用本模块 + 重启。那时本模块的文件一个都不挂载，
# 我们的静态 RRO 不存在 ⇒ config_recentsComponentName 仍是原厂的
# com.motorola.launcher3/... ⇒ 原厂桌面继续持有 signature|recents 的
# MANAGE_ACTIVITY_TASKS，而我们的 com.android.launcher3 包随之消失（HOME/recents 都归原厂）。
# 想再用 Axion 堆叠后台就在管理器里重新启用 + 重启。
# 下面只保留“上一次模块开机不健康就自动停用自己”的熔断，它仍会自动写 disable。
# （原厂 /product/overlay/framework-rro-launcher3.apk 我们从来不动，停用即恢复原厂。）

# --- 探针模式（v1.9）：撤掉 RRO、只挂 priv-app 镜像，recents/HOME 保持原厂 ---------
# 用法（主机侧、重启前）：把模块树里的 RRO 改名藏起来 + touch 下面的标记。
#   mv system/product/overlay/AxionRecentsOverlay.apk _rro_withdrawn.apk
#   touch /data/adb/axion_recents_probe_no_recents
# 目的：二分定位“模块启用后 SystemUI 崩溃循环”的触发者到底是不是
# “recents 配置改指 + HOME 换人”，还是“priv-app 镜像 / 我们的包存在”本身。
# ⚠ 注意：正常使用中**必须**保持模块树里有那份 RRO。手动 park 掉之后
#   如果把 HOME 留给了 com.android.launcher3，Axion 桌面会因为拿不到 signature|recents 的
#   MANAGE_ACTIVITY_TASKS 而崩溃循环，service.sh 的看门狗会把原厂桌面抢回来并停用本模块。
#   诊断完请把文件改回 system/product/overlay/AxionRecentsOverlay.apk 再重启。
PROBE=/data/adb/axion_recents_probe_no_recents
if [ -f "$PROBE" ]; then
    log "PROBE MODE ($PROBE): recents/HOME stay with the stock launcher this boot"
    [ -f "$MODDIR/_rro_withdrawn.apk" ] && log "PROBE MODE: our RRO is withdrawn from the module tree"
fi

# --- 开机失败自动停用（v1.9 收紧：只有"上一次模块生效的开机被看门狗判定健康"才放行）
# v1.6~v1.8 的旧口径是 service.sh 一看到 sys.boot_completed 就清计数，于是
# “启机后崩溃 → 系统自己重启 → 计数被清 → 第二次照样挂载”会无限循环。
# v1.8 实测：SystemUI 崩溃循环把设备反复重启，两次开机都挂载了 payload。
# 新口径：健康标记 $HEALTHY 只由 service.sh 的看门狗（观察 160 秒无崩溃）写入。
#   * 标记存在  = 上一次模块生效的开机是健康的 ⇒ 消费掉它、计数归 1、正常挂载。
#   * 标记不存在 且 计数 >= 2 ⇒ 上一次模块生效的开机没能健康结束 ⇒ 本次完全不挂载，
#     退回原厂，并 touch disable 等用户处理。
HEALTHY=/data/adb/axion_recents_healthy
GUARD=/data/adb/axion_recents_bootcount
prev_healthy=no
[ -f "$HEALTHY" ] && prev_healthy=yes
if [ "$prev_healthy" = yes ]; then
    rm -f "$HEALTHY"
    echo 1 > "$GUARD"
    n=1
else
    n=0
    [ -f "$GUARD" ] && n=$(cat "$GUARD" 2>/dev/null)
    n=$((n + 1))
    echo "$n" > "$GUARD"
fi
log "boot attempt $n (previous module boot healthy: $prev_healthy)"
if [ "$n" -ge 2 ]; then
    log "GUARD: boot attempt $n without a healthy marker - skipping all mounts and disabling the module"
    log "  上一次模块生效的开机没有健康结束（崩溃/自行重启）。修复后先 rm -f $GUARD $MODDIR/disable 再重启"
    touch "$MODDIR/disable"
    exit 0
fi

# v2.0 C-lite：boot-completed.sh 会写 /data/adb/axion_recents_clite_state（pending -> ok/failed）
# 表示“本次开机的 C-lite 切换是否已经 settle”。service.sh 靠它决定要不要等 boot-completed
# 做完再启动健康看门狗（否则看门狗会在探测还没跑完时就判定不健康并回滚）。每开机先清掉。
rm -f /data/adb/axion_recents_clite_state

# --- v1.7 崩溃循环熔断（上一次开机 service.sh 判定桌面崩溃循环时留下的标记）------
# 标记存在 ⇒ 本次开机**完全不挂载**：不新增 priv-app 目录、不启用 RRO，
# 系统以“原厂桌面 + 原厂 recents 配置”启动。这样即使 payload 有问题，
# 设备也只会退回原厂，而不会出现“HOME 反复崩溃 + system_server 重启”。
CRASHLOOP=/data/adb/axion_recents_crashloop
if [ -f "$CRASHLOOP" ]; then
    log "CRASHLOOP marker present ($(cat "$CRASHLOOP" 2>/dev/null)) - skipping all mounts"
    log "  修复 payload 后，删除 $CRASHLOOP 与 $MODDIR/disable 再重启即可重试"
    touch "$MODDIR/disable"
    exit 0
fi

# --- 等分区就绪 -----------------------------------------------------------
i=0
while [ ! -f "$STOCK_APK" ] && [ $i -lt 30 ]; do sleep 1; i=$((i+1)); done
if [ ! -f "$STOCK_APK" ]; then
    log "FATAL: stock launcher apk never appeared; skipping"
    exit 0
fi
if [ ! -f "$MOTO_XML" ]; then
    log "FATAL: stock moto allowlist missing; skipping"
    exit 0
fi

mount_tmpfs() {   # $1=dir $2=size
    if grep -q " $1 " /proc/self/mountinfo; then
        log "note: $1 already a mountpoint, unmounting first"
        umount -l "$1" 2>/dev/null
        sleep 1
    fi
    # 注意：这里**不能**用 -o context=u:object_r:system_file:s0
    #   SELinux 的 filesystem associate 检查会 EPERM（avc denied { associate }），
    #   先不带 context 挂上（默认 u:object_r:tmpfs:s0），挂完再 chcon。
    err=$(mount -t tmpfs -o "mode=0755,size=$2" tmpfs "$1" 2>&1) || {
        log "FAIL  mount tmpfs $1 : $err"
        return 1
    }
    chcon u:object_r:system_file:s0 "$1" 2>/dev/null
    log "OK    tmpfs over $1 (size=$2)"
    return 0
}

# ==========================================================================
# 1. 暂存（必须在任何 tmpfs 之前完成）
# ==========================================================================
rm -rf "$STAGE"
mkdir -p "$STAGE/privstage" "$STAGE/permissions" "$STAGE/newpkg/AxionLauncher3"

stock_total=0
staged=0
for d in "$PRIV"/*; do
    [ -d "$d" ] || continue
    stock_total=$((stock_total + 1))
    name=${d##*/}
    mkdir -p "$STAGE/privstage/$name"
    if mount --bind "$d" "$STAGE/privstage/$name" 2>/dev/null; then
        staged=$((staged + 1))
    else
        log "FAIL  stage bind $name"
    fi
done
log "staged $staged / $stock_total stock priv-app subdirs (each individually bound to /data)"
if [ "$staged" -lt "$stock_total" ] || [ "$stock_total" -lt 10 ]; then
    log "FATAL: staging incomplete (staged=$staged total=$stock_total) - no mounts this boot"
    exit 0
fi
# 抽查暂存内容（空目录说明踩了传播陷阱）
if [ ! -f "$STAGE/privstage/Launcher3QuickStep/Launcher3QuickStep.apk" ]; then
    log "FATAL: staged Launcher3QuickStep is empty (propagation trap) - no mounts this boot"
    exit 0
fi
log "stage spot-check Launcher3QuickStep.apk = $(stat -c %s "$STAGE/privstage/Launcher3QuickStep/Launcher3QuickStep.apk") bytes"

# 权限目录：76 个原厂 xml + 我们的白名单
pcnt=0
for f in "$PERM_DIR"/*.xml; do cp -f "$f" "$STAGE/permissions/" 2>/dev/null && pcnt=$((pcnt+1)); done
cp -f "$P/privapp-permissions-com.android.launcher3.xml" "$STAGE/permissions/" || log "FAIL copy our allowlist"
log "staged $pcnt stock permission xml + ours = $(ls "$STAGE/permissions" | wc -l) files"

# 我们的启动器（独立包目录）
cp -f "$P/AxionLauncher3.apk" "$STAGE/newpkg/AxionLauncher3/AxionLauncher3.apk" \
    && log "staged axion apk $(stat -c %s "$STAGE/newpkg/AxionLauncher3/AxionLauncher3.apk") bytes"
cp -f "$P/AxionRecentsOverlay.apk" "$STAGE/AxionRecentsOverlay.apk" \
    && log "staged rro $(stat -c %s "$STAGE/AxionRecentsOverlay.apk") bytes"

chmod 0644 "$STAGE/newpkg/AxionLauncher3/"*.apk "$STAGE/permissions/"*.xml "$STAGE/AxionRecentsOverlay.apk" 2>/dev/null
chmod 0755 "$STAGE/privstage" "$STAGE/permissions" "$STAGE/newpkg" "$STAGE/newpkg/AxionLauncher3" 2>/dev/null
chcon -R u:object_r:system_file:s0 "$STAGE/newpkg" 2>/dev/null
chcon u:object_r:system_file:s0 "$STAGE/AxionRecentsOverlay.apk" 2>/dev/null

# ==========================================================================
# 2. 权限目录镜像（先做：它单独存在是无害的）
# ==========================================================================
perm_ok=0
if mount_tmpfs "$PERM_DIR" 16m; then
    cp -af "$STAGE/permissions/." "$PERM_DIR"/ && chmod 0644 "$PERM_DIR"/* 2>/dev/null
    chcon -R u:object_r:system_file:s0 "$PERM_DIR" 2>/dev/null
    pnow=$(ls "$PERM_DIR" | wc -l)
    if [ "$pnow" -ge 70 ] && [ -f "$PERM_DIR/privapp-permissions-com.android.launcher3.xml" ] \
       && [ "$(stat -c %s "$MOTO_XML" 2>/dev/null)" = "1853" ]; then
        perm_ok=1
        log "OK    permissions mirror verified: $pnow files, moto allowlist 1853, ours $(stat -c %s "$PERM_DIR/privapp-permissions-com.android.launcher3.xml")"
    else
        log "FAIL  permissions mirror verify: $pnow files / moto=$(stat -c %s "$MOTO_XML" 2>/dev/null)"
    fi
else
    log "FAIL  tmpfs over $PERM_DIR"
fi
if [ "$perm_ok" != 1 ]; then
    log "ABORT: permissions mirror unusable -> tearing it down, no priv-app mirror, no RRO"
    umount -l "$PERM_DIR" 2>/dev/null
    exit 0
fi

# ==========================================================================
# 3. priv-app 镜像 + 新增独立包目录
# ==========================================================================
priv_ok=0
if mount_tmpfs "$PRIV" 16m; then
    poured=0
    for s in "$STAGE/privstage"/*; do
        name=${s##*/}
        mkdir -p "$PRIV/$name"
        mount --bind "$s" "$PRIV/$name" 2>/dev/null && poured=$((poured + 1)) || log "FAIL pour $name"
    done
    mkdir -p "$NEWPKG"
    mount --bind "$STAGE/newpkg/AxionLauncher3" "$NEWPKG" 2>/dev/null
    chcon u:object_r:system_file:s0 "$PRIV" "$NEWPKG" "$NEWPKG/AxionLauncher3.apk" 2>/dev/null
    now=$(ls "$PRIV" | wc -l)
    if [ "$poured" = "$stock_total" ] && [ "$now" -eq "$((stock_total + 1))" ] \
       && [ -f "$PRIV/SystemUI/SystemUI.apk" ] && [ -f "$STOCK_APK" ] \
       && [ -f "$NEWPKG/AxionLauncher3.apk" ]; then
        priv_ok=1
        log "OK    priv-app mirror verified: $now entries ($stock_total stock + AxionLauncher3)"
        log "      axion pkg file $(stat -c %s "$NEWPKG/AxionLauncher3.apk") bytes label $(ls -Z "$NEWPKG/AxionLauncher3.apk" 2>/dev/null | awk '{print $1}')"
        log "      moto  pkg dir  $(ls "$PRIV/Launcher3QuickStep" | tr '\n' ' ')"
    else
        log "FAIL  priv-app mirror verify: poured=$poured/$stock_total entries=$now newpkg=$(ls "$NEWPKG" 2>/dev/null | tr '\n' ' ')"
    fi
else
    log "FAIL  tmpfs over $PRIV"
fi

if [ "$priv_ok" != 1 ]; then
    log "ABORT: tearing down priv-app mirror + permissions mirror (stay stock), no RRO"
    for s in "$STAGE/privstage"/*; do name=${s##*/}; umount -l "$PRIV/$name" 2>/dev/null; done
    umount -l "$NEWPKG" 2>/dev/null
    umount -l "$PRIV" 2>/dev/null
    umount -l "$PERM_DIR" 2>/dev/null
    exit 0
fi

# ==========================================================================
# 4. 静态 RRO —— 只交给 KernelSU magic mount（本脚本不挂载任何东西）
#
# 机制实测（2026-09-26）：
#   * 本机 /product/overlay 被 metamodule 换成一个只读 tmpfs
#     （`KSU /product/overlay tmpfs ro,seclabel,relatime,size=5821156k,...`），因为
#     Iconify 模块在这个目录里放了 51 个 IconifyComponent*.apk；原厂 154 个 overlay
#     文件也都被逐个 bind 进这个 tmpfs。
#   * 原厂**文件** /product/overlay/framework-rro-launcher3.apk 确实存在，它是原厂静态
#     RRO（aapt2: package com.motorola.overlay.launcher3, versionCode 36, priority 1,
#     targetPackage android, isStatic true, 8542 字节），由 metamodule 灌注进来。
#     灌注时间点**晚于**本脚本 ⇒ 手工 bind 盖住它有双重坏处：
#       (a) 原厂 RRO 被我们那份替换（com.motorola.overlay.launcher3 解析失败）；
#       (b) 目标还不存在时 bind 直接失败。
#   * 正确做法 = 把我们的 RRO 放在本模块自己的 system/product/overlay/，由 metamodule
#     挂进 /product/overlay（system_server 命名空间可见，OMS 正好在那里扫描静态 RRO）。
#     两个 RRO 是不同包名（com.axion.recents.overlay priority 100 vs 原厂
#     com.motorola.overlay.launcher3 priority 1），可以并存，我们的值优先。
#   * 因此本脚本只检查“交付前提”（模块树里有那份 8339 字节的 RRO），不做挂载；
#     是否真的生效由 boot-completed.sh / service.sh 用 OMS 的
#     cmd overlay lookup android android:string/config_recentsComponentName 判定。
# ==========================================================================
rro_ok=0
if [ -f "$RRO_SRC" ] && [ "$(stat -c %s "$RRO_SRC" 2>/dev/null)" = "$RRO_BYTES" ]; then
    rro_ok=1
    log "OK    RRO staged for magic mount: $RRO_SRC ($(stat -c %s "$RRO_SRC") bytes)"
    if [ -f "$RRO_MAGIC" ]; then
        log "note  $RRO_MAGIC already visible ($(stat -c %s "$RRO_MAGIC") bytes, label $(ls -Z "$RRO_MAGIC" 2>/dev/null | awk '{print $1}'))"
    else
        log "note  $RRO_MAGIC not visible yet - the metamodule pours /product/overlay later in boot"
    fi
    rm -f /data/resource-cache/*AxionRecentsOverlay* 2>/dev/null
    log "removed stale idmap for our overlay"
else
    log "FAIL  RRO not staged in the module tree ($RRO_SRC) - recents stays stock"
fi
# 这个标记只表示“交付前提成立”，不表示 RRO 已经生效；后续阶段用 OMS 查询判定真正状态。
echo "$rro_ok" > /data/adb/axion_recents_rro_ok

# ==========================================================================
# 5. 落盘证据
# ==========================================================================
log "--- readable check (init namespace) ---"
for f in "$STOCK_APK" "$NEWPKG/AxionLauncher3.apk" \
         "$PERM_DIR/privapp-permissions-com.android.launcher3.xml" "$MOTO_XML" "$RRO_MAGIC"; do
    if [ -r "$f" ]; then log "READ  $f ($(stat -c %s "$f") bytes, label $(ls -Z "$f" 2>/dev/null | awk '{print $1}'))"
    else log "UNREADABLE $f"; fi
done
log "priv-app entries=$(ls "$PRIV" | wc -l) permissions files=$(ls "$PERM_DIR" | wc -l) mounts=$(mount | grep -c -E "priv-app|etc/permissions|framework-rro-launcher3")"
log "done"
