package de.robv.android.xposed.callbacks;

import android.content.pm.ApplicationInfo;

/**
 * Compile-only stub of the LSPosed/Xposed callback parameter (never packaged: only com/axion/**
 * classes are fed to d8). Only the public fields we read are declared - the runtime class
 * provided by LSPosed has the same binary name and the same public fields.
 */
public class XC_LoadPackage {

    public static class LoadPackageParam {
        public String packageName;
        public String processName;
        public ClassLoader classLoader;
        public ApplicationInfo appInfo;
        public boolean isFirstApplication;
    }
}
