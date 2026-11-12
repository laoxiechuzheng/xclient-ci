package com.follow.clash

import android.app.Activity
import android.content.ComponentCallbacks2
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import com.follow.clash.common.Components
import com.follow.clash.common.GlobalState
import com.follow.clash.plugins.AppPlugin
import com.follow.clash.plugins.BatteryPlugin
import com.follow.clash.plugins.ServicePlugin
import com.follow.clash.plugins.TilePlugin
import com.follow.clash.xclient.UpdatePlugin
import io.flutter.embedding.engine.FlutterEngine

internal object ManagedFlutterEngineOwner {
    private val handler = Handler(Looper.getMainLooper())
    private var pendingUpdateRequest = false
    private val lifecycle = ManagedEngineLifecycle(
        create = { createEngine(GlobalState.application) },
        destroy = { engine ->
            ServiceState.detachFlutterEngine(engine)
            engine.destroy()
        },
        finishHost = { host ->
            handler.post {
                val activity = host as Activity
                if (!activity.isDestroyed) activity.finish()
            }
        },
        reopen = {
            handler.post {
                val context = GlobalState.application
                val intent = Intent(Intent.ACTION_MAIN).setComponent(Components.mainActivity)
                    .addCategory(Intent.CATEGORY_LAUNCHER)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                if (pendingUpdateRequest) {
                    intent.action = AppPlugin.updateRequestAction(context)
                    pendingUpdateRequest = false
                }
                try {
                    context.startActivity(intent)
                } catch (_: RuntimeException) {
                    GlobalState.log("Unable to reopen the client")
                }
            }
        },
        deferRelease = { release -> handler.post { release() } },
    )

    val isClosing: Boolean
        get() = lifecycle.isClosing

    val hasInteractiveActivity: Boolean
        get() = lifecycle.hasInteractiveActivity

    fun acquire(activity: Activity): ManagedEngineLease<FlutterEngine> = onMain {
        if (isClosing && AppPlugin.isUpdateRequest(activity.intent)) pendingUpdateRequest = true
        lifecycle.acquire(activity)
    }

    fun hostDetached(activity: Activity) = onMain { lifecycle.hostDetached(activity) }

    fun hostDestroyed(activity: Activity) = onMain { lifecycle.hostDestroyed(activity) }

    fun beginExit(): Long? = onMain { lifecycle.beginExit() }

    fun abortExit(generation: Long): Boolean = onMain { lifecycle.abortExit(generation) }

    fun completeExit(generation: Long): Boolean = onMain { lifecycle.completeExit(generation) }

    fun canCompleteExit(generation: Long): Boolean = onMain { lifecycle.canCompleteExit(generation) }

    fun queueReopen(updateRequest: Boolean = false) = onMain {
        pendingUpdateRequest = pendingUpdateRequest || updateRequest
        lifecycle.queueReopen()
    }

    @Suppress("DEPRECATION")
    fun onTrimMemory(level: Int) = onMain {
        if (!hasInteractiveActivity) {
            lifecycle.engine?.let { engine ->
                if (level >= ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW) {
                    engine.dartExecutor.notifyLowMemoryWarning()
                    engine.systemChannel.sendMemoryPressureWarning()
                }
                engine.renderer.onTrimMemory(level)
                engine.platformViewsController.onTrimMemory(level)
            }
        }
    }

    private fun createEngine(context: Context): FlutterEngine {
        val engine = FlutterEngine(context.applicationContext)
        try {
            engine.plugins.add(AppPlugin(retainOnActivityDetach = true))
            engine.plugins.add(BatteryPlugin())
            engine.plugins.add(ServicePlugin())
            engine.plugins.add(TilePlugin())
            engine.plugins.add(UpdatePlugin())
            ServiceState.attachFlutterEngine(engine)
            return engine
        } catch (error: RuntimeException) {
            ServiceState.detachFlutterEngine(engine)
            engine.destroy()
            throw error
        }
    }

    private inline fun <T> onMain(block: () -> T): T {
        check(Looper.myLooper() == Looper.getMainLooper())
        return block()
    }
}
