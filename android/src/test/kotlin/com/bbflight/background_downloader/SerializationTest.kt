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
        var enc = Json.encodeToString(Holder(BaseDirectory.applicationDocuments))
        assertEquals("{\"dir\":0}", enc)
        enc = Json.encodeToString(Holder(BaseDirectory.applicationLibrary))
        assertEquals("{\"dir\":3}", enc)
        val dec = Json.decodeFromString<Holder>(enc)
        assertEquals(BaseDirectory.applicationLibrary, dec.dir)
    }

}
