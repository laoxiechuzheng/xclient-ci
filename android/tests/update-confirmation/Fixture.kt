package com.follow.clash.xclient.fixture

class Intent(val actionValue: String? = null) {
    var action = actionValue
    var targetPackage: String? = null
    var component: String? = null
    var flags = 0
    private val extras = mutableMapOf<String, Any?>()
    constructor(other: Intent) : this(other.action) {
        targetPackage = other.targetPackage
        component = other.component
        flags = other.flags
        extras.putAll(other.extras)
    }
    fun setPackage(value: String) = apply { targetPackage = value }
    fun addFlags(value: Int) = apply { flags = flags or value }
    fun putExtra(key: String, value: Any?) = apply { extras[key] = value }
    fun getIntExtra(key: String, fallback: Int) = extras[key] as? Int ?: fallback
    @Suppress("UNCHECKED_CAST")
    fun <T> getParcelableExtra(key: String): T? = extras[key] as? T
    fun <T> getParcelableExtra(key: String, type: Class<T>): T? = type.cast(extras[key])
    fun opaque() = extras["opaque"]
    companion object {
        const val EXTRA_INTENT = "intent"
        const val FLAG_ACTIVITY_NEW_TASK = 0x10000000
    }
}

class PackageInstaller {
    data class SessionInfo(val sessionId: Int, val appPackageName: String?)
    val sessions = mutableMapOf<Int, SessionInfo>()
    val owned = mutableSetOf<Int>()
    val mySessions get() = sessions.values.filter { it.sessionId in owned }
    fun getSessionInfo(id: Int) = sessions[id]
    companion object {
        const val EXTRA_SESSION_ID = "session"
        const val EXTRA_STATUS = "status"
        const val STATUS_PENDING_USER_ACTION = -1
        const val STATUS_SUCCESS = 0
        const val STATUS_FAILURE = 1
        const val STATUS_FAILURE_ABORTED = 3
    }
}

class PackageManager {
    val packageInstaller = PackageInstaller()
    fun getLaunchIntentForPackage(name: String) = Intent("launcher").setPackage(name)
}

open class Context(
    val packageManager: PackageManager = PackageManager(),
    val notifications: NotificationManager = NotificationManager(),
) {
    val packageName = "com.xclient.example"
    val applicationInfo = ApplicationInfo()
    @Suppress("UNCHECKED_CAST")
    fun <T> getSystemService(type: Class<T>): T = notifications as T
}

class ApplicationInfo { val icon = 1 }
class Activity(context: Context, val focused: Boolean = true) : Context(context.packageManager, context.notifications) {
    val launched = mutableListOf<Intent>()
    fun hasWindowFocus() = focused
    fun startActivity(intent: Intent) { launched += Intent(intent) }
}
class Binding(val activity: Activity)
open class BroadcastReceiver { open fun onReceive(context: Context, intent: Intent) = Unit }
object Build {
    object VERSION { var SDK_INT = 35 }
    object VERSION_CODES { const val O = 26; const val TIRAMISU = 33 }
}
class NotificationChannel(val id: String, val name: String, val importance: Int)
class Notification(val pending: PendingIntent?) {
    class Builder(context: Context, channel: String = "") {
        private var pending: PendingIntent? = null
        fun setSmallIcon(value: Int) = this
        fun setContentTitle(value: String) = this
        fun setContentText(value: String) = this
        fun setContentIntent(value: PendingIntent) = apply { pending = value }
        fun setAutoCancel(value: Boolean) = this
        fun build() = Notification(pending)
    }
}
class NotificationManager {
    val posted = linkedMapOf<Pair<String?, Int>, Notification>()
    fun createNotificationChannel(channel: NotificationChannel) = Unit
    fun notify(id: Int, notification: Notification) { posted[null to id] = notification }
    fun notify(tag: String, id: Int, notification: Notification) { posted[tag to id] = notification }
    fun cancel(id: Int) { posted.remove(null to id) }
    fun cancel(tag: String, id: Int) { posted.remove(tag to id) }
    companion object { const val IMPORTANCE_DEFAULT = 3 }
}
class PendingIntent(val requestCode: Int, var intent: Intent, val flags: Int) {
    fun send() = Intent(intent)
    companion object {
        const val FLAG_UPDATE_CURRENT = 1
        const val FLAG_IMMUTABLE = 2
        private val records = mutableMapOf<List<Any?>, PendingIntent>()
        fun clear() = records.clear()
        fun getActivity(context: Context, code: Int, intent: Intent, flags: Int): PendingIntent {
            val key = listOf(code, intent.action, intent.targetPackage, intent.component)
            val previous = records[key]
            if (previous != null) {
                if (flags and FLAG_UPDATE_CURRENT != 0) previous.intent = Intent(intent)
                return previous
            }
            return PendingIntent(code, Intent(intent), flags).also { records[key] = it }
        }
    }
}

object Delivery { val statuses = mutableListOf<Pair<Int, String>>() }
private fun processDeath() {
    for (field in UpdatePlugin::class.java.declaredFields) {
        field.isAccessible = true
        when {
            field.name == "active" -> field.set(null, null)
            field.name.startsWith("pendingConfirmation") -> {
                val state = field.get(null)
                if (state is MutableMap<*, *>) state.clear() else field.set(null, null)
            }
        }
    }
}
private fun owner(context: Context, id: Int, pkg: String? = context.packageName, ours: Boolean = true) {
    context.packageManager.packageInstaller.sessions[id] = PackageInstaller.SessionInfo(id, pkg)
    if (ours) context.packageManager.packageInstaller.owned += id
}
private fun confirmation(id: Int, opaque: Any = Any()) = Intent("system-confirm")
    .setPackage("com.android.packageinstaller")
    .putExtra(PackageInstaller.EXTRA_SESSION_ID, id)
    .putExtra("opaque", opaque)
private fun status(context: Context, id: Int, result: Int, confirm: Intent? = null, action: String = "${context.packageName}.xclient.INSTALL_STATUS") {
    val intent = Intent(action).putExtra(PackageInstaller.EXTRA_SESSION_ID, id)
        .putExtra(PackageInstaller.EXTRA_STATUS, result)
    if (confirm != null) intent.putExtra(Intent.EXTRA_INTENT, confirm)
    UpdateInstallReceiver().onReceive(context, intent)
}

fun main() {
    var passed = 0
    var failed = 0
    fun test(name: String, action: () -> Unit) {
        processDeath()
        PendingIntent.clear()
        Delivery.statuses.clear()
        try { action(); passed++; println("PASS $name") }
        catch (error: Throwable) { failed++; println("FAIL $name: ${error.message}") }
    }
    test("system confirmation survives creator process death without static state") {
        val context = Context()
        owner(context, 7)
        val opaque = Any()
        val original = confirmation(7, opaque)
        status(context, 7, PackageInstaller.STATUS_PENDING_USER_ACTION, original)
        val pending = context.notifications.posted.values.single().pending!!
        processDeath()
        val sent = pending.send()
        check(sent.action == "system-confirm") { "notification lost the system confirmation" }
        check(sent.targetPackage == "com.android.packageinstaller" && sent.component == null)
        check(sent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1) == 7)
        check(sent.opaque() === opaque && sent.flags and Intent.FLAG_ACTIVITY_NEW_TASK != 0)
        check(pending.flags and PendingIntent.FLAG_IMMUTABLE != 0 && original.flags == 0)
    }
    test("two sessions retain separate notifications and activity tokens") {
        val context = Context()
        for (id in listOf(7, 8)) {
            owner(context, id)
            status(context, id, PackageInstaller.STATUS_PENDING_USER_ACTION, confirmation(id))
        }
        val pending = context.notifications.posted.values.map { it.pending!! }
        check(pending.size == 2 && pending.map { it.requestCode }.toSet().size == 2)
        processDeath()
        check(pending.map { it.send().getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1) }.toSet() == setOf(7, 8))
    }
    test("foreign owner, foreign package, unknown package and uncontrolled action are refused") {
        for ((pkg, ours, action) in listOf(
            Triple("com.xclient.example", false, "com.xclient.example.xclient.INSTALL_STATUS"),
            Triple("other.package", true, "com.xclient.example.xclient.INSTALL_STATUS"),
            Triple(null, true, "com.xclient.example.xclient.INSTALL_STATUS"),
            Triple("com.xclient.example", true, "other.action"),
        )) {
            val context = Context()
            owner(context, 7, pkg, ours)
            status(context, 7, PackageInstaller.STATUS_PENDING_USER_ACTION, confirmation(7), action)
            check(context.notifications.posted.isEmpty())
        }
    }
    test("foreground confirmation clones the opaque system action immediately") {
        val context = Context()
        owner(context, 7)
        val activity = Activity(context)
        UpdatePlugin().attachForFixture(activity)
        val original = confirmation(7)
        status(context, 7, PackageInstaller.STATUS_PENDING_USER_ACTION, original)
        check(activity.launched.single().action == "system-confirm" && original.flags == 0)
        check(context.notifications.posted.isEmpty())
        check(Delivery.statuses.last() == 7 to "pending_user")
    }
    test("terminal cleanup works after session removal and leaves another session intact") {
        val context = Context()
        for (id in listOf(7, 8)) {
            owner(context, id)
            status(context, id, PackageInstaller.STATUS_PENDING_USER_ACTION, confirmation(id))
        }
        context.packageManager.packageInstaller.sessions.remove(7)
        status(context, 7, PackageInstaller.STATUS_FAILURE_ABORTED)
        check(context.notifications.posted.size == 1)
        val activity = Activity(context)
        UpdatePlugin().attachForFixture(activity)
        UpdatePlugin.resumePending(activity)
        check(activity.launched.single().getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1) == 8)
    }
    test("terminal cleanup after process death needs no session metadata") {
        val context = Context()
        owner(context, 7)
        status(context, 7, PackageInstaller.STATUS_PENDING_USER_ACTION, confirmation(7))
        processDeath()
        context.packageManager.packageInstaller.sessions.clear()
        status(context, 7, PackageInstaller.STATUS_SUCCESS)
        check(context.notifications.posted.isEmpty())
    }
    println("SUMMARY passed=$passed failed=$failed; actual companion/receiver bodies; simulated Android framework")
    check(failed == 0) { "confirmation contract failed" }
}
