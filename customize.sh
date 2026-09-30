#!/system/bin/sh
# Axion Recents - installer hook (runs during KernelSU/Magisk module install).
# Keep it defensive: no command here may abort the installation.
if command -v ui_print >/dev/null 2>&1; then
    ui_print "- Axion Recents v1.0: installing (tmpfs mirror of priv-app + permissions, new Axion package, static RRO)"
fi
chmod 0755 "$MODPATH/post-fs-data.sh" "$MODPATH/service.sh" "$MODPATH/boot-completed.sh" 2>/dev/null
# To go back to the stock launcher, disable this module in the KernelSU manager and reboot.
# All module payload files must carry the system_file SELinux label, exactly like
# the other working modules on this device (Iconify, uperf).
chcon -R u:object_r:system_file:s0 "$MODPATH" 2>/dev/null
if command -v ui_print >/dev/null 2>&1; then
    ui_print "- Reboot required.  Log after boot: /data/adb/axion_recents.log"
fi
true
