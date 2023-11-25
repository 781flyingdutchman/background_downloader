package com.bbflight.background_downloader

//val urlWithContentLength = "https://storage.googleapis.com/approachcharts/test/5MB-test.ZIP"
//var task =  Task(mapOf("url" to urlWithContentLength, "filename" to "taskFilename.txt"))
//
//
//class HelpersTest {
//
//    @Test
//    fun parseRange() {
//        assertEquals(Pair(10L, 20L), parseRange("bytes=10-20"))
//        assertEquals(Pair(0L, 20L), parseRange("bytes=-20"))
//        assertEquals(Pair(10L, null), parseRange("bytes=10-"))
//        assertEquals(Pair(0L, null), parseRange(""))
//    }
//
//    @Test
//    fun getContentLength() {
//        var h = mapOf<String, List<String>>()
//        assertEquals(-1, getContentLength(h, task))
//        h = mapOf("Content-Length" to listOf("123"))
//        assertEquals(123, getContentLength(h, task))
//        h = mapOf("content-length" to listOf("123"))
//        assertEquals(123, getContentLength(h, task))
//        task = task.copyWith(headers = mapOf("Range" to "bytes=0-20"))
//        h = mapOf()
//        assertEquals(21, getContentLength(h, task))
//        task = task.copyWith(headers = mapOf("Known-Content-Length" to "456"))
//        assertEquals(456, getContentLength(h, task))
//        task = task.copyWith(headers = mapOf("Known-Content-Length" to "456", "Range" to "bytes=0-20"))
//        assertEquals(21, getContentLength(h, task))
//        h = mapOf("Content-Length" to listOf("123"))
//        assertEquals(123, getContentLength(h, task))
//    }
//}
