package com.readlist.panel;

import android.content.Intent;
import android.content.pm.FeatureInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;

import androidx.annotation.NonNull;
import androidx.core.content.FileProvider;

import com.readlist.panel.ext.ExtensionBridge;

import java.io.File;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import io.flutter.embedding.android.FlutterFragmentActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

// FlutterFragmentActivity (with the AppCompat theme in styles.xml) is kept
// from the app-lock days; it works the same as FlutterActivity without it.
public class MainActivity extends FlutterFragmentActivity {
    private static final String CHANNEL = "com.readlist.panel/updater";

    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
        // Mihon extension APKs, run natively (see android/app/src/main/kotlin).
        ExtensionBridge extensions = new ExtensionBridge(this);
        extensions.register(flutterEngine.getDartExecutor().getBinaryMessenger());
        extensions.warmUp();
        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), CHANNEL)
                .setMethodCallHandler((call, result) -> {
                    try {
                        switch (call.method) {
                            case "appVersion": {
                                PackageInfo info = getPackageManager()
                                        .getPackageInfo(getPackageName(), 0);
                                result.success(info.versionName);
                                break;
                            }
                            case "updateDir": {
                                File dir = new File(getCacheDir(), "updates");
                                //noinspection ResultOfMethodCallIgnored
                                dir.mkdirs();
                                result.success(dir.getAbsolutePath());
                                break;
                            }
                            case "extensionDir": {
                                File dir = new File(getCacheDir(), "extensions");
                                //noinspection ResultOfMethodCallIgnored
                                dir.mkdirs();
                                result.success(dir.getAbsolutePath());
                                break;
                            }
                            case "installedExtensions": {
                                result.success(installedExtensions());
                                break;
                            }
                            case "uninstallPackage": {
                                String pkg = call.argument("package");
                                startActivity(new Intent(Intent.ACTION_DELETE,
                                        Uri.parse("package:" + pkg))
                                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
                                result.success(null);
                                break;
                            }
                            case "canInstall": {
                                result.success(Build.VERSION.SDK_INT < Build.VERSION_CODES.O
                                        || getPackageManager().canRequestPackageInstalls());
                                break;
                            }
                            case "openInstallSettings": {
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                    startActivity(new Intent(
                                            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                            Uri.parse("package:" + getPackageName())));
                                }
                                result.success(null);
                                break;
                            }
                            case "installApk": {
                                String path = call.argument("path");
                                File apk = new File(path);
                                Uri uri = FileProvider.getUriForFile(
                                        this, getPackageName() + ".updates", apk);
                                Intent intent = new Intent(Intent.ACTION_VIEW)
                                        .setDataAndType(uri, "application/vnd.android.package-archive")
                                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION
                                                | Intent.FLAG_ACTIVITY_NEW_TASK);
                                startActivity(intent);
                                result.success(null);
                                break;
                            }
                            default:
                                result.notImplemented();
                        }
                    } catch (Exception e) {
                        result.error("updater", e.getMessage(), null);
                    }
                });
    }

    /** Installed Mihon / Tachiyomi extensions: they declare the
     *  "tachiyomi.extension" feature in their manifest. */
    @SuppressWarnings("deprecation")
    private List<Map<String, Object>> installedExtensions() {
        List<Map<String, Object>> out = new ArrayList<>();
        PackageManager pm = getPackageManager();
        for (PackageInfo info : pm.getInstalledPackages(PackageManager.GET_CONFIGURATIONS)) {
            boolean isExtension = false;
            if (info.reqFeatures != null) {
                for (FeatureInfo f : info.reqFeatures) {
                    if ("tachiyomi.extension".equals(f.name)) {
                        isExtension = true;
                        break;
                    }
                }
            }
            if (!isExtension) continue;
            Map<String, Object> m = new HashMap<>();
            m.put("package", info.packageName);
            m.put("versionName", info.versionName == null ? "" : info.versionName);
            m.put("versionCode", Build.VERSION.SDK_INT >= Build.VERSION_CODES.P
                    ? info.getLongVersionCode() : (long) info.versionCode);
            out.add(m);
        }
        return out;
    }
}
