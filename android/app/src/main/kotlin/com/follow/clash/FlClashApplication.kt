package com.follow.clash

import android.app.Application
import android.content.ComponentCallbacks2
import android.content.Context
import com.follow.clash.common.GlobalState

class FlClashApplication : Application() {
    override fun attachBaseContext(base: Context?) {
        super.attachBaseContext(base)
        GlobalState.init(this)
    }

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        ManagedFlutterEngineOwner.onTrimMemory(level)
    }

    @Suppress("DEPRECATION")
    override fun onLowMemory() {
        super.onLowMemory()
        ManagedFlutterEngineOwner.onTrimMemory(ComponentCallbacks2.TRIM_MEMORY_COMPLETE)
    }
}
