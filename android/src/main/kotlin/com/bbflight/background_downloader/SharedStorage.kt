package com.bbflight.background_downloader

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import android.webkit.MimeTypeMap
import androidx.annotation.RequiresApi
import androidx.loader.content.CursorLoader
import java.io.File
import java.io.FileInputStream
import java.io.OutputStream

/// Scoped Storage destinations for Android
@Suppress("EnumEntryName")
enum class SharedStorage { downloads, images, video, audio, files, external }

val leadingPathSeparatorRegEx = Regex("""^/+""")
val trailingPathSeparatorRegEx = Regex("""/$""")

/**
 * Moves the file from filePath to the shared storage destination and returns the path to
 * that file if successful, or null if not
 *
 * If successful, the original file will have been deleted
 */
fun moveToSharedStorage(
    context: Context,
    filePath: String,
    destination: SharedStorage,
    directory: String,
    mimeType: String?
): String? {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
        return moveToPublicDirectory(filePath, destination, directory)
    }
    val file = File(filePath)
    if (!file.exists()) {
        Log.i(
            BDPlugin.TAG,
            "File $filePath does not exist -> cannot move to shared storage"
        )
        return null
    }
    val cleanDirectory =
        trailingPathSeparatorRegEx.replace(leadingPathSeparatorRegEx.replace(directory, ""), "")
    // Set up the content values for the new file
    val contentValues = ContentValues().apply {
        put(MediaStore.MediaColumns.DISPLAY_NAME, file.name)
        put(MediaStore.MediaColumns.MIME_TYPE, mimeType ?: getMimeType(file.name))
        put(MediaStore.MediaColumns.RELATIVE_PATH, getRelativePath(destination, cleanDirectory))
        put(MediaStore.MediaColumns.IS_PENDING, 1)
    }
    var success = false
    // Insert the new file into the MediaStore
    val resolver = context.contentResolver
    val uri = try {
        resolver.insert(getMediaStoreUri(destination), contentValues)
    } catch (e: Exception) {
        Log.i(BDPlugin.TAG, "Cannot insert $filePath in MediaStore: $e")
        return null
    }
    if (uri != null) {
        try {
            // Get an OutputStream and write the contents of the file
            val os: OutputStream? = uri.let { resolver.openOutputStream(it) }
            if (os != null) {
                os.use { output ->
                    FileInputStream(file).use { input ->
                        input.copyTo(output)
                    }
                }
                success = true
            }
        } catch (e: Exception) {
            Log.i(
                BDPlugin.TAG,
                "Error moving file $filePath to shared storage: $e"
            )
        } finally {
            contentValues.clear()
            contentValues.put(MediaStore.MediaColumns.IS_PENDING, 0)
            resolver.update(uri, contentValues, null, null)
        }
    }
    // If the file was moved successfully, remove the original
    if (success) {
        file.delete()
    }
    return if (success) pathFromUri(context, uri!!) else null
}

/**
 * Moves the file from filePath to the shared storage destination and returns the path to
 * that file if successful, or null if not
 *
 * If successful, the original file will have been deleted
 *
 * This implementation is for Android versions before Q and requires app permissions
 * READ_EXTERNAL_STORAGE and WRITE_EXTERNAL_STORAGE
 */
private fun moveToPublicDirectory(
    filePath: String, destination: SharedStorage, directory: String
): String? {
    try {
        val file = File(filePath)
        if (!file.exists()) {
            Log.i(
                BDPlugin.TAG,
                "File $filePath does not exist -> cannot move to public directory"
            )
            return null
        }

        val destinationMediaPath = getMediaStorePathBelowQ(destination)
        val rootDir = Environment.getExternalStoragePublicDirectory(destinationMediaPath)
        val destDir = File(rootDir, directory)
        if (!destDir.exists()) {
            destDir.mkdirs()
        }
        // try to get a new file name if already exist
        val maxCheck = 100
        var currentCheck = 1
        var destinationFile = File(destDir, file.name)
        val fileName = file.nameWithoutExtension
        val fileHasExtension = file.name.contains(".")
        val fileExtension = if (fileHasExtension) ".${file.extension}" else ""
        while (destinationFile.exists() && currentCheck < maxCheck) {
            destinationFile = File(destDir, "${fileName}_$currentCheck$fileExtension")
            currentCheck++
        }
        if (destinationFile.exists()) throw Exception("Destination file exist!")

        // copy file
        destinationFile.outputStream().use { output ->
            FileInputStream(file).use { input ->
                input.copyTo(output)
            }
        }
        file.delete()
        return destinationFile.absolutePath
    } catch (e: Exception) {
        Log.i(
            BDPlugin.TAG,
            "Unable to move file $filePath to public directory: $e"
        )
        return null
    }
}

/**
 * Returns the path to the file in shared storage, or null
 */
fun pathInSharedStorage(
    context: Context,
    filePath: String,
    destination: SharedStorage,
    directory: String
): String? {
    val fileName = File(filePath).name
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
        val destinationMediaPath = getMediaStorePathBelowQ(destination)
        val rootDir = Environment.getExternalStoragePublicDirectory(destinationMediaPath)
        val destDir = File(rootDir, directory)
        val destinationFile = File(destDir, fileName)
        return destinationFile.path
    }
    // Version above Q uses MediaStore
    context.contentResolver.query(
        getMediaStoreUri(destination),
        arrayOf(
            MediaStore.Images.Media.DATA,
            MediaStore.MediaColumns.DISPLAY_NAME
        ), // same for all collections AFAIK
        "${MediaStore.MediaColumns.DISPLAY_NAME} = ?",
        arrayOf(fileName),
        null
    )?.use { cursor ->
        if (cursor.moveToFirst()) {
            return cursor.getString(0)
        }
    }
    return null
}

/**
 * Returns path to media store [destination] for Android versions at or above Q
 */
@RequiresApi(Build.VERSION_CODES.Q)
private fun getMediaStoreUri(destination: SharedStorage): Uri {
    return when (destination) {
        SharedStorage.files -> MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        SharedStorage.downloads -> MediaStore.Downloads.getContentUri(
            MediaStore.VOLUME_EXTERNAL_PRIMARY
        )

        SharedStorage.images -> MediaStore.Images.Media.getContentUri(
            MediaStore.VOLUME_EXTERNAL_PRIMARY
        )

        SharedStorage.video -> MediaStore.Video.Media.getContentUri(
            MediaStore.VOLUME_EXTERNAL_PRIMARY
        )

        SharedStorage.audio -> MediaStore.Audio.Media.getContentUri(
            MediaStore.VOLUME_EXTERNAL_PRIMARY
        )

        SharedStorage.external -> MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL)
    }
}

/**
 * Returns path to media store [destination] for Android versions below Q
 */
private fun getMediaStorePathBelowQ(destination: SharedStorage): String {
    return when (destination) {
        SharedStorage.files -> Environment.DIRECTORY_DOCUMENTS
        SharedStorage.downloads -> Environment.DIRECTORY_DOWNLOADS
        SharedStorage.images -> Environment.DIRECTORY_PICTURES
        SharedStorage.video -> Environment.DIRECTORY_MOVIES
        SharedStorage.audio -> Environment.DIRECTORY_MUSIC
        SharedStorage.external -> ""
    }
}

/**
 * Returns file path to ScopedStorage [destination] and subdirectory [directory]
 */
private fun getRelativePath(destination: SharedStorage, directory: String): String {
    val sharedStorageDirectory = when (destination) {
        SharedStorage.files -> Environment.DIRECTORY_DOCUMENTS
        SharedStorage.downloads -> Environment.DIRECTORY_DOWNLOADS
        SharedStorage.images -> Environment.DIRECTORY_PICTURES
        SharedStorage.video -> Environment.DIRECTORY_MOVIES
        SharedStorage.audio -> Environment.DIRECTORY_MUSIC
        SharedStorage.external -> ""
    }
    return if (directory.isEmpty()) sharedStorageDirectory else "$sharedStorageDirectory/$directory"
}


/**
 * Return Mime type for this [fileName], as a String
 *
 * Defaults to application/octet-stream
 */
fun getMimeType(fileName: String): String {
    val extension = fileName.substringAfterLast(".", "")
    return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
        ?: "application/octet-stream"
}

/**
 * Returns the file path related to this MediaStore [uri], or null
 */
private fun pathFromUri(context: Context, uri: Uri): String? {
    val proj = arrayOf(MediaStore.Images.Media.DATA)
    val loader = CursorLoader(context, uri, proj, null, null, null)
    val cursor = loader.loadInBackground() ?: return null
    val columnIndex: Int = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DATA)
    cursor.moveToFirst()
    val result = cursor.getString(columnIndex)
    cursor.close()
    return result
}
