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
# Best effort - the KernelSU installer does not always have a live PackageManager (e.g. installs that
# happen before the system is up); service.sh retries on every boot until the installed copy's hash
# matches extras/, so a failure here is harmless.
HELPER="$MODPATH/extras/motodesktop-helper.apk"
if [ -f "$HELPER" ] && command -v pm >/dev/null 2>&1; then
    ui "- bridge APK: $(pm install -r -d "$HELPER" 2>&1 | tr '\n' ' ')"
else
    ui "- bridge APK: will be installed automatically on the next boot"
fi

# To go back to the stock launcher, disable this module in the KernelSU manager and reboot.
# All module payload files must carry the system_file SELinux label, exactly like
# the other working modules on this device (Iconify, uperf).
chcon -R u:object_r:system_file:s0 "$MODPATH" 2>/dev/null
ui "- Reboot required.  Log after boot: /data/adb/axion_recents.log"
true
