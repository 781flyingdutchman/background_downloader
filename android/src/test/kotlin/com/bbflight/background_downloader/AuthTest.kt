package com.bbflight.background_downloader

import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue

class AuthTest {

    private fun createAuth(
        accessToken: String? = null,
        accessHeaders: Map<String, String> = emptyMap(),
        accessQueryParams: Map<String, String> = emptyMap(),
        accessTokenExpiryTime: Long? = null,
        refreshToken: String? = null,
        refreshHeaders: Map<String, String> = emptyMap(),
        refreshQueryParams: Map<String, String> = emptyMap(),
        refreshUrl: String? = null,
        onAuthRawHandle: Long? = null
    ): Auth = Auth(
        accessToken = accessToken,
        accessHeaders = accessHeaders,
        accessQueryParams = accessQueryParams,
        accessTokenExpiryTime = accessTokenExpiryTime,
        refreshToken = refreshToken,
        refreshHeaders = refreshHeaders,
        refreshQueryParams = refreshQueryParams,
        refreshUrl = refreshUrl,
        onAuthRawHandle = onAuthRawHandle
    )

    @Test
    fun `getExpandedAccessHeaders replaces tokens correctly`() {
        val auth = createAuth(
            accessToken = "access123",
            refreshToken = "refresh123",
            accessHeaders = mapOf("Authorization" to "Bearer {accessToken}", "Refresh" to "{refreshToken}")
        )
        val expandedHeaders = auth.getExpandedAccessHeaders()
        assertEquals("Bearer access123", expandedHeaders["Authorization"])
        assertEquals("refresh123", expandedHeaders["Refresh"])
    }

    @Test
    fun `getExpandedAccessQueryParams replaces tokens correctly`() {
        val auth = createAuth(
            accessToken = "access456",
            refreshToken = "refresh456",
            accessQueryParams = mapOf("token" to "A {accessToken}", "refresh" to "A {refreshToken}")
        )
        val expandedParams = auth.getExpandedAccessQueryParams()
        assertEquals("A access456", expandedParams["token"])
        assertEquals("A refresh456", expandedParams["refresh"])
    }

    @Test
    fun `addOrUpdateQueryParams adds new query params to URL`() {
        // ignored because we would have to mock Uri.parse
//        val auth = createAuth()
//        val url = "https://example.com/api"
//        val queryParams = mapOf("param1" to "value1", "param2" to "value2")
//        val updatedUri = auth.addOrUpdateQueryParams(url, queryParams)
//        assertEquals("https://example.com/api?param1=value1&param2=value2", updatedUri.toString())
    }

    @Test
    fun `addOrUpdateQueryParams updates existing query params`() {
        // ignored because we would have to mock Uri.parse
//        val auth = createAuth()
//        val url = "https://example.com/api?param1=oldValue"
//        val queryParams = mapOf("param1" to "newValue")
//        val updatedUri = auth.addOrUpdateQueryParams(url, queryParams)
//        assertEquals("https://example.com/api?param1=newValue", updatedUri.toString())
    }

    @Test
    fun `isTokenExpired returns true when token is expired`() {
        val expiryTime = System.currentTimeMillis() - 10000  // Expired 10 seconds ago
        val auth = createAuth(accessTokenExpiryTime = expiryTime)
        assertTrue(auth.isTokenExpired())
    }

    @Test
    fun `isTokenExpired returns false when token is not expired`() {
        val expiryTime = System.currentTimeMillis() + 60000  // Expires in 1 minute
        val auth = createAuth(accessTokenExpiryTime = expiryTime)
        assertFalse(auth.isTokenExpired())
    }

    @Test
    fun `isTokenExpired applies buffer time correctly`() {
        val expiryTime = System.currentTimeMillis() + 5000  // Expires in 5 seconds
        val auth = createAuth(accessTokenExpiryTime = expiryTime)
        assertTrue(auth.isTokenExpired(bufferTime = 7000))  // Buffer time makes it appear expired
        assertFalse(auth.isTokenExpired(bufferTime = 3000)) // Within buffer, not expired
    }

    @Test
    fun `hasOnAuthCallback returns true when onAuthRawHandle is set`() {
        val auth = createAuth(onAuthRawHandle = 1234L)
        assertTrue(auth.hasOnAuthCallback())
    }

    @Test
    fun `hasOnAuthCallback returns false when onAuthRawHandle is not set`() {
        val auth = createAuth(onAuthRawHandle = null)
        assertFalse(auth.hasOnAuthCallback())
    }
}
