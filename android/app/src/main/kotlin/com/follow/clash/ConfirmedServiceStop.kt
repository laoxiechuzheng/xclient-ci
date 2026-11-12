package com.follow.clash

import kotlinx.coroutines.CancellationException

internal class ConfirmedServiceStop(
    private val stopOwned: suspend () -> Boolean,
    private val requestServiceStop: () -> Boolean,
    private val release: () -> Unit,
) {
    suspend fun stop(): Boolean = try {
        if (!stopOwned() || !requestServiceStop()) false
        else {
            release()
            true
        }
    } catch (error: CancellationException) {
        throw error
    } catch (_: Exception) {
        false
    }
}
