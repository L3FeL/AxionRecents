#!/system/bin/sh
# Axion Recents - installer hook (runs during KernelSU/Magisk module install).
# Keep it defensive: no command here may abort the installation.
ui() { if command -v ui_print >/dev/null 2>&1; then ui_print "$*"; fi; }

# Version string for the banner comes from module.prop, so it can never go stale.
MODVER="$(sed -n 's/^version=//p' "$MODPATH/module.prop" 2>/dev/null | head -n 1)"
[ -n "$MODVER" ] || MODVER="(unknown version)"
ui "- Axion Recents $MODVER: installing (tmpfs mirror of priv-app + permissions, Axion package, static RRO)"
ui "- Default mode needs no configuration: reboot and the stacked recents are live."
ui "- Optional C-lite mode (stock Moto launcher keeps HOME, Axion only serves recents):"
ui "  enable 'Axion Desktop Bridge' in LSPosed (scope: system framework + Moto launcher) and reboot."
ui "  Turn it off again + reboot to go back to the default mode.  No other step is needed -"
ui "  the bridge APK ships in extras/ and this module installs/updates it by itself."
ui "  Details: extras/C-LITE.md"

chmod 0755 "$MODPATH/post-fs-data.sh" "$MODPATH/service.sh" "$MODPATH/boot-completed.sh" 2>/dev/null
chmod 0644 "$MODPATH/extras/motodesktop-helper.apk" 2>/dev/null

# v1.2: install the bundled LSPosed bridge right away, so the user only has to toggle it in LSPosed.
# v1.2.2: only when the installed copy is OLDER than the one in this zip.  Every `pm install` gives
# the APK a fresh /data/app/~~<random>/... path, while LSPosed keeps loading the path it cached in
# /data/adb/lspd/config/modules_config.db - once that path is gone the module is skipped silently
# and C-lite stops working (HOME goes back to the Axion launcher).  The bridge therefore has its own
# version (helper.prop, generated from the shipped APK by helper/build-helper.ps1) and a release
# that does not touch the bridge leaves the installed APK alone.
# Best effort - the KernelSU installer does not always have a live PackageManager (e.g. installs that
# happen before the system is up); service.sh retries on every boot.
HELPER="$MODPATH/extras/motodesktop-helper.apk"
BRIDGE_PKG=com.axion.motodesktop
bridge_want="$(sed -n 's/^versionCode=//p' "$MODPATH/helper.prop" 2>/dev/null | head -n 1)"
bridge_have=""
if command -v pm >/dev/null 2>&1; then
    bridge_have="$(pm dump "$BRIDGE_PKG" 2>/dev/null | sed -n 's/.*versionCode=\([0-9][0-9]*\).*/\1/p' | head -n 1)"
fi
if [ ! -f "$HELPER" ] || ! command -v pm >/dev/null 2>&1; then
    ui "- bridge APK: will be installed automatically on the next boot"
elif [ -n "$bridge_have" ] && [ -n "$bridge_want" ] && [ "$bridge_have" -ge "$bridge_want" ]; then
    ui "- bridge APK: already installed (versionCode $bridge_have >= $bridge_want), left untouched"
    ui "  (re-installing an unchanged bridge would move it to a new /data/app path and LSPosed"
    ui "   would keep loading the old one - see extras/C-LITE.md)"
else
    ui "- bridge APK v${bridge_want:-?}: $(pm install -r -d "$HELPER" 2>&1 | tr '\n' ' ')"
    bridge_new="$(pm path "$BRIDGE_PKG" 2>/dev/null | head -1 | sed 's/^package://')"
    lspd_db=/data/adb/lspd/config/modules_config.db
    if [ -f "$lspd_db" ]; then
        lspd_paths="$(grep -a -o '/data/app/[^/]*/com\.axion\.motodesktop-[^/]*/base\.apk' "$lspd_db" 2>/dev/null | sort -u)"
        for p in $lspd_paths; do
            [ "$p" = "$bridge_new" ] && continue
            ui "  WARNING: LSPosed still remembers the previous bridge path"
            ui "    cached : $p"
            ui "    actual : $bridge_new"
            ui "  Open LSPosed, switch 'Axion Desktop Bridge' off and on again, then reboot."
            ui "  Until then the bridge is skipped and the Axion launcher stays HOME."
        done
    fi
fi

# v1.2.2: clear the markers / disable file that the removed auto-disable circuit breaker left
# behind. If a previous version disabled this module on its own, KernelSU keeps it disabled while
# /data/adb/modules/axion_recents/disable exists - so installing over it must remove that file,
# otherwise the fresh install still looks "not enabled" in the manager.
for m in /data/adb/axion_recents_crashloop /data/adb/axion_recents_bootcount \
         /data/adb/axion_recents_rebooted /data/adb/axion_recents_needs_attention; do
    [ -f "$m" ] && rm -f "$m" 2>/dev/null && ui "- cleared stale marker $(basename "$m")"
done
for d in /data/adb/modules/axion_recents/disable "$MODPATH/disable"; do
    if [ -f "$d" ]; then
        rm -f "$d" 2>/dev/null && ui "- removed stale $d (a previous version disabled itself)"
    fi
done

# To go back to the stock launcher, disable this module in the KernelSU manager and reboot.
# All module payload files must carry the system_file SELinux label, exactly like
# the other working modules on this device (Iconify, uperf).
chcon -R u:object_r:system_file:s0 "$MODPATH" 2>/dev/null
ui "- Reboot required.  Log after boot: /data/adb/axion_recents.log"
true
