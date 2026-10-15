package com.bbflight.background_downloader

import org.junit.Assert.assertEquals
import org.junit.Test

class ReRunDecisionTest {

    @Test
    fun firstRunRuns() {
        assertEquals(ReRunDecision.run, reRunDecision(0, true, emptyList()))
        // also when its task left the tasks map, or another work exists
        assertEquals(ReRunDecision.run, reRunDecision(0, false, emptyList()))
        assertEquals(ReRunDecision.run, reRunDecision(0, true, listOf("other")))
    }

    @Test
    fun reRunOfUnfinishedTaskRuns() {
        assertEquals(ReRunDecision.run, reRunDecision(1, true, emptyList()))
        assertEquals(ReRunDecision.run, reRunDecision(3, true, emptyList()))
    }

    @Test
    fun reRunOfFinishedTaskIsSkipped() {
        assertEquals(ReRunDecision.skipFinished, reRunDecision(1, false, emptyList()))
    }

    @Test
    fun reRunWithAnotherUnfinishedWorkIsSkipped() {
        assertEquals(ReRunDecision.skipSuperseded, reRunDecision(1, true, listOf("other")))
        // the other work holds the slot, so superseded wins over finished
        assertEquals(ReRunDecision.skipSuperseded, reRunDecision(2, false, listOf("other")))
    }
}
