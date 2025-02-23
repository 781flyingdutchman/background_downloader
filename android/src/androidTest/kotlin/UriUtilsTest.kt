import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.bbflight.background_downloader.UriUtils
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class UriUtilsTest {

    @Test
    fun pack_should_pack_filename_and_uri_into_a_single_string() {
        val filename = "myFile.txt"
        val uri = Uri.parse("content://com.example.app/document/123")

        val packedString = UriUtils.pack(filename, uri)

        assertEquals(":::$filename::::::$uri:::", packedString)
    }

    @Test
    fun unpack_should_unpack_a_valid_packed_string_into_filename_and_uri() {
        val filename = "myFile.txt"
        val uri = Uri.parse("content://com.example.app/document/123")
        val packedString = ":::$filename::::::$uri:::"

        val (unpackedFilename, unpackedUri) = UriUtils.unpack(packedString)

        assertEquals(filename, unpackedFilename)
        assertEquals(uri, unpackedUri)
    }

    @Test
    fun unpack_should_return_original_string_and_null_uri_for_simple_filename_string() {
        val invalidPackedString = "This is not a packed string"

        val (filename, uri) = UriUtils.unpack(invalidPackedString)

        assertEquals(invalidPackedString, filename)
        assertNull(uri)
    }

    @Test
    fun unpack_should_return_null_and_uri_for_simple_uri_string() {
        val uriString = "https://www.example.com/path/to/resource"

        val (filename, uri) = UriUtils.unpack(uriString)

        assertNull(filename)
        assertEquals(uri.toString(), uriString)
    }

    @Test
    fun uriFromStringValue_should_return_Uri_for_a_valid_Uri_string() {
        val uriString = "https://www.example.com/path/to/resource"
        val expectedUri = Uri.parse(uriString)

        val resultUri = UriUtils.uriFromStringValue(uriString)

        assertEquals(expectedUri, resultUri)
    }

    @Test
    fun uriFromStringValue_should_return_Uri_from_a_valid_packed_string() {
        val filename = "myFile.txt"
        val uri = Uri.parse("content://com.example.app/document/123")
        val packedString = UriUtils.pack(filename, uri)

        val resultUri = UriUtils.uriFromStringValue(packedString)

        assertEquals(uri, resultUri)
    }

    @Test
    fun uriFromStringValue_should_return_null_for_an_invalid_string() {
        val invalidString = "This is not a Uri or packed string"

        val resultUri = UriUtils.uriFromStringValue(invalidString)

        assertNull(resultUri)
    }

    @Test
    fun uriFromStringValue_should_return_null_for_a_packed_string_with_invalid_Uri() {
        val filename = "myFile.txt"
        val invalidUri = "invalid"
        val packedString = ":::$filename::::::$invalidUri:::"

        val resultUri = UriUtils.uriFromStringValue(packedString)

        assertNull(resultUri)
    }

    @Test
    fun containsUri_should_return_true_for_a_valid_Uri_string() {
        val uriString = "https://www.example.com/path/to/resource"
        assertTrue(UriUtils.containsUri(uriString))
    }

    @Test
    fun containsUri_should_return_true_for_a_valid_packed_Uri_string() {
        val filename = "myFile.txt"
        val uri = Uri.parse("content://com.example.app/document/123")
        val packedString = UriUtils.pack(filename, uri)

        assertTrue(UriUtils.containsUri(packedString))
    }

    @Test
    fun containsUri_should_return_false_for_an_invalid_string() {
        val invalidString = "This is not a Uri or packed string"

        assertFalse(UriUtils.containsUri(invalidString))
    }
}