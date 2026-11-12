package com.follow.clash.xclient

import android.app.Activity
import android.app.PendingIntent
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import com.follow.clash.R
import com.follow.clash.common.Components
import com.follow.clash.plugins.AppPlugin
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors

class UpdatePlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler,
    PluginRegistry.ActivityResultListener {
    private lateinit var context: Context
    private var channel: MethodChannel? = null
    private var binding: ActivityPluginBinding? = null
    private var permissionResult: MethodChannel.Result? = null
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "xclient/update")
        channel?.setMethodCallHandler(this)
        active = this
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        if (active === this) active = null
        channel?.setMethodCallHandler(null)
        channel = null
        permissionResult?.success(false)
        permissionResult = null
        worker.shutdown()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        this.binding = binding
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = detachActivity()
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)
    override fun onDetachedFromActivity() {
        detachActivity()
        permissionResult?.success(false)
        permissionResult = null
    }

    private fun detachActivity() {
        binding?.removeActivityResultListener(this)
        binding = null
    }

    private fun canInstall() = Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
        context.packageManager.canRequestPackageInstalls()

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "notifyUpdateAction" -> result.success(notifyUpdateAction(call.argument<String>("kind")))
            "clearUpdateAction" -> {
                context.getSystemService(NotificationManager::class.java).cancel("xclient-update-action", 7716)
                result.success(true)
            }
            "canInstall" -> result.success(canInstall())
            "openInstallSettings" -> {
                if (canInstall()) {
                    result.success(true)
                    return
                }
                val activity = binding?.activity
                if (activity == null || permissionResult != null) {
                    result.error("permission_unavailable", "Cannot open install settings", null)
                    return
                }
                permissionResult = result
                try {
                    activity.startActivityForResult(Intent(
                        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:${context.packageName}"),
                    ), permissionRequest)
                } catch (_: Exception) {
                    permissionResult = null
                    result.error("permission_unavailable", "Cannot open install settings", null)
                }
            }
            "inspectArchive", "install" -> {
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("invalid_path", "Missing package path", null)
                    return
                }
                worker.execute {
                    try {
                        val file = packageFile(path)
                        val info = inspect(file)
                        if (call.method == "inspectArchive") {
                            main.post { result.success(info) }
                        } else {
                            check(canInstall()) { "install_permission" }
                            check(info["samePackage"] == true && info["sameSigner"] == true &&
                                info["newerVersion"] == true) { "package_mismatch" }
                            val session = install(file)
                            main.post { result.success(session) }
                        }
                    } catch (_: Exception) {
                        main.post { result.error("install_failed", "Package validation or installation failed", null) }
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun notifyUpdateAction(kind: String?): Boolean {
        val text = when (kind) {
            "permission" -> R.string.xclient_update_permission
            "failed" -> R.string.xclient_update_retry
            "required" -> R.string.xclient_update_required
            "available" -> R.string.xclient_update_available
            else -> return false
        }
        return try {
            val manager = context.getSystemService(NotificationManager::class.java)
            val notificationChannel = "xclient-update-actions"
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                manager.createNotificationChannel(NotificationChannel(notificationChannel,
                    context.getString(R.string.xclient_update_channel), NotificationManager.IMPORTANCE_DEFAULT))
                Notification.Builder(context, notificationChannel)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }
            val intent = Intent(AppPlugin.updateRequestAction(context)).setComponent(Components.mainActivity)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            val pending = PendingIntent.getActivity(context, 7716, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            manager.notify("xclient-update-action", 7716, builder.setSmallIcon(context.applicationInfo.icon)
                .setContentTitle(context.applicationInfo.loadLabel(context.packageManager))
                .setContentText(context.getString(text)).setContentIntent(pending).setAutoCancel(true).build())
            true
        } catch (_: Exception) { false }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != permissionRequest) return false
        permissionResult?.success(canInstall())
        permissionResult = null
        return true
    }

    private fun packageFile(path: String): File {
        val file = File(path).canonicalFile
        val roots = listOf(context.cacheDir, context.filesDir).map { it.canonicalPath + File.separator }
        require(roots.any { file.path.startsWith(it) })
        require(file.isFile && file.canRead() && file.name.endsWith(".apk") && file.length() > 0)
        return file
    }

    @Suppress("DEPRECATION")
    private fun inspect(file: File): Map<String, Any> {
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
            PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
        val pm = context.packageManager
        val archive = pm.getPackageArchiveInfo(file.path, flags)
            ?: return mapOf("samePackage" to false, "sameSigner" to false, "newerVersion" to false)
        val installed = pm.getPackageInfo(context.packageName, flags)
        val archiveSigners = signers(archive)
        val installedSigners = signers(installed)
        val archiveVersion = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
            archive.longVersionCode else archive.versionCode.toLong()
        val currentVersion = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
            installed.longVersionCode else installed.versionCode.toLong()
        return mapOf(
            "samePackage" to (archive.packageName == context.packageName),
            "sameSigner" to (archiveSigners.isNotEmpty() && archiveSigners == installedSigners),
            "newerVersion" to (archiveVersion > currentVersion),
        )
    }

    @Suppress("DEPRECATION")
    private fun signers(info: PackageInfo): Set<String> {
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
            info.signingInfo?.apkContentsSigners else info.signatures
        return signatures?.map { signature ->
            MessageDigest.getInstance("SHA-256").digest(signature.toByteArray())
                .joinToString("") { "%02x".format(it) }
        }?.toSet() ?: emptySet()
    }

    private fun install(file: File): Int {
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        params.setAppPackageName(context.packageName)
        params.setSize(file.length())
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_REQUIRED)
        }
        val sessionId = installer.createSession(params)
        try {
            installer.openSession(sessionId).use { session ->
                session.openWrite("base.apk", 0, file.length()).use { output ->
                    file.inputStream().use { it.copyTo(output) }
                    session.fsync(output)
                }
                val callback = Intent(context, UpdateInstallReceiver::class.java)
                    .setAction("${context.packageName}.xclient.INSTALL_STATUS")
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                    (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0)
                val pending = PendingIntent.getBroadcast(context, sessionId, callback, flags)
                session.commit(pending.intentSender)
            }
        } catch (error: Exception) {
            installer.abandonSession(sessionId)
            throw error
        }
        return sessionId
    }

    private fun notifyStatus(sessionId: Int, status: String) {
        main.post {
            channel?.invokeMethod("onInstallStatus", mapOf(
                "sessionId" to sessionId, "status" to status,
            ))
        }
    }

    companion object {
        private const val permissionRequest = 7714
        private var active: UpdatePlugin? = null
        private val pendingConfirmations = linkedMapOf<Int, Intent>()
        private const val notificationId = 7715
        fun deliver(sessionId: Int, status: String) {
            active?.notifyStatus(sessionId, status)
        }

        fun resumePending(activity: Activity) {
            for ((sessionId, confirmation) in pendingConfirmations.toMap()) {
                if (!ownsSession(activity, sessionId)) {
                    finish(activity, sessionId)
                    continue
                }
                launchConfirmation(activity, sessionId, confirmation)
                return
            }
        }

        private fun ownsSession(context: Context, sessionId: Int): Boolean {
            if (sessionId <= 0) return false
            return try {
                val installer = context.packageManager.packageInstaller
                val info = installer.getSessionInfo(sessionId) ?: return false
                info.appPackageName == context.packageName &&
                    installer.mySessions.any { it.sessionId == sessionId }
            } catch (_: Exception) { false }
        }

        private fun notificationTag(sessionId: Int) = "xclient-update-$sessionId"

        fun finish(context: Context, sessionId: Int) {
            pendingConfirmations.remove(sessionId)
            context.getSystemService(NotificationManager::class.java)
                .cancel(notificationTag(sessionId), notificationId)
        }

        private fun launchConfirmation(activity: Activity, sessionId: Int, confirmation: Intent): Boolean {
            try {
                activity.startActivity(Intent(confirmation).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                finish(activity, sessionId)
                return true
            } catch (_: Exception) { return false }
        }

        fun confirm(context: Context, sessionId: Int, confirmation: Intent): Boolean {
            if (!ownsSession(context, sessionId)) return false
            val systemConfirmation = Intent(confirmation).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            pendingConfirmations[sessionId] = systemConfirmation
            val activity = active?.binding?.activity
            if (activity != null && activity.hasWindowFocus() &&
                launchConfirmation(activity, sessionId, systemConfirmation)) {
                return true
            }
            try {
                val manager = context.getSystemService(NotificationManager::class.java)
                val channel = "xclient_updates"
                val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    manager.createNotificationChannel(NotificationChannel(
                        channel, "客户端更新", NotificationManager.IMPORTANCE_DEFAULT,
                    ))
                    Notification.Builder(context, channel)
                } else {
                    @Suppress("DEPRECATION")
                    Notification.Builder(context)
                }
                val pending = PendingIntent.getActivity(context, sessionId, systemConfirmation,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                manager.notify(notificationTag(sessionId), notificationId, builder
                    .setSmallIcon(context.applicationInfo.icon)
                    .setContentTitle("请确认客户端更新")
                    .setContentText("点击继续确认安装新版本")
                    .setContentIntent(pending)
                    .setAutoCancel(true)
                    .build())
            } catch (_: Exception) { }
            return true
        }
    }
}

class UpdateInstallReceiver : BroadcastReceiver() {
    @Suppress("DEPRECATION")
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != "${context.packageName}.xclient.INSTALL_STATUS") return
        val session = intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1)
        if (session <= 0) return
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            val confirmation = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
                intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
            else intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
            if (confirmation != null) {
                try {
                    if (UpdatePlugin.confirm(context, session, confirmation)) {
                        UpdatePlugin.deliver(session, "pending_user")
                        return
                    }
                } catch (_: Exception) { }
            }
            UpdatePlugin.finish(context, session)
            UpdatePlugin.deliver(session, "failure")
            return
        }
        UpdatePlugin.finish(context, session)
        UpdatePlugin.deliver(session, when (status) {
            PackageInstaller.STATUS_SUCCESS -> "success"
            PackageInstaller.STATUS_FAILURE_ABORTED -> "aborted"
            else -> "failure"
        })
    }
}
