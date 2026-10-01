package com.axion.motodesktop;

import android.content.Context;
import android.content.pm.PackageInfo;
import android.content.pm.PermissionInfo;
import android.hardware.display.DisplayManager;
import android.os.Binder;
import android.util.Log;
import android.view.Display;

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
 */
public class Main implements IXposedHookLoadPackage {

    private static final String TAG = "AXMOTO";
    private static final String TARGET_PKG = "com.motorola.launcher3";
    private static final String SYSTEM_PKG = "android";
    private static final int PER_USER_RANGE = 100000;
    private static final int PERMISSION_GRANTED = 0;

    /** Used when PermissionInfo.PROTECTION_FLAG_RECENTS cannot be reflected (older releases). */
    private static final Set<String> FALLBACK_RECENTS_PERMS = new HashSet<String>(Arrays.asList(
            "android.permission.MANAGE_ACTIVITY_TASKS",
            "android.permission.REMOVE_TASKS",
            "android.permission.ROTATE_SURFACE_FLINGER",
            "android.permission.WAKEUP_SURFACE_FLINGER",
            "android.permission.STOP_APP_SWITCHES",
            "android.permission.SET_ORIENTATION",
            "android.permission.CONTROL_REMOTE_APP_TRANSITION_ANIMATIONS",
            "android.permission.START_TASKS_FROM_RECENTS"));

    private static final String[] CONTEXT_METHODS = new String[] {
            "checkPermission",
            "checkCallingPermission",
            "checkCallingOrSelfPermission",
            "enforcePermission",
            "enforceCallingPermission",
            "enforceCallingOrSelfPermission"};

    private static final Map<String, Boolean> PERM_CACHE = new ConcurrentHashMap<String, Boolean>();
    private static final Set<String> LOGGED =
            Collections.newSetFromMap(new ConcurrentHashMap<String, Boolean>());

    private static volatile Context sSystemContext;
    private static volatile int sTargetAppId = -1;
    private static volatile int sRecentsFlag = Integer.MIN_VALUE;
    private static volatile int sHookCount;
    private static volatile boolean sSystemServer;

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
            // Target app process only: Moto's launcher builds its task view pool on a background
            // thread with a non-visual context, and Android 12+ makes Context.getDisplay() throw
            // for those. See DisplayFallbackHook.
            hookMethod(cl, "android.app.ContextImpl", "getDisplay", new DisplayFallbackHook());
        }
        Log.i(TAG, "hooks installed: " + sHookCount);
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
