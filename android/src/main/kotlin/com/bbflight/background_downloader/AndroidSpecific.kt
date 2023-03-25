package com.bbflight.background_downloader

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import androidx.annotation.RequiresApi
import java.io.File
import java.io.FileInputStream
import java.io.OutputStream

/// Scoped Storage destinations for Android
enum class ScopedStorage { files, downloads, images, video, audio, external }

/**
 * Moves the file from filePath to the scoped storage destination and returns true if successful
 */
fun moveToScopedStorage(
        context: Context,
        filePath: String,
        destination: ScopedStorage,
        destinationFolder: String,
        markPending: Boolean,
        deleteTemporaryFile: Boolean,
): Boolean {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
        return false
    }

    val file = File(filePath)
    if (!file.exists()) {
        return false
    }

    if (!destinationFolder.startsWith("/")) {
        return false
    }

    // Set up the content values for the new file
    val contentValues = ContentValues().apply {
        put(MediaStore.MediaColumns.DISPLAY_NAME, file.name)
        put(MediaStore.MediaColumns.MIME_TYPE, getMimeType(file.name))
        put(MediaStore.MediaColumns.RELATIVE_PATH, getRelativePath(destination, destinationFolder))
        if (markPending) {
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
    }

    // Insert the new file into the MediaStore
    val resolver = context.contentResolver
    val uri = resolver.insert(getMediaStoreUri(destination), contentValues)

    // Get an OutputStream to write the contents of the file
    val os: OutputStream? = uri?.let { resolver.openOutputStream(it) }

    // Write data to the output stream
    os?.use { output ->
        FileInputStream(file).use { input ->
            input.copyTo(output)
        }
    }

    // Close the output stream
    os?.close()

    // If the file is pending, mark it as non-pending
    if (markPending) {
        contentValues.clear()
        contentValues.put(MediaStore.MediaColumns.IS_PENDING, 0)
        resolver.update(uri!!, contentValues, null, null)
    }

    // Return true if the file was created successfully
    val created = uri != null
    if (created && deleteTemporaryFile) {
        file.delete()
    }

    return created
}

@RequiresApi(Build.VERSION_CODES.Q)
private fun getMediaStoreUri(destination: ScopedStorage): Uri {
    return when (destination) {
        ScopedStorage.files -> MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        ScopedStorage.downloads -> MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        ScopedStorage.images -> MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        ScopedStorage.video -> MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        ScopedStorage.audio -> MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        ScopedStorage.external -> MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL)
    }
}

private fun getRelativePath(destination: ScopedStorage, destinationFolder: String): String {
    return when (destination) {
        ScopedStorage.files -> Environment.DIRECTORY_DOCUMENTS
        ScopedStorage.downloads -> Environment.DIRECTORY_DOWNLOADS
        ScopedStorage.images -> Environment.DIRECTORY_PICTURES
        ScopedStorage.video -> Environment.DIRECTORY_MOVIES
        ScopedStorage.audio -> Environment.DIRECTORY_MUSIC
        ScopedStorage.external -> ""
    } + destinationFolder
}

private fun getMimeType(fileName: String): String {
    val extension = MimeTypeMap.getFileExtensionFromUrl(fileName)
    return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
            ?: "application/octet-stream"
}
