package com.follow.clash

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import com.follow.clash.common.Components
import com.follow.clash.common.GlobalState

internal object ManagedStartPrompt {
    private const val CHANNEL = "xclient-verification"
    private const val NOTIFICATION_ID = 0x584356

    fun request(userInitiated: Boolean) {
        val context = GlobalState.application
        val message = context.getString(R.string.xclient_verify_before_connect)
        context.showToast(message)
        val intent = Intent().setComponent(Components.mainActivity).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        if (userInitiated) {
            try {
                context.startActivity(intent)
                return
            } catch (_: RuntimeException) {
                GlobalState.log("Unable to open account verification")
            }
        }
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                manager.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL,
                        context.getString(R.string.xclient_verification_channel),
                        NotificationManager.IMPORTANCE_DEFAULT,
                    ),
                )
            }
            val pending = PendingIntent.getActivity(
                context,
                NOTIFICATION_ID,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, CHANNEL)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }
            manager.notify(
                NOTIFICATION_ID,
                builder.setSmallIcon(android.R.drawable.ic_dialog_info)
                    .setContentTitle(context.applicationInfo.loadLabel(context.packageManager))
                    .setContentText(message)
                    .setContentIntent(pending)
                    .setAutoCancel(true)
                    .build(),
            )
        } catch (_: SecurityException) {
            GlobalState.log("Account verification notification is unavailable")
        }
    }
}
