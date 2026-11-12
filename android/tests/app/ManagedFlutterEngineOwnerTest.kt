package com.follow.clash

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

private class EngineFixture {
    val events = mutableListOf<String>()
    val finished = mutableListOf<Any>()
    var created = 0
    var destroyed = 0
    var reopened = 0
    val owner = ManagedEngineLifecycle(
        create = { created++; Any().also { events += "create" } },
        destroy = { destroyed++; events += "destroy" },
        finishHost = { finished += it; events += "finish" },
        reopen = { reopened++; events += "reopen" },
    )
}

class ManagedFlutterEngineOwnerTest {
    @Test
    fun `queued release keeps the old generation until all borrowed hosts detach`() {
        val queued = mutableListOf<() -> Unit>()
        var destroyed = 0
        val owner = ManagedEngineLifecycle(
            create = { Any() },
            destroy = { destroyed++ },
            finishHost = {},
            reopen = {},
            deferRelease = { queued += it },
        )
        val first = Any()
        val lease = owner.acquire(first)
        owner.beginExit()
        owner.completeExit(lease.generation)
        owner.hostDestroyed(first)
        assertEquals(0, destroyed)
        assertTrue(owner.isClosing)
        val late = Any()
        assertSame(lease.engine, owner.acquire(late).engine)
        queued.removeAt(0).invoke()
        assertEquals(0, destroyed)
        owner.hostDestroyed(late)
        queued.removeAt(0).invoke()
        assertEquals(1, destroyed)
        assertFalse(owner.isClosing)
    }
    @Test
    fun `activity recreation reuses one engine and registration`() {
        val fixture = EngineFixture()
        val firstHost = Any()
        val first = fixture.owner.acquire(firstHost)
        fixture.owner.hostDestroyed(firstHost)
        val second = fixture.owner.acquire(Any())
        assertSame(first.engine, second.engine)
        assertEquals(first.generation, second.generation)
        assertEquals(1, fixture.created)
        assertEquals(0, fixture.destroyed)
        assertTrue(fixture.owner.hasInteractiveActivity)
    }

    @Test
    fun `late old host destroy does not erase newer host`() {
        val fixture = EngineFixture()
        val oldHost = Any()
        val newHost = Any()
        fixture.owner.acquire(oldHost)
        fixture.owner.acquire(newHost)
        fixture.owner.hostDetached(oldHost)
        assertTrue(fixture.owner.hasInteractiveActivity)
        fixture.owner.hostDestroyed(oldHost)
        assertTrue(fixture.owner.hasInteractiveActivity)
        fixture.owner.hostDestroyed(newHost)
        assertFalse(fixture.owner.hasInteractiveActivity)
        assertEquals(0, fixture.destroyed)
    }

    @Test
    fun `detached view keeps a lease until real activity destruction`() {
        val fixture = EngineFixture()
        val host = Any()
        val lease = fixture.owner.acquire(host)
        fixture.owner.hostDetached(host)
        assertFalse(fixture.owner.hasInteractiveActivity)
        fixture.owner.beginExit()
        fixture.owner.completeExit(lease.generation)
        assertEquals(0, fixture.destroyed)
        fixture.owner.hostDestroyed(host)
        assertEquals(1, fixture.destroyed)
    }

    @Test
    fun `no activity keeps engine but cannot act as interactive tile`() {
        val fixture = EngineFixture()
        val host = Any()
        val lease = fixture.owner.acquire(host)
        fixture.owner.hostDestroyed(host)
        assertSame(lease.engine, fixture.owner.engine)
        assertFalse(fixture.owner.hasInteractiveActivity)
        assertFalse(fixture.owner.isClosing)
    }

    @Test
    fun `same host acquire is idempotent`() {
        val fixture = EngineFixture()
        val host = Any()
        assertSame(fixture.owner.acquire(host), fixture.owner.acquire(host))
        assertEquals(1, fixture.created)
    }

    @Test
    fun `close waits for all normal and closing host destruction`() {
        val fixture = EngineFixture()
        val normal = Any()
        val closingOne = Any()
        val closingTwo = Any()
        val initial = fixture.owner.acquire(normal)
        assertEquals(initial.generation, fixture.owner.beginExit())
        val one = fixture.owner.acquire(closingOne)
        val two = fixture.owner.acquire(closingTwo)
        assertSame(initial.engine, one.engine)
        assertSame(initial.engine, two.engine)
        assertTrue(one.closingHost)
        assertTrue(two.closingHost)
        assertFalse(fixture.owner.hasInteractiveActivity)
        assertTrue(fixture.owner.completeExit(initial.generation))
        assertEquals(3, fixture.finished.size)
        fixture.owner.hostDestroyed(normal)
        fixture.owner.hostDestroyed(closingOne)
        assertEquals(0, fixture.destroyed)
        fixture.owner.hostDestroyed(closingTwo)
        assertEquals(1, fixture.destroyed)
        assertEquals(1, fixture.reopened)
        assertEquals(listOf("destroy", "reopen"), fixture.events.takeLast(2))
        val fresh = fixture.owner.acquire(Any())
        assertNotSame(initial.engine, fresh.engine)
        assertTrue(fresh.generation > initial.generation)
        assertFalse(fresh.closingHost)
    }

    @Test
    fun `duplicate exit and stale completion cannot release a fresh engine`() {
        val fixture = EngineFixture()
        val host = Any()
        val first = fixture.owner.acquire(host)
        assertEquals(fixture.owner.beginExit(), fixture.owner.beginExit())
        assertFalse(fixture.owner.completeExit(first.generation + 1))
        assertTrue(fixture.owner.completeExit(first.generation))
        fixture.owner.hostDestroyed(host)
        val fresh = fixture.owner.acquire(Any())
        assertFalse(fixture.owner.completeExit(first.generation))
        assertSame(fresh.engine, fixture.owner.engine)
        assertEquals(1, fixture.destroyed)
    }

    @Test
    fun `late closing host is finished without attaching terminal engine`() {
        val fixture = EngineFixture()
        val host = Any()
        val lease = fixture.owner.acquire(host)
        fixture.owner.beginExit()
        fixture.owner.completeExit(lease.generation)
        val late = Any()
        assertTrue(fixture.owner.acquire(late).closingHost)
        assertTrue(fixture.finished.contains(late))
        fixture.owner.hostDestroyed(host)
        assertEquals(0, fixture.destroyed)
        fixture.owner.hostDestroyed(late)
        assertEquals(1, fixture.destroyed)
        assertEquals(1, fixture.reopened)
    }

    @Test
    fun `stop failure aborts closing shells and reopens same live engine once`() {
        val fixture = EngineFixture()
        val oldHost = Any()
        val lease = fixture.owner.acquire(oldHost)
        fixture.owner.beginExit()
        val shellOne = Any()
        val shellTwo = Any()
        fixture.owner.acquire(shellOne)
        fixture.owner.acquire(shellTwo)
        fixture.owner.hostDestroyed(oldHost)
        assertTrue(fixture.owner.abortExit(lease.generation))
        assertFalse(fixture.owner.isClosing)
        assertEquals(listOf(shellOne, shellTwo), fixture.finished)
        assertEquals(0, fixture.reopened)
        fixture.owner.hostDestroyed(shellOne)
        assertEquals(0, fixture.reopened)
        fixture.owner.hostDestroyed(shellTwo)
        assertEquals(1, fixture.reopened)
        assertSame(lease.engine, fixture.owner.acquire(Any()).engine)
        assertEquals(0, fixture.destroyed)
        assertEquals(1, fixture.created)
    }

    @Test
    fun `terminal exit cannot abort back to a live session`() {
        val fixture = EngineFixture()
        val lease = fixture.owner.acquire(Any())
        fixture.owner.beginExit()
        fixture.owner.completeExit(lease.generation)
        assertFalse(fixture.owner.abortExit(lease.generation))
        assertTrue(fixture.owner.isClosing)
        assertFalse(fixture.owner.hasInteractiveActivity)
    }

    @Test
    fun `new intent during close queues one reopen without another engine`() {
        val fixture = EngineFixture()
        val host = Any()
        val lease = fixture.owner.acquire(host)
        fixture.owner.beginExit()
        fixture.owner.queueReopen()
        fixture.owner.queueReopen()
        fixture.owner.completeExit(lease.generation)
        fixture.owner.hostDestroyed(host)
        assertEquals(1, fixture.reopened)
        assertEquals(1, fixture.created)
    }

    @Test
    fun `explicit close with no host destroys immediately without reopening`() {
        val fixture = EngineFixture()
        val host = Any()
        val lease = fixture.owner.acquire(host)
        fixture.owner.hostDestroyed(host)
        fixture.owner.beginExit()
        assertTrue(fixture.owner.completeExit(lease.generation))
        assertEquals(1, fixture.destroyed)
        assertEquals(0, fixture.reopened)
        fixture.owner.hostDestroyed(host)
        assertEquals(1, fixture.destroyed)
    }

    @Test
    fun `abort without a new launch keeps original activity and engine`() {
        val fixture = EngineFixture()
        val lease = fixture.owner.acquire(Any())
        fixture.owner.beginExit()
        assertTrue(fixture.owner.abortExit(lease.generation))
        assertTrue(fixture.owner.hasInteractiveActivity)
        assertSame(lease.engine, fixture.owner.engine)
        assertTrue(fixture.finished.isEmpty())
        assertEquals(0, fixture.reopened)
    }
}
