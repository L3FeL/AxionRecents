package de.robv.android.xposed;

/** Compile-only stub of the LSPosed/Xposed reflection helpers (never packaged). */
public final class XposedHelpers {

    private XposedHelpers() {
    }

    public static Class<?> findClass(String className, ClassLoader classLoader) {
        return null;
    }

    public static Object callStaticMethod(Class<?> clazz, String methodName, Object... args) {
        return null;
    }

    public static Object callMethod(Object obj, String methodName, Object... args) {
        return null;
    }

    public static Object getStaticObjectField(Class<?> clazz, String fieldName) {
        return null;
    }

    public static int getStaticIntField(Class<?> clazz, String fieldName) {
        return 0;
    }

    public static Object getObjectField(Object obj, String fieldName) {
        return null;
    }

    public static Object newInstance(Class<?> clazz, Object... args) {
        return null;
    }
}
