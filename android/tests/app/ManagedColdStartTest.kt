package com.follow.clash

import com.follow.clash.common.AccessControlMode
import com.follow.clash.models.SetupParams
import com.follow.clash.models.SharedState
import com.follow.clash.service.models.AccessControlProps
import com.follow.clash.service.models.NotificationParams
import com.follow.clash.service.models.VpnOptions
import java.net.InetAddress
import java.net.ServerSocket
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

private class ColdStartHost : ServiceStateHost, AutoCloseable {
    override val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
    override val homeDirPath = "/test/files"
    override val sdkInt = 34
    override var runtime: ServiceRuntime? = null
    var managedBuild = false
    var appClosing = false
    var gateway: TileGateway? = null
    var setupCalls = 0
    var startCalls = 0
    var stopCalls = 0
    var loadCalls = 0
    var startGate: CompletableDeferred<Unit>? = null
    var stopGate: CompletableDeferred<Unit>? = null
    var stopFails = false
    var confirmationPending = false
    var stopReports = 0
    var clearOrdinaryFailure = false
    var permissionApp: AppGateway? = null
    var listener: ServerSocket? = null
    val verificationRequests = mutableListOf<Boolean>()
    val stored = SharedState(
        setupParams = SetupParams("https://example.invalid", emptyMap()),
        vpnOptions = VpnOptions(
            enable = true,
            port = 7890,
            ipv6 = false,
            dnsHijacking = false,
            accessControlProps = AccessControlProps(false, AccessControlMode.ACCEPT_SELECTED, emptyList(), emptyList()),
            allowBypass = false,
            systemProxy = false,
            bypassDomain = emptyList(),
            stack = "gvisor",
            routeAddress = emptyList(),
        ),
    )

    override fun isManagedBuild(): Boolean = managedBuild
    override fun isAppClosing(): Boolean = appClosing
    override fun requiresStopConfirmation(): Boolean = confirmationPending

    override fun requestAppVerification(userInitiated: Boolean) {
        verificationRequests += userInitiated
    }

    override fun log(message: String) = Unit
    override fun showToast(message: String) = Unit
    override fun updateNotificationParams(params: NotificationParams) = Unit
    override fun loadSharedState(): SharedState {
        loadCalls++
        return stored
    }
    override fun isVpnPermissionGranted(): Boolean = true
    override fun isLocalNetworkPermissionGranted(): Boolean = true
    override fun tile(): TileGateway? = gateway
    override fun app(): AppGateway? = permissionApp
    override fun notifyStopped() { stopReports++ }

    override suspend fun stopServiceConfirmed(): Boolean {
        confirmationPending = true
        stopCalls++
        stopGate?.await()
        if (stopFails) return false
        listener?.close()
        runtime = null
        val confirmed = runtime == null
        if (confirmed) confirmationPending = false
        return confirmed
    }

    override suspend fun quickSetup(initParams: String, setupParams: String): Result<String> {
        setupCalls++
        listener = ServerSocket(0, 1, InetAddress.getLoopbackAddress())
        return Result.success("")
    }

    override suspend fun startService(options: VpnOptions): Boolean {
        startCalls++
        startGate?.await()
        runtime = ServiceRuntime(options.enable, 1)
        return true
    }

    override suspend fun stopService() {
        stopCalls++
        stopGate?.await()
        if (stopFails) {
            if (clearOrdinaryFailure) runtime = null
            return
        }
        listener?.close()
        runtime = null
    }

    override fun close() {
        listener?.close()
        scope.cancel()
    }
}

class ManagedColdStartTest {
    @Test
    fun `a stale prepared start cannot clean a pending runtime owned by a newer intent`() = runBlocking {
        ColdStartHost().use { host ->
            host.managedBuild = true
            val machine = ServiceStateMachine(host)
            machine.syncSharedState(host.stored)
            assertTrue(machine.requestStart().await())
            val existing = host.runtime
            machine.syncSharedState(host.stored.copy(vpnOptions = host.stored.vpnOptions!!.copy(enable = false)))
            var newestPermission: ((Boolean) -> Unit)? = null
            var newestStart: kotlinx.coroutines.Deferred<Boolean>? = null
            val newestApp = object : AppGateway {
                override fun requestNotificationPermission(callback: (Boolean) -> Unit) { newestPermission = callback }
                override fun requestLocalNetworkPermission(callback: (Boolean) -> Unit) = callback(true)
                override fun prepareVpn(enable: Boolean, callback: (Boolean) -> Unit) = callback(true)
                override fun cancelVpnPreparation(callback: (Boolean) -> Unit) = Unit
            }
            host.permissionApp = object : AppGateway {
                override fun requestNotificationPermission(callback: (Boolean) -> Unit) = callback(true)
                override fun requestLocalNetworkPermission(callback: (Boolean) -> Unit) = callback(true)
                override fun prepareVpn(enable: Boolean, callback: (Boolean) -> Unit) {
                    host.confirmationPending = true
                    host.permissionApp = newestApp
                    newestStart = machine.requestStart()
                    callback(true)
                }
                override fun cancelVpnPreparation(callback: (Boolean) -> Unit) = Unit
            }
            assertFalse(machine.requestStart().await())
            assertEquals(0, host.stopCalls)
            assertEquals(existing, host.runtime)
            assertTrue(host.confirmationPending)
            newestPermission!!(true)
            assertTrue(newestStart!!.await())
        }
    }
    @Test
    fun `latest managed start survives a confirmed old stop and owns the next runtime`() = runBlocking {
        ColdStartHost().use { host ->
            host.managedBuild = true
            val machine = ServiceStateMachine(host)
            machine.syncSharedState(host.stored)
            assertTrue(machine.requestStart().await())
            host.stopGate = CompletableDeferred()
            val oldStop = machine.requestStop()
            val latestStart = machine.requestStart()
            host.stopGate!!.complete(Unit)
            assertFalse(oldStop.await())
            assertTrue(latestStart.await())
            assertTrue(machine.isRunRequested)
            assertTrue(host.runtime != null)
            assertEquals(2, host.startCalls)
            assertEquals(0, host.stopReports)
        }
    }
    @Test
    fun `managed closing window retains running VPN when an old permission prompt is denied`() = runBlocking {
        ColdStartHost().use { host ->
            host.managedBuild = true
            val machine = ServiceStateMachine(host)
            machine.syncSharedState(host.stored)
            assertTrue(machine.requestStart().await())
            val running = host.runtime
            var permission: ((Boolean) -> Unit)? = null
            host.permissionApp = object : AppGateway {
                override fun requestNotificationPermission(callback: (Boolean) -> Unit) { permission = callback }
                override fun requestLocalNetworkPermission(callback: (Boolean) -> Unit) = callback(true)
                override fun prepareVpn(enable: Boolean, callback: (Boolean) -> Unit) = callback(true)
                override fun cancelVpnPreparation(callback: (Boolean) -> Unit) = Unit
            }
            machine.syncSharedState(host.stored.copy(vpnOptions = host.stored.vpnOptions!!.copy(enable = false)))
            val oldStart = machine.requestStart()
            host.appClosing = true
            host.stopFails = true
            host.clearOrdinaryFailure = true
            assertFalse(host.confirmationPending)
            permission!!(false)
            assertFalse(oldStart.await())
            assertEquals(running, host.runtime)
            assertFalse(machine.isRunRequested)
            assertEquals(RunState.STOPPING, machine.runState.value)
            assertEquals(1L, machine.awaitRunTime())
            assertEquals(0, host.stopReports)
        }
    }
    @Test
    fun `closing blocks tile always-on and Flutter starts without changing settled run`() = runBlocking {
        ColdStartHost().use { host ->
            host.managedBuild = true
            val machine = ServiceStateMachine(host)
            machine.syncSharedState(host.stored)
            assertTrue(machine.requestStart().await())
            val runtime = host.runtime
            host.appClosing = true
            var tileStarts = 0
            host.gateway = TileGateway { tileStarts++ }
            machine.handleStartAction(userInitiated = true)
            assertFalse(machine.requestStart().await())
            assertEquals(0, tileStarts)
            assertEquals(runtime, host.runtime)
            assertTrue(machine.isRunRequested)
            assertTrue(machine.stopForExit())
            assertEquals(null, host.runtime)
            assertFalse(machine.isRunRequested)
        }
    }

    @Test
    fun `exit waits for native stop and refuses an unconfirmed runtime`() = runBlocking {
        ColdStartHost().use { host ->
            host.managedBuild = true
            val machine = ServiceStateMachine(host)
            machine.syncSharedState(host.stored)
            assertTrue(machine.requestStart().await())
            host.appClosing = true
            host.stopGate = CompletableDeferred()
            val stopping = host.scope.async { machine.stopForExit() }
            assertFalse(stopping.isCompleted)
            assertTrue(host.runtime != null)
            host.stopFails = true
            host.stopGate!!.complete(Unit)
            assertFalse(stopping.await())
            assertTrue(host.runtime != null)
            assertFalse(machine.isRunRequested)
            assertEquals(RunState.STOPPING, machine.runState.value)
            assertEquals(1L, machine.awaitRunTime())
            assertEquals(0, host.stopReports)
            host.appClosing = false
            assertFalse(machine.requestStart().await())
            machine.handleStopAction()
            machine.handleVpnRevokeAction()
            assertFalse(machine.isRunRequested)
            assertEquals(RunState.STOPPING, machine.runState.value)
            assertEquals(1L, machine.awaitRunTime())
            assertEquals(0, host.stopReports)
            host.stopFails = false
            machine.handleStopAction()
            assertEquals(null, host.runtime)
            assertEquals(1, host.stopReports)
            assertTrue(machine.requestStart().await())
        }
    }

    @Test
    fun `explicit exit closes idle core listeners even with no native runtime`() = runBlocking {
        ColdStartHost().use { host ->
            val machine = ServiceStateMachine(host)
            assertTrue(machine.stopForExit())
            assertEquals(1, host.stopCalls)
            assertEquals(null, host.runtime)
            assertFalse(machine.isRunRequested)
        }
    }

    @Test
    fun `closing stop waits for a pending start before confirming and revoke still settles`() = runBlocking {
        ColdStartHost().use { host ->
            host.managedBuild = true
            host.startGate = CompletableDeferred()
            val machine = ServiceStateMachine(host)
            machine.syncSharedState(host.stored)
            val start = machine.requestStart()
            host.appClosing = true
            val stopping = host.scope.async { machine.stopForExit() }
            host.startGate!!.complete(Unit)
            assertFalse(start.await())
            assertTrue(stopping.await())
            machine.handleVpnRevokeAction()
            assertEquals(null, host.runtime)
            assertFalse(machine.isRunRequested)
        }
    }
    @Test
    fun `managed saved configuration cannot open a listener without Flutter`() = runBlocking {
        ColdStartHost().use { host ->
            host.managedBuild = true
            val machine = ServiceStateMachine(host)
            machine.handleStartAction()
            assertEquals(0, host.setupCalls)
            assertEquals(0, host.loadCalls)
            assertEquals(0, host.startCalls)
            assertEquals(null, host.listener)
            assertEquals(listOf(false), host.verificationRequests)
            assertFalse(machine.isRunRequested)
            assertEquals(RunState.STOPPED, machine.runState.value)
        }
    }

    @Test
    fun `managed user gestures are sent to app verification without saving start intent`() = runBlocking {
        ColdStartHost().use { host ->
            host.managedBuild = true
            val machine = ServiceStateMachine(host)
            machine.handleStartAction(userInitiated = true)
            machine.handleToggleAction(userInitiated = true)
            assertEquals(listOf(true, true), host.verificationRequests)
            assertEquals(0, host.setupCalls)
            assertEquals(0, host.startCalls)
            assertEquals(0, host.loadCalls)
            assertFalse(machine.isRunRequested)
        }
    }

    @Test
    fun `a managed native runtime is retained after Flutter detaches`() = runBlocking {
        ColdStartHost().use { host ->
            host.managedBuild = true
            val running = ServiceRuntime(vpn = true, startedAtMillis = 7)
            host.runtime = running
            val machine = ServiceStateMachine(host)
            machine.handleStartAction()
            machine.handleStartAction(userInitiated = true)
            assertEquals(running, host.runtime)
            assertEquals(RunState.STARTED, machine.runState.value)
            assertEquals(0, host.setupCalls)
            assertEquals(0, host.startCalls)
            assertEquals(0, host.stopCalls)
            assertTrue(host.verificationRequests.isEmpty())
            machine.handleStopAction()
            assertEquals(1, host.stopCalls)
            assertEquals(RunState.STOPPED, machine.runState.value)
        }
    }

    @Test
    fun `a verified Flutter start is superseded by a later native stop`() = runBlocking {
        ColdStartHost().use { host ->
            host.managedBuild = true
            host.startGate = CompletableDeferred()
            val machine = ServiceStateMachine(host)
            machine.syncSharedState(host.stored)
            val start = machine.requestStart()
            val stop = machine.requestStop()
            host.startGate!!.complete(Unit)
            assertFalse(start.await())
            assertTrue(stop.await())
            assertEquals(null, host.runtime)
            assertFalse(machine.isRunRequested)
            assertEquals(RunState.STOPPED, machine.runState.value)
            assertTrue(host.verificationRequests.isEmpty())
        }
    }

    @Test
    fun `ordinary FlClash still starts its saved configuration`() = runBlocking {
        ColdStartHost().use { host ->
            val machine = ServiceStateMachine(host)
            machine.handleStartAction()
            assertEquals(1, host.setupCalls)
            assertEquals(1, host.startCalls)
            assertTrue(host.listener?.isBound == true)
            assertEquals(RunState.STARTED, machine.runState.value)
        }
    }

    @Test
    fun `an attached Flutter gateway owns a managed start`() = runBlocking {
        ColdStartHost().use { host ->
            host.managedBuild = true
            var starts = 0
            host.gateway = TileGateway { starts++ }
            ServiceStateMachine(host).handleStartAction()
            assertEquals(1, starts)
            assertEquals(0, host.setupCalls)
            assertEquals(0, host.startCalls)
            assertTrue(host.verificationRequests.isEmpty())
        }
    }

    @Test
    fun `managed active runs accept stop and revoke without reopening ports`() = runBlocking {
        ColdStartHost().use { host ->
            host.managedBuild = true
            val machine = ServiceStateMachine(host)
            machine.syncSharedState(host.stored)
            assertTrue(machine.requestStart().await())
            machine.handleStartAction()
            assertEquals(1, host.startCalls)
            assertEquals(0, host.setupCalls)
            machine.handleVpnRevokeAction()
            assertEquals(1, host.stopCalls)
            assertFalse(machine.isRunRequested)
            assertEquals(RunState.STOPPED, machine.runState.value)
        }
    }
}
