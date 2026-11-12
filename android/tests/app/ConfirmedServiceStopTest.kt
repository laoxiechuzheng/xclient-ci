package com.follow.clash

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ConfirmedServiceStopTest {
    @Test
    fun `failed owned stop does not request OS teardown or release real controller ownership`() = runBlocking {
        val calls = mutableListOf<String>()
        val stop = ConfirmedServiceStop(
            stopOwned = { calls += "owned"; false },
            requestServiceStop = { calls += "os"; true },
            release = { calls += "release" },
        )
        assertFalse(stop.stop())
        assertEquals(listOf("owned"), calls)
    }

    @Test
    fun `OS stop error preserves ownership after bound stop and can retry`() = runBlocking {
        val calls = mutableListOf<String>()
        var failOs = true
        val stop = ConfirmedServiceStop(
            stopOwned = { calls += "owned"; true },
            requestServiceStop = { calls += "os"; if (failOs) error("OS unavailable"); true },
            release = { calls += "release" },
        )
        assertFalse(stop.stop())
        assertEquals(listOf("owned", "os"), calls)
        failOs = false
        assertTrue(stop.stop())
        assertEquals(listOf("owned", "os", "owned", "os", "release"), calls)
    }

    @Test
    fun `binding error cannot become a bookkeeping success`() = runBlocking {
        var released = false
        val stop = ConfirmedServiceStop(
            stopOwned = { error("binding unavailable") },
            requestServiceStop = { true },
            release = { released = true },
        )
        assertFalse(stop.stop())
        assertFalse(released)
    }

    @Test
    fun `slow bound stop must finish before OS stop and runtime release`() = runBlocking {
        val gate = CompletableDeferred<Boolean>()
        val calls = mutableListOf<String>()
        val stop = ConfirmedServiceStop(
            stopOwned = { calls += "owned"; gate.await() },
            requestServiceStop = { calls += "os"; true },
            release = { calls += "release" },
        )
        val running = async { stop.stop() }
        kotlinx.coroutines.yield()
        assertEquals(listOf("owned"), calls)
        gate.complete(true)
        assertTrue(running.await())
        assertEquals(listOf("owned", "os", "release"), calls)
    }
}
