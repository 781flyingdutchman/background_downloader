package com.bbflight.background_downloader

import org.junit.Test
import org.junit.Assert.assertEquals

class HelpersTest {

    @Test
    fun parseRangeTest() {
        assertEquals(parseRange("bytes=10-20"), Pair(10L, 20L))
        assertEquals(parseRange("bytes=-20"), Pair(0L, 20L))
        assertEquals(parseRange("bytes=10-"), Pair(10L, null))
        assertEquals(parseRange(""), Pair(0L, null))
    }
}