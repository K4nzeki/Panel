package com.readlist.panel;

import android.content.Intent;
import android.content.pm.PackageInfo;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;

import androidx.annotation.NonNull;
import androidx.core.content.FileProvider;

import java.io.File;

import io.flutter.embedding.android.FlutterFragmentActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

// FlutterFragmentActivity is required for the fingerprint / face prompt.
public class MainActivity extends FlutterFragmentActivity {
    private static final String CHANNEL = "com.readlist.panel/updater";

    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
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
}
