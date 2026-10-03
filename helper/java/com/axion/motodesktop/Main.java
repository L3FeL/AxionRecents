package com.axion.motodesktop;

import android.app.Activity;
import android.content.Context;
import android.content.pm.PackageInfo;
import android.content.pm.PermissionInfo;
import android.hardware.display.DisplayManager;
import android.os.Binder;
import android.os.SystemClock;
import android.provider.Settings;
import android.util.Log;
import android.view.Display;
import android.view.MotionEvent;
import android.view.View;
import android.view.animation.PathInterpolator;

import java.io.BufferedReader;
import java.io.FileReader;
import java.lang.reflect.Member;
import java.lang.reflect.Method;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

import de.robv.android.xposed.IXposedHookLoadPackage;
import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;
import de.robv.android.xposed.callbacks.XC_LoadPackage;

/**
 * Axion Recents helper for the "Moto launcher as HOME, Axion as recents" setup (route C-lite).
 *
 * <p>Surface has exactly one recents component ({@code config_recentsComponentName}, which our RRO
 * points at Axion's Quickstep). AOSP therefore hands the {@code recents}-flagged protected
 * permissions (MANAGE_ACTIVITY_TASKS, REMOVE_TASKS, ROTATE_SURFACE_FLINGER, ...) only to Axion's
 * package. If the Moto launcher (com.motorola.launcher3) is made the default HOME it cannot get
 * them - {@code QuickstepLauncher.setupViews()} calls
 * {@code IActivityTaskManager.getRootTaskInfo()} during startup and dies with
 * {@code SecurityException: Permission Denial ... requires android.permission.MANAGE_ACTIVITY_TASKS}
 * - and there is no allowlist / {@code pm grant} / RRO path for such permissions.
 *
 * <p>This module runs inside system_server and makes the permission machinery answer "granted" for
 * those specific permissions when the caller is the target launcher. It only ever <em>grants</em>,
 * never denies, only for the target app id, and only for permissions that carry the platform's
 * {@code recents} protection flag (or are in the explicit fallback list).
 *
 * <p>It also runs inside the Moto launcher process itself, where it repairs the two home-screen
 * gestures that C-lite breaks. Both are implemented by the Moto launcher but executed through
 * {@code com.android.quickstep.SystemUiProxy}, whose {@code mSystemUiProxy} field is only filled
 * when SystemUI binds <em>this</em> launcher's TouchInteractionService. Because C-lite gives the
 * recents role to Axion, SystemUI binds Axion instead: the field stays null, so
 * {@code SystemUiProxy.isActive()} answers false (a swipe down is never intercepted) and
 * {@code lockDevice()} returns silently (the double tap dies at its last gate). See
 * {@link #installCliteGestureHooks}.
 */
public class Main implements IXposedHookLoadPackage {

    private static final String TAG = "AXMOTO";
    private static final String TARGET_PKG = "com.motorola.launcher3";
    private static final String SYSTEM_PKG = "android";
    private static final int PER_USER_RANGE = 100000;
    private static final int PERMISSION_GRANTED = 0;

    /**
     * Used when PermissionInfo.PROTECTION_FLAG_RECENTS cannot be reflected (older releases), and as
     * the exact list of extra permissions granted to the target launcher.
     *
     * <p>The C-lite gesture repair needs two ordinary (non-recents) permissions that the Moto
     * launcher does not request at all: DEVICE_POWER for PowerManager.goToSleep() and
     * EXPAND_STATUS_BAR for the notification-shade/control-centre expansion. Both are enforced
     * inside system_server through ContextImpl.enforceCallingOrSelfPermission, i.e. through the
     * funnel hooked below.
     */
    private static final Set<String> FALLBACK_RECENTS_PERMS = new HashSet<String>(Arrays.asList(
            "android.permission.MANAGE_ACTIVITY_TASKS",
            "android.permission.REMOVE_TASKS",
            "android.permission.ROTATE_SURFACE_FLINGER",
            "android.permission.WAKEUP_SURFACE_FLINGER",
            "android.permission.STOP_APP_SWITCHES",
            "android.permission.SET_ORIENTATION",
            "android.permission.CONTROL_REMOTE_APP_TRANSITION_ANIMATIONS",
            "android.permission.START_TASKS_FROM_RECENTS",
            "android.permission.DEVICE_POWER",
            "android.permission.EXPAND_STATUS_BAR"));

    private static final String[] CONTEXT_METHODS = new String[] {
            "checkPermission",
            "checkCallingPermission",
            "checkCallingOrSelfPermission",
            "enforcePermission",
            "enforceCallingPermission",
            "enforceCallingOrSelfPermission"};

    /**
     * Activities that can be the C-lite home. Moto's launcher is AOSP-derived, so the concrete
     * activity is {@code com.android.launcher3.uioverrides.QuickstepLauncher} (the manifest entry
     * {@code CustomizationPanelLauncher} is only its alias).
     */
    private static final String[] LAUNCHER_ACTIVITY_CLASSES = new String[] {
            "com.android.launcher3.uioverrides.QuickstepLauncher",
            "com.android.launcher3.Launcher"};

    private static final Map<String, Boolean> PERM_CACHE = new ConcurrentHashMap<String, Boolean>();
    private static final Set<String> LOGGED =
            Collections.newSetFromMap(new ConcurrentHashMap<String, Boolean>());

    private static volatile Context sSystemContext;
    private static volatile int sTargetAppId = -1;
    private static volatile int sRecentsFlag = Integer.MIN_VALUE;
    private static volatile int sHookCount;
    private static volatile boolean sSystemServer;
    /** Class loader of the Moto launcher process; null inside system_server. */
    private static volatile ClassLoader sTargetClassLoader;
    /** Uptime of the last "home arrives" animation, used to debounce activity resumes. */
    private static volatile long sLastArriveUptime;

    @Override
    public void handleLoadPackage(XC_LoadPackage.LoadPackageParam lpparam) throws Throwable {
        try {
            if (lpparam == null) {
                return;
            }
            final String pkg = lpparam.packageName;
            final boolean systemServer = SYSTEM_PKG.equals(pkg) && SYSTEM_PKG.equals(lpparam.processName);
            final boolean targetApp = TARGET_PKG.equals(pkg);
            if (!systemServer && !targetApp) {
                return;
            }
            Log.i(TAG, "module loaded pkg=" + pkg + " process=" + lpparam.processName);
            installHooks(lpparam.classLoader, systemServer);
            if (systemServer) {
                // v1.2: persistent, boot-scoped signal for the KernelSU module scripts.
                // LSPosed writes every XposedBridge.log() call into
                // /data/adb/lspd/log/modules_<boot>.log, which boot-completed.sh / service.sh read as
                // root to decide between C-lite (stock launcher keeps HOME) and the default mode.
                // The boot id makes the line unambiguous: a line left over from an earlier boot can
                // never switch the current boot into C-lite. Keep the prefix/label in sync with
                // BRIDGE_LOG_LABEL in boot-completed.sh + service.sh.
                XposedBridge.log("AxionDesktopBridge active in system_server hooks=" + sHookCount
                        + " boot=" + readBootId());
            }
        } catch (Throwable t) {
            Log.e(TAG, "handleLoadPackage failed", t);
        }
    }

    private static void installHooks(ClassLoader cl, boolean systemServer) {
        sSystemServer = systemServer;
        // The funnel every system_server caller goes through (this is the crash path).
        // NOTE: the class really is android.app.ContextImpl (android.content.ContextImpl does not
        // exist) - the wrong name silently disabled these hooks for a while.
        hookClass(cl, "android.app.ContextImpl", CONTEXT_METHODS);
        // Local permission helpers used inside each process.
        hookClass(cl, "android.app.ActivityManager",
                new String[] {"checkComponentPermission", "checkPermission"});
        hookClass(cl, "android.permission.PermissionManager",
                new String[] {"checkPermission", "checkUidPermission"});
        if (systemServer) {
            hookClass(cl, "android.app.ActivityManagerService",
                    new String[] {"checkComponentPermission", "checkPermission", "checkUidPermission",
                            "checkCallingPermission", "enforceCallingPermission"});
            hookClass(cl, "com.android.server.am.ActivityManagerService",
                    new String[] {"checkComponentPermission", "checkPermission", "checkUidPermission",
                            "checkCallingPermission", "enforceCallingPermission"});
            hookClass(cl, "com.android.server.wm.ActivityTaskManagerService",
                    new String[] {"checkCallingPermission", "enforceCallingPermission"});
            hookClass(cl, "com.android.server.pm.permission.PermissionManagerService",
                    new String[] {"checkPermission", "checkUidPermission"});
            hookClass(cl, "com.android.server.pm.permission.PermissionManagerServiceImpl",
                    new String[] {"checkPermission", "checkUidPermission"});
            hookClass(cl, "com.android.server.permission.access.permission.PermissionService",
                    new String[] {"checkPermission", "checkUidPermission"});
            hookClass(cl, "com.android.server.permission.access.AccessCheckingService",
                    new String[] {"checkPermission", "checkUidPermission"});
            // The precise grant point: called once per requested signature permission while the
            // package is scanned. Forcing it true makes the permission really granted, so every
            // later check path (new or old permission architecture) sees PERMISSION_GRANTED.
            hookMethod(cl, "com.android.server.pm.permission.PermissionManagerServiceImpl",
                    "shouldGrantPermissionByProtectionFlags", new GrantByFlagsHook());
        } else {
            sTargetClassLoader = cl;
            // Target app process only: Moto's launcher builds its task view pool on a background
            // thread with a non-visual context, and Android 12+ makes Context.getDisplay() throw
            // for those. See DisplayFallbackHook.
            hookMethod(cl, "android.app.ContextImpl", "getDisplay", new DisplayFallbackHook());
            // Repair the two home-screen gestures C-lite breaks (mSystemUiProxy is never set).
            installCliteGestureHooks(cl);
        }
        Log.i(TAG, "hooks installed: " + sHookCount);
    }

    /**
     * C-lite gesture repair, installed in the {@code com.motorola.launcher3} process only.
     *
     * <p>Reason the stock code is dead: {@code SystemUiProxy.mSystemUiProxy} is assigned by
     * {@code TouchInteractionService$TISBinder.setProxy()} and SystemUI only binds the service of
     * the package named by {@code config_recentsComponentName}. C-lite points that at Axion, so the
     * Moto launcher never gets a proxy:
     * <ul>
     *   <li>double tap on empty workspace -> {@code WorkspaceTouchListener.lockScreen()} ->
     *       {@code SystemUiProxy.lockDevice(true)} -> {@code if (mSystemUiProxy == null) return}
     *       (no log, no action);</li>
     *   <li>swipe down on workspace -> {@code StatusBarTouchController.canInterceptTouch()} ->
     *       {@code return SystemUiProxy.isActive()} -> false, so the gesture is never even
     *       intercepted.</li>
     * </ul>
     *
     * <p>All five hooks below only act when the proxy really is missing, so a launcher that does own
     * the recents role keeps its stock behaviour.
     */
    private static void installCliteGestureHooks(ClassLoader cl) {
        // 1) Keep the double tap active. Utilities.isSleepScreenEnabled() decides whether the
        //    gesture does anything and is called from exactly one place (WorkspaceTouchListener).
        hookMethod(cl, "com.android.launcher3.Utilities", "isSleepScreenEnabled",
                new SleepScreenGateHook());
        // 2) Let the swipe-down touch stream through the interception gate.
        hookMethod(cl, "com.android.quickstep.SystemUiProxy", "isActive", new SystemUiActiveHook());
        // 3) Perform the expansion the forwarded stream used to trigger in SystemUI.
        hookMethod(cl, "com.android.quickstep.SystemUiProxy", "onStatusBarTouchEvent",
                new StatusBarTouchHook());
        // 4) Safety net for the sleep action itself.
        hookMethod(cl, "com.android.quickstep.SystemUiProxy", "lockDevice", new LockDeviceHook());
        // 5) C-lite gets no remote transition for the home task (the stock launcher has no
        //    SystemUiProxy, so nothing registers one): the platform plays its own OPEN transition
        //    there, the closing app window slides off the bottom and the home lands with a hard
        //    cut (measured: one frame, 59.5 mean frame difference). Animate the launcher's own
        //    decor view instead - it is the only surface we can reach from this process.
        for (String cls : LAUNCHER_ACTIVITY_CLASSES) {
            hookMethod(cl, cls, "onResume", new HomeArriveHook());
        }
        XposedBridge.log("AxionDesktopBridge clite gestures installed in launcher hooks=" + sHookCount
                + " boot=" + readBootId());
    }

    private static void hookClass(ClassLoader cl, String className, String[] methodNames) {
        Class<?> clazz;
        try {
            clazz = XposedHelpers.findClass(className, cl);
        } catch (Throwable t) {
            Log.i(TAG, "class not present: " + className);
            return;
        }
        if (clazz == null) {
            Log.i(TAG, "class not present: " + className);
            return;
        }
        for (String name : methodNames) {
            try {
                Set<?> unhooks = XposedBridge.hookAllMethods(clazz, name, new PermissionHook(className + "." + name));
                int n = unhooks == null ? 0 : unhooks.size();
                sHookCount += n;
                Log.i(TAG, "hook " + className + "." + name + " -> " + n);
            } catch (Throwable t) {
                Log.i(TAG, "hook failed " + className + "." + name + ": " + t);
            }
        }
    }

    private static void hookMethod(ClassLoader cl, String className, String methodName,
            XC_MethodHook callback) {
        Class<?> clazz;
        try {
            clazz = XposedHelpers.findClass(className, cl);
        } catch (Throwable t) {
            Log.i(TAG, "class not present: " + className);
            return;
        }
        if (clazz == null) {
            Log.i(TAG, "class not present: " + className);
            return;
        }
        try {
            Set<?> unhooks = XposedBridge.hookAllMethods(clazz, methodName, callback);
            int n = unhooks == null ? 0 : unhooks.size();
            sHookCount += n;
            Log.i(TAG, "hook " + className + "." + methodName + " -> " + n);
        } catch (Throwable t) {
            Log.i(TAG, "hook failed " + className + "." + methodName + ": " + t);
        }
    }

    /**
     * Grant-at-scan hook for
     * {@code PermissionManagerServiceImpl.shouldGrantPermissionByProtectionFlags(AndroidPackage,
     * PackageState..., Permission, ArraySet<String>)}. The parameter positions are resolved from the
     * hooked method's declared parameter types (not from argument order) so the hook keeps working
     * if the signature shifts.
     */
    private static final class GrantByFlagsHook extends XC_MethodHook {

        @Override
        protected void beforeHookedMethod(MethodHookParam param) throws Throwable {
            try {
                Object[] args = param.args;
                if (args == null || !(param.method instanceof Method)) {
                    return;
                }
                Class<?>[] types = ((Method) param.method).getParameterTypes();
                if (types.length < 2 || types.length > args.length) {
                    return;
                }
                Object pkgObj = null;
                Object permObj = null;
                for (int i = 0; i < types.length; i++) {
                    String tn = types[i].getName();
                    if (pkgObj == null && tn.endsWith("AndroidPackage")) {
                        pkgObj = args[i];
                    } else if (permObj == null && tn.endsWith("Permission")) {
                        permObj = args[i];
                    }
                }
                if (pkgObj == null || permObj == null) {
                    return;
                }
                Object pkgName = XposedHelpers.callMethod(pkgObj, "getPackageName");
                if (!TARGET_PKG.equals(pkgName)) {
                    return;
                }
                Object permName = XposedHelpers.callMethod(permObj, "getName");
                boolean recents = false;
                try {
                    Object flag = XposedHelpers.callMethod(permObj, "isRecents");
                    recents = flag instanceof Boolean && (Boolean) flag;
                } catch (Throwable ignored) {
                    // older release without Permission.isRecents()
                }
                if (!recents && !isRecentsPermission(permName instanceof String ? (String) permName : null)) {
                    return;
                }
                param.setResult(Boolean.TRUE);
                logOnce("grant-at-scan " + permName + " -> " + pkgName);
            } catch (Throwable t) {
                // never break package scanning
            }
        }
    }

    /**
     * Shared adapter for every permission funnel: args[0] (first String) is the permission, the
     * uid is whichever int argument equals our target app id (falls back to the binder caller).
     */
    private static final class PermissionHook extends XC_MethodHook {

        private final String where;

        PermissionHook(String where) {
            this.where = where;
        }

        @Override
        protected void beforeHookedMethod(MethodHookParam param) throws Throwable {
            try {
                final Object[] args = param.args;
                if (args == null || args.length == 0) {
                    return;
                }
                final int appId = resolveAppId();
                String perm = null;
                int uid = -1;
                for (Object arg : args) {
                    if (arg instanceof String) {
                        if (perm == null) {
                            perm = (String) arg;
                        }
                    } else if (arg instanceof Integer) {
                        int v = (Integer) arg;
                        if (v > 0 && appId > 0 && v % PER_USER_RANGE == appId) {
                            uid = v;
                        }
                    }
                }
                if (perm == null) {
                    return;
                }
                if (uid < 0) {
                    uid = Binder.getCallingUid();
                }
                if (!shouldGrant(perm, uid)) {
                    return;
                }
                Member m = param.method;
                boolean isVoid = (m instanceof Method) && ((Method) m).getReturnType() == Void.TYPE;
                param.setResult(isVoid ? null : Integer.valueOf(PERMISSION_GRANTED));
                logOnce("granted " + perm + " to uid " + uid + " via " + where);
            } catch (Throwable t) {
                // never break the caller
            }
        }
    }

    private static boolean shouldGrant(String perm, int uid) {
        if (perm == null || uid <= 0) {
            return false;
        }
        int appId = resolveAppId();
        if (appId <= 0 || uid % PER_USER_RANGE != appId) {
            return false;
        }
        return isRecentsPermission(perm);
    }

    private static boolean isRecentsPermission(String perm) {
        Boolean cached = PERM_CACHE.get(perm);
        if (cached != null) {
            return cached;
        }
        boolean result = FALLBACK_RECENTS_PERMS.contains(perm);
        if (sSystemServer) {
            // Never call back into the package manager from inside a permission funnel while
            // system_server is the caller: PackageManagerService takes its own locks, and a
            // re-entrant query from these hooks can deadlock. The explicit list covers every
            // recents-flagged permission that ships with Android 16.
            return result;
        }
        int flag = recentsFlag();
        if (flag > 0) {
            try {
                PermissionInfo info = systemContext().getPackageManager().getPermissionInfo(perm, 0);
                if (info != null && (info.protectionLevel & flag) != 0) {
                    result = true;
                }
            } catch (Throwable t) {
                // unknown permission -> keep the fallback answer
            }
            PERM_CACHE.put(perm, Boolean.valueOf(result));
        }
        return result;
    }

    private static int recentsFlag() {
        if (sRecentsFlag == Integer.MIN_VALUE) {
            int value = -1;
            try {
                value = XposedHelpers.getStaticIntField(PermissionInfo.class, "PROTECTION_FLAG_RECENTS");
            } catch (Throwable t) {
                Log.i(TAG, "PROTECTION_FLAG_RECENTS unavailable: " + t);
            }
            sRecentsFlag = value;
        }
        return sRecentsFlag;
    }

    private static int resolveAppId() {
        if (sTargetAppId > 0) {
            return sTargetAppId;
        }
        try {
            Context ctx = systemContext();
            PackageInfo info = ctx.getPackageManager().getPackageInfo(TARGET_PKG, 0);
            if (info != null && info.applicationInfo != null) {
                sTargetAppId = info.applicationInfo.uid % PER_USER_RANGE;
                Log.i(TAG, TARGET_PKG + " appId=" + sTargetAppId);
            }
        } catch (Throwable t) {
            Log.i(TAG, "resolveAppId failed: " + t);
        }
        return sTargetAppId;
    }

    private static Context systemContext() {
        Context ctx = sSystemContext;
        if (ctx != null) {
            return ctx;
        }
        synchronized (Main.class) {
            if (sSystemContext == null) {
                Object activityThread = XposedHelpers.callStaticMethod(
                        XposedHelpers.findClass("android.app.ActivityThread", null), "currentActivityThread");
                sSystemContext = (Context) XposedHelpers.callMethod(activityThread, "getSystemContext");
            }
            return sSystemContext;
        }
    }

    private static void logOnce(String message) {
        if (LOGGED.add(message)) {
            Log.i(TAG, message);
        }
    }

    /**
     * Kernel boot id ({@code /proc/sys/kernel/random/boot_id}), used as the boot-scope token of the
     * {@code XposedBridge.log()} handshake with the KernelSU module scripts. Returns {@code "?"} when
     * the file cannot be read; the scripts compare the value with their own read of the same file and
     * simply stay in the default mode on a mismatch, so a missing value is safe.
     */
    private static String readBootId() {
        BufferedReader reader = null;
        try {
            reader = new BufferedReader(new FileReader("/proc/sys/kernel/random/boot_id"));
            String line = reader.readLine();
            return line == null ? "?" : line.trim();
        } catch (Throwable t) {
            return "?";
        } finally {
            if (reader != null) {
                try {
                    reader.close();
                } catch (Throwable ignored) {
                    // nothing to do
                }
            }
        }
    }

    // ---------------------------------------------------------------------------------------
    // C-lite gestures (double tap to sleep, swipe down to the shade/control centre)
    // ---------------------------------------------------------------------------------------

    /**
     * True when this launcher owns the recents role and therefore has a live SystemUI proxy. When
     * the field cannot be read we answer {@code true} so the stock path is left completely alone.
     */
    private static boolean hasSystemUiProxy(Object systemUiProxyInstance) {
        try {
            return XposedHelpers.getObjectField(systemUiProxyInstance, "mSystemUiProxy") != null;
        } catch (Throwable t) {
            return true;
        }
    }

    /** Reads a Moto framework setting ({@code com.motorola.android.provider.MotorolaSettings.Global}). */
    private static String readMotoGlobal(String key) {
        try {
            Class<?> clazz = XposedHelpers.findClass(
                    "com.motorola.android.provider.MotorolaSettings$Global", sTargetClassLoader);
            Object value = XposedHelpers.callStaticMethod(clazz, "getString",
                    systemContext().getContentResolver(), key);
            return value instanceof String ? (String) value : null;
        } catch (Throwable t) {
            Log.i(TAG, "readMotoGlobal(" + key + ") failed: " + t);
            return null;
        }
    }

    /** Moto-space id used by the stock gesture gate; non-empty means the stock gesture is off. */
    private static String motoSpaceId() {
        try {
            Class<?> clazz = XposedHelpers.findClass(
                    "com.android.launcher3.settings.MotoSpaceHelper", sTargetClassLoader);
            Object value = XposedHelpers.getStaticObjectField(clazz, "sMotoSpaceId");
            return value == null ? null : String.valueOf(value);
        } catch (Throwable t) {
            return null;
        }
    }

    /**
     * Expands the notification shade (or the control centre) without the SystemUI proxy.
     * {@code StatusBarManager} is not guaranteed to be a named system service, and the launcher dex
     * has no reference to it at all, so everything here is reflective and falls back to the internal
     * {@code IStatusBarService} binder.
     */
    private static boolean expandStatusBarPanel(boolean settingsPanel) {
        try {
            Object manager = systemContext().getSystemService("statusbar");
            if (manager != null) {
                if (settingsPanel) {
                    XposedHelpers.callMethod(manager, "expandSettingsPanel", new Object[] {null});
                } else {
                    XposedHelpers.callMethod(manager, "expandNotificationsPanel");
                }
                logOnce("swipe down -> StatusBarManager."
                        + (settingsPanel ? "expandSettingsPanel" : "expandNotificationsPanel"));
                return true;
            }
        } catch (Throwable t) {
            Log.i(TAG, "StatusBarManager path failed: " + t);
        }
        try {
            Object binder = XposedHelpers.callStaticMethod(
                    XposedHelpers.findClass("android.os.ServiceManager", null), "getService", "statusbar");
            if (binder == null) {
                logOnce("swipe down: statusbar binder unavailable");
                return false;
            }
            Class<?> stub = XposedHelpers.findClass(
                    "com.android.internal.statusbar.IStatusBarService$Stub", sTargetClassLoader);
            Object service = XposedHelpers.callStaticMethod(stub, "asInterface", binder);
            if (service == null) {
                return false;
            }
            if (settingsPanel) {
                XposedHelpers.callMethod(service, "expandSettingsPanel", new Object[] {null});
            } else {
                XposedHelpers.callMethod(service, "expandNotificationsPanel");
            }
            logOnce("swipe down -> IStatusBarService."
                    + (settingsPanel ? "expandSettingsPanel" : "expandNotificationsPanel"));
            return true;
        } catch (Throwable t) {
            Log.i(TAG, "expand panel failed: " + t);
            return false;
        }
    }

    /**
     * Double tap on an empty workspace area -> screen off.
     *
     * <p>Stock {@code Utilities.isSleepScreenEnabled()} is
     * {@code "1".equalsIgnoreCase(MotorolaSettings.Global.getString(cr, "put_display_to_sleep")) &&
     * !MotoSpaceHelper.isMotoSpaceEnabled()}. Unset means "off" for stock, but unset is exactly what
     * this ROM ships and what the user expects to mean the default. We only open the gate for the
     * unset case: an explicit value ("1"/"0") is still honoured, so Moto's own setting keeps
     * working.
     */
    private static final class SleepScreenGateHook extends XC_MethodHook {

        @Override
        protected void afterHookedMethod(MethodHookParam param) throws Throwable {
            try {
                if (Boolean.TRUE.equals(param.getResult())) {
                    return;
                }
                final String raw = readMotoGlobal("put_display_to_sleep");
                final String spaceId = motoSpaceId();
                if (raw != null) {
                    logOnce("sleep gate kept (put_display_to_sleep=" + raw + " motoSpaceId=" + spaceId + ")");
                    return;
                }
                param.setResult(Boolean.TRUE);
                logOnce("sleep gate opened (put_display_to_sleep unset, motoSpaceId=" + spaceId + ")");
            } catch (Throwable t) {
                Log.i(TAG, "sleep gate failed: " + t);
            }
        }
    }

    /** Lets the swipe-down gesture pass {@code StatusBarTouchController.canInterceptTouch()}. */
    private static final class SystemUiActiveHook extends XC_MethodHook {

        @Override
        protected void beforeHookedMethod(MethodHookParam param) throws Throwable {
            try {
                if (Boolean.TRUE.equals(param.getResult()) || hasSystemUiProxy(param.thisObject)) {
                    return;
                }
                param.setResult(Boolean.TRUE);
                logOnce("SystemUiProxy.isActive -> true (no SystemUI binding in C-lite)");
            } catch (Throwable t) {
                Log.i(TAG, "isActive hook failed: " + t);
            }
        }
    }

    /**
     * Sleeps the device when {@code lockDevice(true)} would have asked SystemUI to do it. Only acts
     * when the proxy is missing, so a launcher that owns the recents role is untouched.
     */
    private static final class LockDeviceHook extends XC_MethodHook {

        @Override
        protected void beforeHookedMethod(MethodHookParam param) throws Throwable {
            try {
                if (hasSystemUiProxy(param.thisObject)) {
                    return;
                }
                Object power = systemContext().getSystemService(Context.POWER_SERVICE);
                if (power == null) {
                    logOnce("lockDevice: PowerManager unavailable");
                    return;
                }
                XposedHelpers.callMethod(power, "goToSleep", SystemClock.uptimeMillis());
                param.setResult(null);
                logOnce("lockDevice -> PowerManager.goToSleep()");
            } catch (Throwable t) {
                Log.i(TAG, "lockDevice fallback failed: " + t);
            }
        }
    }

    /**
     * Replaces the touch stream that {@code StatusBarTouchController} would have forwarded to
     * SystemUI: the panel is expanded on ACTION_UP instead of being dragged. A long drag opens the
     * control centre (quick settings), anything shorter opens the plain notification shade.
     */
    private static final class StatusBarTouchHook extends XC_MethodHook {

        private static final float CONTROL_CENTRE_TRAVEL_PX = 240f;

        /** ACTION_DOWN y of the forwarded stream, -1 when no drag is in flight. */
        private float mDownY = -1f;

        @Override
        protected void beforeHookedMethod(MethodHookParam param) throws Throwable {
            try {
                if (hasSystemUiProxy(param.thisObject)) {
                    return;
                }
                Object event = (param.args != null && param.args.length > 0) ? param.args[0] : null;
                if (event == null) {
                    return;
                }
                final int action =
                        ((Integer) XposedHelpers.callMethod(event, "getActionMasked")).intValue();
                if (action == MotionEvent.ACTION_DOWN) {
                    mDownY = ((Float) XposedHelpers.callMethod(event, "getY")).floatValue();
                    return;
                }
                if (action != MotionEvent.ACTION_UP && action != MotionEvent.ACTION_CANCEL) {
                    return;
                }
                final float downY = mDownY;
                mDownY = -1f;
                if (action == MotionEvent.ACTION_CANCEL) {
                    param.setResult(null);
                    return;
                }
                final float travel = downY < 0f
                        ? 0f
                        : ((Float) XposedHelpers.callMethod(event, "getY")).floatValue() - downY;
                final boolean controlCentre = travel > CONTROL_CENTRE_TRAVEL_PX;
                Log.i(TAG, "swipe down: downY=" + downY + " travel=" + travel
                        + "px -> " + (controlCentre ? "control centre" : "notifications"));
                if (expandStatusBarPanel(controlCentre)) {
                    param.setResult(null);
                }
            } catch (Throwable t) {
                Log.i(TAG, "status bar touch hook failed: " + t);
            }
        }
    }

    /**
     * "Desktop drops in from the top" animation for C-lite's app -> home transition.
     *
     * <p>Why the stock launcher needs help: C-lite points {@code config_recentsComponentName} at
     * Axion, so SystemUI never binds the stock launcher's {@code TouchInteractionService} and
     * {@code mSystemUiProxy} stays null there. Without the proxy
     * {@code registerRemoteTransition()} is a no-op, so the platform cannot be handed a
     * launcher-driven transition for the home task and plays its own OPEN transition: the closing
     * app window slides down off the screen while the home appears at its final position (measured
     * on device as a single 59.5 mean-frame-difference cut). That window belongs to the Shell, but
     * the launcher's own decor view is ours - so the desktop is pushed up, shrunk and faded at
     * {@code onResume} and animated into place while the app is still leaving.
     *
     * <p>Knobs live in {@code Settings.Global} (defaults in brackets) and can be changed on a
     * running device with {@code settings put global <key> <value>}; {@code 0} for
     * {@code axion_home_arrive_enabled} turns the animation off:
     * <ul>
     *   <li>{@code axion_home_arrive_enabled} [1]</li>
     *   <li>{@code axion_home_arrive_scale} [1.35] - start scale, 1.0 = no scaling. It is raised to
     *       {@code 1 + 2 * |translation|} when needed: the launcher window carries the wallpaper, so
     *       a start scale that does not cover the shifted content would show the window background
     *       (a black band) along the opposite edge.</li>
     *   <li>{@code axion_home_arrive_translation} [-0.16] - start offset as a fraction of the
     *       window height, negative = above its final position</li>
     *   <li>{@code axion_home_arrive_alpha} [1.0] - start alpha</li>
     *   <li>{@code axion_home_arrive_duration} [220] - milliseconds; keep it at or below the
     *       platform's own home transition (~250 ms) so the transform is already back to identity
     *       when the transition finishes and the live window replaces the shell leash</li>
     * </ul>
     */
    private static final class HomeArriveHook extends XC_MethodHook {

        private static final String ENABLED = "axion_home_arrive_enabled";
        private static final String SCALE = "axion_home_arrive_scale";
        private static final String TRANSLATION = "axion_home_arrive_translation";
        private static final String ALPHA = "axion_home_arrive_alpha";
        private static final String DURATION = "axion_home_arrive_duration";

        /** onResume also fires for configuration changes and quick home/app toggles. */
        private static final long DEBOUNCE_MS = 350;

        @Override
        protected void afterHookedMethod(MethodHookParam param) throws Throwable {
            try {
                if (!(param.thisObject instanceof Activity)) {
                    return;
                }
                final Activity activity = (Activity) param.thisObject;
                final View root = activity.getWindow() == null
                        ? null : activity.getWindow().getDecorView();
                if (root == null || root.getWidth() <= 0 || root.getHeight() <= 0) {
                    return;
                }
                final long now = SystemClock.uptimeMillis();
                if (now - sLastArriveUptime < DEBOUNCE_MS) {
                    return;
                }
                final Context cr = activity.getApplicationContext();
                if (Settings.Global.getInt(cr.getContentResolver(), ENABLED, 1) == 0) {
                    return;
                }
                final float requestedScale = clamp(Settings.Global.getFloat(
                        cr.getContentResolver(), SCALE, 1.35f), 0.2f, 3f);
                final float translation = clamp(Settings.Global.getFloat(
                        cr.getContentResolver(), TRANSLATION, -0.16f), -1.5f, 1.5f);
                final float alpha = clamp(Settings.Global.getFloat(
                        cr.getContentResolver(), ALPHA, 1f), 0f, 1f);
                final int duration = (int) clamp(Settings.Global.getFloat(
                        cr.getContentResolver(), DURATION, 220f), 60f, 1500f);
                // The launcher window carries the wallpaper, so any part of it that the shifted
                // content does not cover shows the window background (black). Translating up by T
                // uncovers T of the height at the bottom edge, scaling by S covers (S - 1) / 2 at
                // each edge, so require S >= 1 + 2T.
                final float minScale = 1f + Math.max(0f, -translation) * 2f;
                final float scale = Math.max(requestedScale, minScale);
                if (scale > requestedScale + 0.001f) {
                    Log.i(TAG, "home arrive: start scale raised " + requestedScale + " -> " + scale
                            + " so the shifted window stays covered");
                }
                sLastArriveUptime = now;
                final float startY = root.getHeight() * translation;
                root.animate().cancel();
                root.setPivotX(root.getWidth() / 2f);
                root.setPivotY(root.getHeight() / 2f);
                root.setScaleX(scale);
                root.setScaleY(scale);
                root.setTranslationY(startY);
                root.setAlpha(alpha);
                root.animate()
                        .scaleX(1f)
                        .scaleY(1f)
                        .translationY(0f)
                        .alpha(1f)
                        .setDuration(duration)
                        .setInterpolator(new PathInterpolator(0.16f, 0f, 0.24f, 1f))
                        .start();
                Log.i(TAG, "home arrive: " + activity.getClass().getName()
                        + " scale " + scale + "->1 translationY " + startY + "->0 alpha "
                        + alpha + "->1 in " + duration + "ms");
            } catch (Throwable t) {
                Log.i(TAG, "home arrive failed: " + t);
            }
        }
    }

    private static float clamp(float value, float min, float max) {
        return value < min ? min : (value > max ? max : value);
    }

    /**
     * Fallback for {@code android.app.ContextImpl#getDisplay()}.
     *
     * <p>Android 12+ throws {@link UnsupportedOperationException} when a context that is not
     * associated with a display asks for it ("Tried to obtain display from a Context not associated
     * with one"). Moto's launcher pre-inflates its task-view pool with the application context, and
     * the inflation path reaches {@code QuickStepContract.getWindowCornerRadius()} →
     * {@code Context.getDisplay()}: the exception kills the pool's init thread, the launcher process
     * dies and the device ends up in a crash loop (observed as
     * {@code FATAL EXCEPTION: ViewPool-init ... Error inflating class
     * com.android.quickstep.views.TaskThumbnailView}). The display is only used there to compute a
     * corner radius, so returning the default display restores the pre-Android 12 behaviour.
     */
    private static final class DisplayFallbackHook extends XC_MethodHook {

        @Override
        protected void afterHookedMethod(MethodHookParam param) throws Throwable {
            if (!param.hasThrowable()) {
                return;
            }
            Throwable t = param.getThrowable();
            if (!(t instanceof UnsupportedOperationException)) {
                return;
            }
            Object self = param.thisObject;
            if (!(self instanceof Context)) {
                return;
            }
            try {
                DisplayManager dm = (DisplayManager)
                        ((Context) self).getSystemService(Context.DISPLAY_SERVICE);
                Display display = dm == null ? null : dm.getDisplay(Display.DEFAULT_DISPLAY);
                if (display != null) {
                    param.setThrowable(null);
                    param.setResult(display);
                    logOnce("display fallback in " + self.getClass().getName());
                }
            } catch (Throwable t2) {
                Log.i(TAG, "display fallback failed: " + t2);
            }
        }
    }
}
