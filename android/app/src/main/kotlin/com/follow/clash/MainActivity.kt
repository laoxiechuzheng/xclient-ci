package com.follow.clash

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.view.Gravity
import android.window.BackEvent
import android.widget.TextView
import com.follow.clash.core.Core
import com.follow.clash.plugins.AppPlugin
import com.follow.clash.plugins.BatteryPlugin
import com.follow.clash.plugins.ServicePlugin
import com.follow.clash.plugins.TilePlugin
import com.follow.clash.xclient.UpdatePlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.platform.PlatformPlugin
import io.flutter.plugin.view.SensitiveContentPlugin

class MainActivity : FlutterActivity() {
    private val managedBuild by lazy { Core.isManagedBuild() }
    private var engineLease: ManagedEngineLease<FlutterEngine>? = null
    private val closingHost: Boolean
        get() = engineLease?.closingHost == true

    override fun getCachedEngineId(): String? =
        if (managedBuild) null else super.getCachedEngineId()

    override fun getCachedEngineGroupId(): String? =
        if (managedBuild) null else super.getCachedEngineGroupId()

    override fun provideFlutterEngine(context: Context): FlutterEngine? {
        if (!managedBuild) return super.provideFlutterEngine(context)
        return ManagedFlutterEngineOwner.acquire(this).also { engineLease = it }.engine
    }

    override fun shouldDestroyEngineWithHost(): Boolean =
        if (managedBuild) false else super.shouldDestroyEngineWithHost()

    override fun shouldRestoreAndSaveState(): Boolean =
        if (managedBuild) false else super.shouldRestoreAndSaveState()

    override fun shouldAttachEngineToActivity(): Boolean =
        !closingHost && super.shouldAttachEngineToActivity()

    override fun attachToEngineAutomatically(): Boolean =
        !closingHost && super.attachToEngineAutomatically()

    override fun shouldDispatchAppLifecycleState(): Boolean =
        !closingHost && super.shouldDispatchAppLifecycleState()

    override fun providePlatformPlugin(
        activity: Activity?,
        flutterEngine: FlutterEngine,
    ): PlatformPlugin? =
        if (closingHost) null else super.providePlatformPlugin(activity, flutterEngine)

    override fun provideSensitiveContentPlugin(
        activity: Activity?,
        flutterEngine: FlutterEngine,
    ): SensitiveContentPlugin? =
        if (closingHost) null else super.provideSensitiveContentPlugin(activity, flutterEngine)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (closingHost) {
            setContentView(TextView(this).apply {
                gravity = Gravity.CENTER
                setText(R.string.xclient_exiting)
            })
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        if (managedBuild) return
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(AppPlugin())
        flutterEngine.plugins.add(BatteryPlugin())
        flutterEngine.plugins.add(ServicePlugin())
        flutterEngine.plugins.add(TilePlugin())
        flutterEngine.plugins.add(UpdatePlugin())
        ServiceState.attachFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        if (!managedBuild) flutterEngine?.let(ServiceState::detachFlutterEngine)
        super.onDestroy()
        if (managedBuild) ManagedFlutterEngineOwner.hostDestroyed(this)
    }

    override fun detachFromFlutterEngine() {
        super.detachFromFlutterEngine()
        if (managedBuild) ManagedFlutterEngineOwner.hostDetached(this)
    }

    override fun onNewIntent(intent: Intent) {
        if (managedBuild && (closingHost || ManagedFlutterEngineOwner.isClosing)) {
            setIntent(intent)
            ManagedFlutterEngineOwner.queueReopen(AppPlugin.isUpdateRequest(intent))
            return
        }
        super.onNewIntent(intent)
    }

    @Suppress("DEPRECATION")
    override fun onBackPressed() {
        if (closingHost) finish() else super.onBackPressed()
    }

    override fun startBackGesture(backEvent: BackEvent) {
        if (!closingHost) super.startBackGesture(backEvent)
    }

    override fun updateBackGestureProgress(backEvent: BackEvent) {
        if (!closingHost) super.updateBackGestureProgress(backEvent)
    }

    override fun commitBackGesture() {
        if (closingHost) finish() else super.commitBackGesture()
    }

    override fun cancelBackGesture() {
        if (!closingHost) super.cancelBackGesture()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (!closingHost) super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray,
    ) {
        if (!closingHost) super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun onUserLeaveHint() {
        if (!closingHost) super.onUserLeaveHint()
    }

    override fun onResume() {
        super.onResume()
        if (!closingHost && (!managedBuild || !ManagedFlutterEngineOwner.isClosing)) {
            UpdatePlugin.resumePending(this)
        }
    }
}
