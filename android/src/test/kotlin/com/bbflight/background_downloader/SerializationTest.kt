package com.bbflight.background_downloader

import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Test

@Serializable
data class Holder(val dir: BaseDirectory)


class SerializationTest {

    @Test
    fun encodeEnum() {
        var enc = bdJson.encodeToString(Holder(BaseDirectory.applicationDocuments))
        assertEquals("{\"dir\":0}", enc)
        enc = bdJson.encodeToString(Holder(BaseDirectory.applicationLibrary))
        assertEquals("{\"dir\":3}", enc)
        val dec = bdJson.decodeFromString<Holder>(enc)
        assertEquals(BaseDirectory.applicationLibrary, dec.dir)
    }

    @Test
    fun ignoreUnknownKeysTest() {
        val jsonWithUnknownKeys = "{\"dir\":0,\"unknownField\":123,\"anotherUnknown\":\"xyz\"}"
        val dec = bdJson.decodeFromString<Holder>(jsonWithUnknownKeys)
        assertEquals(BaseDirectory.applicationDocuments, dec.dir)
    }

}
