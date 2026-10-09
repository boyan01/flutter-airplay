// SPDX-License-Identifier: GPL-3.0-or-later
package tech.soit.flutterairplay

import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/** Android owns package identity/signatures and the system installation UI. */
internal class AppUpdateInstaller(private val activity: MainActivity, private val channel: MethodChannel) {
    private val worker = Executors.newSingleThreadExecutor()
    private var disposed = false

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method == "install") {
                val path = call.argument<String>("path")
                val expected = call.argument<Number>("versionCode")?.toLong()
                if (path == null || expected == null || BuildConfig.DEBUG) {
                    result.error("update", "Invalid update request or debug build.", null)
                    return@setMethodCallHandler
                }
                worker.execute {
                    try {
                        val file = verify(path, expected)
                        activity.runOnUiThread {
                            if (disposed || activity.isFinishing || activity.isDestroyed) {
                                result.error("update", "The update window is no longer available.", null)
                            } else {
                                try {
                                    if (!activity.packageManager.canRequestPackageInstalls()) {
                                        activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                            Uri.parse("package:${activity.packageName}")))
                                    } else {
                                        val uri = FileProvider.getUriForFile(activity,
                                            "${activity.packageName}.updates", file)
                                        activity.startActivity(Intent(Intent.ACTION_VIEW).apply {
                                            setDataAndType(uri, "application/vnd.android.package-archive")
                                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                        })
                                    }
                                    result.success(null)
                                } catch (error: Exception) {
                                    result.error("update", error.message, null)
                                }
                            }
                        }
                    } catch (error: Exception) {
                        activity.runOnUiThread { result.error("update", error.message, null) }
                    }
                }
            } else result.notImplemented()
        }
    }

    @Suppress("DEPRECATION")
    private fun packageInfo(path: String?): PackageInfo {
        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
        return if (path == null) activity.packageManager.getPackageInfo(activity.packageName, flags)
            else activity.packageManager.getPackageArchiveInfo(path, flags)
                ?: throw IllegalArgumentException("Invalid APK.")
    }

    @Suppress("DEPRECATION")
    private fun versionCode(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()

    @Suppress("DEPRECATION")
    private fun signatures(info: PackageInfo): Set<String> {
        val values = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures
        return values?.map { it.toCharsString() }?.toSet().orEmpty()
    }

    private fun verify(path: String, expected: Long): File {
        val directory = File(activity.cacheDir, "updates").canonicalFile
        val file = File(path).canonicalFile
        require(file.parentFile == directory && file.isFile && file.length() > 0) { "Invalid update file path." }
        val installed = packageInfo(null)
        val archive = packageInfo(file.path)
        require(archive.packageName == activity.packageName) { "APK package does not match this application." }
        require(versionCode(archive) == expected && expected > versionCode(installed)) { "APK version is not a newer update." }
        val trusted = signatures(installed)
        require(trusted.isNotEmpty() && signatures(archive) == trusted) { "APK signing certificate does not match this application." }
        return file
    }

    fun dispose() {
        disposed = true
        channel.setMethodCallHandler(null)
        worker.shutdown()
    }
}
