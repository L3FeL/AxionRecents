package com.axion.recents;

import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;

/**
 * Repairs the APK path LSPosed has cached for a module.
 *
 * <p>LSPosed remembers the /data/app path it first loaded a module from in
 * {@code /data/adb/lspd/config/modules_config.db}. Every {@code pm install -r} gives the APK a brand
 * new {@code /data/app/~~<random>/...} path, so the cached one goes stale and LSPosed then silently
 * skips the module - C-lite stops working without a single error message anywhere.
 *
 * <p>The device has no sqlite3 binary, so this runs as a normal Java entry point through
 * {@code app_process} (see service.sh) and talks to the database through the framework's own
 * SQLiteDatabase, which is WAL aware and takes the same locks the LSPosed daemon takes.
 *
 * <p>Usage: {@code CLASSPATH=lspd-fix.jar app_process /system/bin com.axion.recents.LspdPathFix
 * <db> <module-pkg> <actual-apk-path>} to repair, or {@code ... LspdPathFix -get <db>
 * <module-pkg>} to print the cached path (the module scripts use that instead of grepping the file,
 * which also sees path copies left behind in freed pages).
 *
 * <p>Exit codes: 0 ok, 1 error, 2 bad usage, 3 no row for that module.
 */
public final class LspdPathFix {

    private static final int LOCK_RETRIES = 10;
    private static final long LOCK_RETRY_DELAY_MS = 200;

    private LspdPathFix() {
    }

    public static void main(String[] args) {
        if (args.length >= 3 && "-get".equals(args[0])) {
            if (args.length < 3) {
                System.err.println("usage: LspdPathFix -get <modules_config.db> <module-pkg>");
                System.exit(2);
            }
            printCached(args[1], args[2]);
            return;
        }
        if (args.length < 3) {
            System.err.println("usage: LspdPathFix <modules_config.db> <module-pkg> <apk-path>");
            System.err.println("       LspdPathFix -get <modules_config.db> <module-pkg>");
            System.exit(2);
        }
        final String dbPath = args[0];
        final String modulePkg = args[1];
        final String actual = args[2];

        SQLiteDatabase db = null;
        try {
            db = openWithRetries(dbPath);
            final String cached = query(db, modulePkg);
            if (cached == null) {
                System.err.println("no row for " + modulePkg + " in " + dbPath);
                System.exit(3);
            }
            if (actual.equals(cached)) {
                System.out.println("ok: " + modulePkg + " already points at " + actual);
                return;
            }
            db.execSQL("update modules set apk_path=? where module_pkg_name=?",
                    new Object[]{actual, modulePkg});
            final String now = query(db, modulePkg);
            if (!actual.equals(now)) {
                System.err.println("update did not stick: " + now);
                System.exit(1);
            }
            System.out.println("fixed: " + modulePkg + " " + cached + " -> " + now);
        } catch (Throwable t) {
            System.err.println("failed: " + t);
            t.printStackTrace();
            System.exit(1);
        } finally {
            closeQuietly(db);
        }
    }

    /** Prints the apk_path lspd has on record, or {@code none} when the module has no row. */
    private static void printCached(String dbPath, String modulePkg) {
        SQLiteDatabase db = null;
        try {
            db = openWithRetries(dbPath);
            final String cached = query(db, modulePkg);
            System.out.println(cached != null ? cached : "none");
        } catch (Throwable t) {
            System.err.println("failed: " + t);
            System.exit(1);
        } finally {
            closeQuietly(db);
        }
    }

    private static void closeQuietly(SQLiteDatabase db) {
        if (db == null) {
            return;
        }
        try {
            db.close();
        } catch (Throwable ignored) {
            // nothing useful to do while exiting
        }
    }

    private static SQLiteDatabase openWithRetries(String dbPath) {
        RuntimeException last = null;
        for (int i = 0; i < LOCK_RETRIES; i++) {
            try {
                return SQLiteDatabase.openDatabase(dbPath, null, SQLiteDatabase.OPEN_READWRITE);
            } catch (RuntimeException e) {
                // SQLiteException / SQLiteCantOpenDatabaseException / SQLiteDatabaseLockedException
                last = e;
                sleep(LOCK_RETRY_DELAY_MS);
            }
        }
        throw last;
    }

    private static String query(SQLiteDatabase db, String modulePkg) {
        Cursor c = null;
        try {
            c = db.rawQuery("select apk_path from modules where module_pkg_name=?",
                    new String[]{modulePkg});
            return c.moveToFirst() ? c.getString(0) : null;
        } finally {
            if (c != null) {
                c.close();
            }
        }
    }

    private static void sleep(long ms) {
        try {
            Thread.sleep(ms);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
}
