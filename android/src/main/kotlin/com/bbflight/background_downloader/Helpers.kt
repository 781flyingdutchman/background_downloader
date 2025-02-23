package com.bbflight.background_downloader

import android.annotation.SuppressLint
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.StatFs
import android.util.Log
import androidx.core.content.FileProvider.getUriForFile
import androidx.preference.PreferenceManager
import com.bbflight.background_downloader.TaskWorker.Companion.TAG
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CompletableDeferred
import java.io.File
import java.net.URLDecoder
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager
import kotlin.io.path.Path
import kotlin.io.path.pathString


/**
 * Installs a custom X509 TrustManager that accepts all certificates. Future
 * HTTPS calls will therefore not check the validity of the TLS certificate.
 *
 * DO NOT CONFIGURE THE DOWNLOADER TO BYPASS CERTIFICATE VALIDATION IN RELEASE
 */
fun acceptUntrustedCertificates() {
    try {
        // Create a trust manager that does not validate certificate chains
        val trustAllCerts = arrayOf<TrustManager>(
            @SuppressLint("CustomX509TrustManager")
            object : X509TrustManager {
                @SuppressLint("TrustAllX509TrustManager")
                override fun checkClientTrusted(
                    chain: Array<java.security.cert.X509Certificate>,
                    authType: String
                ) {
                }

                @SuppressLint("TrustAllX509TrustManager")
                override fun checkServerTrusted(
                    chain: Array<java.security.cert.X509Certificate>,
                    authType: String
                ) {
                }

                override fun getAcceptedIssuers(): Array<java.security.cert.X509Certificate> {
                    return arrayOf()
                }
            })

        // Install the all-trusting trust manager
        val sslContext = SSLContext.getInstance("TLS")
        sslContext.init(null, trustAllCerts, java.security.SecureRandom())
        // Create an ssl socket factory with our all-trusting manager
        HttpsURLConnection.setDefaultSSLSocketFactory(sslContext.socketFactory)
        Log.w(
            BDPlugin.TAG, "Bypassing TLS certificate validation\n" +
                    "HTTPS calls will NOT check the validity of the TLS certificate."
        )
    } catch (e: Exception) {
        throw RuntimeException(e)
    }
}

/**
 * Returns true if there is insufficient space to store a file of length
 * [contentLength]
 *
 * Returns false if [contentLength] <= 0
 * Returns false if configCheckAvailableSpace has not been set, or if available
 * space is greater than that setting
 * Returns true otherwise
 */
fun insufficientSpace(applicationContext: Context, contentLength: Long): Boolean {
    if (contentLength <= 0) {
        return false
    }
    val checkValue = PreferenceManager.getDefaultSharedPreferences(applicationContext)
        .getInt(BDPlugin.keyConfigCheckAvailableSpace, 0)
    if (checkValue <= 0) {
        return false
    }
    val path = Environment.getDataDirectory()
    val stat = StatFs(path.path)
    val available = stat.blockSizeLong * stat.availableBlocksLong
    return available - (BDPlugin.remainingBytesToDownload.values.sum()
            + contentLength) < (checkValue.toLong() shl 20)
}

/**
 * Parses the range in a Range header, and returns a Pair representing
 * the range. The format needs to be "bytes=10-20"
 *
 * A missing lower range is substituted with 0L, and a missing upper
 * range with null.  If the string cannot be parsed, returns (0L, null)
 */
fun parseRange(rangeStr: String): Pair<Long, Long?> {
    val regex = Regex("""bytes=(\d*)-(\d*)""")
    val match = regex.find(rangeStr) ?: return Pair(0, null)
    val start = match.groupValues[1].toLongOrNull() ?: 0L
    val end = match.groupValues[2].toLongOrNull()
    return Pair(start, end)
}

/**
 * Returns the content length extracted from the [responseHeaders], or from
 * the [task] headers
 */
fun getContentLength(responseHeaders: Map<String, List<String>>, task: Task): Long {
    // if response provides contentLength, return it
    val contentLength = responseHeaders["Content-Length"]?.get(0)?.toLongOrNull()
        ?: responseHeaders["content-length"]?.get(0)?.toLongOrNull()
        ?: -1L
    if (contentLength != -1L) {
        return contentLength
    }
    // try extracting it from Range header
    val taskRangeHeader = task.headers["Range"] ?: task.headers["range"] ?: ""
    val taskRange = parseRange(taskRangeHeader)
    if (taskRange.second != null) {
        val rangeLength = taskRange.second!! - taskRange.first + 1L
        Log.d(TAG, "TaskId ${task.taskId} contentLength set to $rangeLength based on Range header")
        return rangeLength
    }
    // try extracting it from a special "Known-Content-Length" header
    val knownLength = (task.headers["Known-Content-Length"]?.toLongOrNull()
        ?: task.headers["known-content-length"]?.toLongOrNull()
        ?: -1)
    if (knownLength != -1L) {
        Log.d(
            TAG,
            "TaskId ${task.taskId} contentLength set to $knownLength based on Known-Content-Length header"
        )
    } else {
        Log.d(TAG, "TaskId ${task.taskId} contentLength undetermined")
    }
    return knownLength
}


/**
 * Return the path to the baseDir for this [baseDirectory], or null if path could not be reached
 *
 * Null only happens if external storage is requested but not available
 */
fun baseDirPath(context: Context, baseDirectory: BaseDirectory): String? {
    val useExternalStorage = PreferenceManager.getDefaultSharedPreferences(context)
        .getInt(BDPlugin.keyConfigUseExternalStorage, -1) == 0
    val baseDirPath: String
    if (!useExternalStorage) {
        if (Build.VERSION.SDK_INT >= 26) {
            baseDirPath = when (baseDirectory) {
                BaseDirectory.applicationDocuments -> Path(
                    context.dataDir.path, "app_flutter"
                ).pathString

                BaseDirectory.temporary -> context.cacheDir.path
                BaseDirectory.applicationSupport -> context.filesDir.path
                BaseDirectory.applicationLibrary -> Path(
                    context.filesDir.path, "Library"
                ).pathString

                BaseDirectory.root -> ""
            }
        } else {
            baseDirPath = when (baseDirectory) {
                BaseDirectory.applicationDocuments -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    "${context.dataDir.path}/app_flutter"
                } else {
                    "${context.applicationInfo.dataDir}/app_flutter"
                }

                BaseDirectory.temporary -> context.cacheDir.path
                BaseDirectory.applicationSupport -> context.filesDir.path
                BaseDirectory.applicationLibrary -> "${context.filesDir.path}/Library"
                BaseDirectory.root -> ""
            }
        }
    } else {
        // external storage variant
        val externalStorageDirectory = context.getExternalFilesDir(null)
        val externalCacheDirectory = context.externalCacheDir
        if (externalStorageDirectory == null || externalCacheDirectory == null) {
            Log.e(TAG, "Could not access external storage")
            return null
        }
        baseDirPath = when (baseDirectory) {
            BaseDirectory.applicationDocuments -> externalStorageDirectory.path
            BaseDirectory.temporary -> externalCacheDirectory.path
            BaseDirectory.applicationSupport -> "${externalStorageDirectory.path}/Support"
            BaseDirectory.applicationLibrary -> "${externalStorageDirectory.path}/Library"
            BaseDirectory.root -> ""
        }
    }
    return baseDirPath
}

fun getBasenameWithoutExtension(file: File): String {
    val fileName = file.name
    val extension = file.extension
    return fileName.substringBeforeLast(".$extension")
}

/**
 * Returns the Uri for the given [filePath], or null if not allowed/possible
 */
fun getUriFromFilePath(context: Context, filePath: String): String? {
    try {
        val contentUri = getUriForFile(
            context,
            context.packageName + ".com.bbflight.background_downloader.fileprovider",
            File(filePath)
        )
        return contentUri.toString()
    } catch (e: Exception) {
        Log.i(BDPlugin.TAG, "Failed to get Uri for file $filePath: $e")
        return null
    }
}

/**
 * Suggests a filename based on response headers and a URL. If none can be derived, returns ""
 *
 * @param responseHeaders The response headers map.
 * @param url             The URL the file would be downloaded from.
 * @return A suggested filename, derived from the headers or the URL.
 */
fun suggestFilename(responseHeaders: Map<String, List<String>>, url: String): String {
    try {
        val disposition = (responseHeaders["Content-Disposition"]
            ?: responseHeaders["content-disposition"])?.get(0)
        if (disposition != null) {
            // Try filename*=UTF-8'language'"encodedFilename"
            val encodedFilenameRegEx =
                Regex("""filename\*=\s*([^']+)'([^']*)'"?([^"]+)"?""", RegexOption.IGNORE_CASE)
            var match = encodedFilenameRegEx.find(disposition)
            if (match != null && match.groupValues[1].isNotEmpty() && match.groupValues[3].isNotEmpty()) {
                try {
                    val suggestedFilename = if (match.groupValues[1].uppercase() == "UTF-8") {
                        URLDecoder.decode(match.groupValues[3], "UTF-8")
                    } else {
                        match.groupValues[3]
                    }
                    return suggestedFilename
                } catch (_: IllegalArgumentException) {
                    Log.d(
                        TAG,
                        "Could not interpret suggested filename (UTF-8 url encoded) ${match.groupValues[3]}"
                    )
                }
            }
            // Try filename="filename"
            val plainFilenameRegEx =
                Regex("""filename=\s*"?([^"]+)"?.*$""", RegexOption.IGNORE_CASE)
            match = plainFilenameRegEx.find(disposition)
            if (match != null && match.groupValues[1].isNotEmpty()) {
                return match.groupValues[1]
            }
        }
    } catch (_: Throwable) {
    }
    // Try filename derived from last path segment of the url
    try {
        val uri = Uri.parse(url)
        return getFilenameFromUri(uri)
    } catch (_: Throwable) {
    }
    return "" // Default fallback
}

/**
 * Returns the filename from the given [uri]
 *
 * Returns "" if not possible
 *
 * Slightly modified from lastPathSegment to account for possible subdirs in that last segment
 * (e.g. '/primary:Documents/dog-drawing.jpg' will have 'Documents/dog-drawing.jpg' as last path
 * segment, not 'dog-drawing.jpg')
 */
fun getFilenameFromUri(uri: Uri): String {
    val lastPathSegment = uri.lastPathSegment
    if (lastPathSegment != null) {
        val lastSlashIndex = lastPathSegment.lastIndexOf("/")
        val filename =
            if (lastSlashIndex != -1) lastPathSegment.substring(lastSlashIndex + 1) else lastPathSegment
        return filename
    }
    return ""
}

// Helper extension to filter out null values from Maps
fun <K, V> Map<K, V>?.filterNotNull(): Map<K, V> {
    return this?.filter { (key, value) -> key != null && value != null } ?: emptyMap()
}

/**
 * Simple Flutter result handler, completes the [completer] with true if the result of the
 * method call is true, and false otherwise
 */
class FlutterBooleanResultHandler(private val completer: CompletableDeferred<Boolean>) :
    MethodChannel.Result {

    override fun success(result: Any?) {
        completer.complete(result == true)
    }

    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
        Log.i(BDPlugin.TAG, "Flutter result error $errorCode: $errorMessage")
        completer.complete(false)
    }

    override fun notImplemented() {
        Log.i(BDPlugin.TAG, "Flutter method not implemented")
        completer.complete(false)
    }
}

/**
 * Flutter result handler, completes the [completer] with the result of the method call
 */
class FlutterResultHandler<T>(private val completer: CompletableDeferred<T?>) :
    MethodChannel.Result {

    override fun success(result: Any?) {
        @Suppress("UNCHECKED_CAST")
        val castedResult = result as? T?
        completer.complete(castedResult)
    }

    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
        Log.i(BDPlugin.TAG, "Flutter result error $errorCode: $errorMessage")
        completer.complete(null)
    }

    override fun notImplemented() {
        Log.i(BDPlugin.TAG, "Flutter method not implemented")
        completer.complete(null)
    }
}
