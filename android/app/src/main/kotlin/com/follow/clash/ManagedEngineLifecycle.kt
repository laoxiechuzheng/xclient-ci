package com.follow.clash

internal data class ManagedEngineLease<E>(
    val engine: E,
    val generation: Long,
    val closingHost: Boolean,
)

internal class ManagedEngineLifecycle<E>(
    private val create: () -> E,
    private val destroy: (E) -> Unit,
    private val finishHost: (Any) -> Unit,
    private val reopen: () -> Unit,
    private val deferRelease: (() -> Unit) -> Unit = { it() },
) {
    private var currentEngine: E? = null
    private var generation = 0L
    private var terminal = false
    private var pendingReopen = false
    private var releaseQueued = false
    @Volatile
    private var interactiveHost: Any? = null
    private val hosts = linkedMapOf<Any, ManagedEngineLease<E>>()

    @Volatile
    var isClosing = false
        private set

    val engine: E?
        get() = currentEngine

    val hasInteractiveActivity: Boolean
        get() = !isClosing && interactiveHost != null

    fun acquire(host: Any): ManagedEngineLease<E> {
        hosts[host]?.let { return it }
        val engine = currentEngine ?: create().also {
            currentEngine = it
            generation++
        }
        val lease = ManagedEngineLease(engine, generation, isClosing)
        hosts[host] = lease
        if (lease.closingHost) {
            pendingReopen = true
            if (terminal) finishHost(host)
        } else {
            interactiveHost = host
        }
        return lease
    }

    fun hostDestroyed(host: Any) {
        if (hosts.remove(host) == null) return
        hostDetached(host)
        settle()
    }

    fun hostDetached(host: Any) {
        if (interactiveHost === host) interactiveHost = null
    }

    fun beginExit(): Long? {
        if (currentEngine == null) return null
        isClosing = true
        return generation
    }

    fun queueReopen() {
        if (currentEngine == null) return
        pendingReopen = true
        settle()
    }

    fun abortExit(requestGeneration: Long): Boolean {
        if (!matchesClosing(requestGeneration) || terminal) return false
        isClosing = false
        hosts.filterValues { it.closingHost }.keys.toList().forEach(finishHost)
        settle()
        return true
    }

    fun completeExit(requestGeneration: Long): Boolean {
        if (!matchesClosing(requestGeneration)) return false
        if (!terminal) {
            terminal = true
            hosts.keys.toList().forEach(finishHost)
        }
        settle()
        return true
    }

    private fun matchesClosing(requestGeneration: Long): Boolean =
        currentEngine != null && isClosing && requestGeneration == generation

    fun canCompleteExit(requestGeneration: Long): Boolean = matchesClosing(requestGeneration)

    private fun settle() {
        if (terminal && hosts.isEmpty()) {
            if (releaseQueued) return
            releaseQueued = true
            deferRelease release@{
                releaseQueued = false
                if (!terminal || hosts.isNotEmpty()) return@release
                val engine = currentEngine ?: return@release
                currentEngine = null
                terminal = false
                isClosing = false
                destroy(engine)
                replayReopen()
            }
        }
        replayReopen()
    }

    private fun replayReopen() {
        if (!isClosing && pendingReopen && hosts.values.none { it.closingHost }) {
            pendingReopen = false
            reopen()
        }
    }
}
