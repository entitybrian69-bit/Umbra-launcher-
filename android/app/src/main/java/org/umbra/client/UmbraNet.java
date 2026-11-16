// Umbra's only Java: the two things the NDK cannot do, and nothing else.
//
// The app is a NativeActivity with no Java of its own, and it stays that way for
// everything the game does. Two jobs are not reachable from the NDK at all:
//
//   1. HTTPS. The client jar comes from Mojang over TLS, and the NDK ships no TLS
//      client. java.net.HttpURLConnection is on every Android device already.
//   2. A document picker. ACTION_OPEN_DOCUMENT answers through
//      onActivityResult(), and android.app.NativeActivity does not implement that
//      callback, so a picker started from native code can never learn what the user
//      chose. This class does.
//
// Neither method decides anything: download() streams bytes to a path the caller
// names and reports how many, and pick() returns the Uri the user chose. Whether
// those bytes are the right bytes is decided in Goose (core/gamefiles.goose,
// core/sha1.goose), where the test suite can reach it.
package org.umbra.client;

import android.app.Activity;
import android.app.NativeActivity;
import android.content.ContentResolver;
import android.content.Intent;
import android.net.Uri;
import android.util.Log;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;

public class UmbraNet {
    private static final String TAG = "umbra";

    // Progress of the download in flight, read by the native frame loop to draw the
    // bar. Volatile because the reader is on another thread; a torn read of a
    // progress counter would be cosmetic and this is not.
    private static volatile long sGot = 0;
    private static volatile long sTotal = 0;
    private static volatile String sError = "";
    private static volatile boolean sRunning = false;

    public static long progressGot() { return sGot; }
    public static long progressTotal() { return sTotal; }
    public static String lastError() { return sError; }
    public static boolean running() { return sRunning; }

    /**
     * Stream url into dest, replacing it. Returns the number of bytes written, or
     * -1 with lastError() set. The caller verifies the bytes; this only moves them.
     */
    public static long download(String url, String dest) {
        sGot = 0;
        sTotal = 0;
        sError = "";
        sRunning = true;
        HttpURLConnection conn = null;
        FileOutputStream out = null;
        // dest is already the caller's temporary name (client.jar.part, from
        // core/gamefiles.goose), so it is written as given. This used to write
        // dest + ".part", which produced client.jar.part.part: the 41 MB the device
        // did download sat under a name nothing looked at, and the run refused it
        // with "the downloaded file could not be read back" (43958738406).
        File tmp = new File(dest);
        try {
            URL u = new URL(url);
            conn = (HttpURLConnection) u.openConnection();
            conn.setConnectTimeout(20000);
            conn.setReadTimeout(30000);
            conn.setInstanceFollowRedirects(true);
            conn.setRequestProperty("User-Agent", "Umbra/launcher");
            int code = conn.getResponseCode();
            if (code != 200) {
                sError = "the server answered " + code + " for " + url;
                return -1;
            }
            sTotal = conn.getContentLength();
            InputStream in = conn.getInputStream();
            out = new FileOutputStream(tmp, false);
            byte[] buf = new byte[65536];
            long got = 0;
            int n;
            while ((n = in.read(buf)) > 0) {
                out.write(buf, 0, n);
                got += n;
                sGot = got;
                if (Thread.currentThread().isInterrupted()) {
                    sError = "the download was cancelled";
                    return -1;
                }
            }
            out.flush();
            out.close();
            out = null;
            in.close();
            if (sTotal > 0 && got != sTotal) {
                sError = "the connection ended after " + got + " of " + sTotal + " bytes";
                return -1;
            }
            // The .part file is renamed only after the caller has verified it, so a
            // half transfer can never be mistaken for a jar. Here that means the
            // download looks like a complete one: close it and hand it back.
            return got;
        } catch (Exception e) {
            String m = e.getMessage();
            sError = (m == null || m.isEmpty()) ? e.getClass().getSimpleName() : m;
            return -1;
        } finally {
            sRunning = false;
            if (out != null) {
                try { out.close(); } catch (Exception ignored) { }
            }
            if (conn != null) conn.disconnect();
        }
    }

    // --- the document picker ---------------------------------------------
    //
    // A pick started here blocks on this class's monitor until the activity
    // delivers the result, which is why the native caller runs it on its own
    // thread. The picked Uri is turned into a file by copyUriTo, on the same
    // thread, before the activity can take the grant away.
    private static final Object LOCK = new Object();
    private static Uri sPicked = null;
    private static boolean sPicking = false;
    private static int sRequest = 0x554D42;   // "UMB"

    public static void pick(Activity activity, String[] mimeTypes) {
        synchronized (LOCK) {
            sPicked = null;
            sPicking = true;
        }
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT);
        intent.addCategory(Intent.CATEGORY_OPENABLE);
        if (mimeTypes != null && mimeTypes.length == 1) {
            intent.setType(mimeTypes[0]);
        } else {
            intent.setType("*/*");
            if (mimeTypes != null && mimeTypes.length > 1) {
                intent.putExtra(Intent.EXTRA_MIME_TYPES, mimeTypes);
            }
        }
        try {
            activity.startActivityForResult(intent, sRequest);
        } catch (Exception e) {
            synchronized (LOCK) {
                sPicking = false;
                sPicked = null;
                sError = "no document picker on this device: " + e.getMessage();
                LOCK.notifyAll();
            }
        }
    }

    /** Called by UmbraActivity when the picker answers. */
    public static void delivered(int requestCode, int resultCode, Intent data) {
        if (requestCode != sRequest) return;
        synchronized (LOCK) {
            sPicked = (resultCode == Activity.RESULT_OK && data != null) ? data.getData() : null;
            sPicking = false;
            LOCK.notifyAll();
        }
    }

    /**
     * Waits for the picker and copies what was picked into dest. Returns the number
     * of bytes written, -1 if nothing was picked, or a negative code with
     * lastError() set.
     */
    public static long pickAndCopy(Activity activity, String dest, String[] mimeTypes) {
        pick(activity, mimeTypes);
        Uri uri;
        synchronized (LOCK) {
            long deadline = System.currentTimeMillis() + 300000;
            while (sPicking) {
                long left = deadline - System.currentTimeMillis();
                if (left <= 0) break;
                try { LOCK.wait(left); } catch (InterruptedException e) { break; }
            }
            uri = sPicked;
            sPicked = null;
            sPicking = false;
        }
        if (uri == null) return -1;
        return copyUriTo(activity, uri.toString(), dest);
    }

    /** Stream a content:// or file:// Uri into dest. */
    public static long copyUriTo(Activity activity, String uriString, String dest) {
        InputStream in = null;
        OutputStream out = null;
        // dest is already the caller's temporary name (client.jar.part, from
        // core/gamefiles.goose), so it is written as given. This used to write
        // dest + ".part", which produced client.jar.part.part: the 41 MB the device
        // did download sat under a name nothing looked at, and the run refused it
        // with "the downloaded file could not be read back" (43958738406).
        File tmp = new File(dest);
        try {
            Uri uri = Uri.parse(uriString);
            if ("file".equals(uri.getScheme())) {
                in = new java.io.FileInputStream(new File(uri.getPath()));
            } else {
                ContentResolver cr = activity.getContentResolver();
                in = cr.openInputStream(uri);
            }
            if (in == null) {
                sError = "the picked document could not be opened";
                return -2;
            }
            out = new FileOutputStream(tmp, false);
            byte[] buf = new byte[65536];
            long got = 0;
            int n;
            while ((n = in.read(buf)) > 0) {
                out.write(buf, 0, n);
                got += n;
                sGot = got;
            }
            out.flush();
            out.close();
            out = null;
            in.close();
            return got;
        } catch (Exception e) {
            String m = e.getMessage();
            sError = (m == null || m.isEmpty()) ? e.getClass().getSimpleName() : m;
            return -3;
        } finally {
            if (out != null) { try { out.close(); } catch (Exception ignored) { } }
        }
    }

    // --- the activity that can receive results ---------------------------
    //
    // Everything else is inherited: this class exists for onActivityResult alone,
    // and it hands the answer to the static state above. The manifest points at it
    // instead of at android.app.NativeActivity.
    public static class UmbraActivity extends NativeActivity {
        @Override
        protected void onActivityResult(int requestCode, int resultCode, Intent data) {
            super.onActivityResult(requestCode, resultCode, data);
            Log.i(TAG, "picker: result " + resultCode + " for request " + requestCode);
            UmbraNet.delivered(requestCode, resultCode, data);
        }
    }
}
