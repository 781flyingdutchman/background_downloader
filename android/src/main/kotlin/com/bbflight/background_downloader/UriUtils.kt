package com.bbflight.background_downloader

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import android.util.Log
import androidx.documentfile.provider.DocumentFile
import io.flutter.plugin.common.MethodChannel


/**
 * Helper class for launching the Android file picker to select a directory.
 */
object DirectoryPicker {
    const val TAG = "DirectoryPicker"
    private var pendingResult: MethodChannel.Result? = null
    private var persistedUriPermission: Boolean = false
    private const val REQUEST_CODE_PICK_DIRECTORY = 165465106


    /**
     * Launches the Android file picker to select a directory.
     *
     * @param activity The current activity.
     * @param startLocation The shared storage location to start the picker in (ignored on API levels below Q).
     * @param result The MethodChannel result to complete when the picker is closed.
     *
     * Returns true if the picker was launched successfully, false otherwise.
     *
     * The result of the picker is handled in [handleActivityResult], and is either
     * a URI string, null (if the picker was cancelled) or an error
     */
    fun pickDirectory(
        activity: Activity,
        startLocation: SharedStorage?,
        persistedUriPermission: Boolean = false,
        result: MethodChannel.Result
    ): Boolean {
        if (pendingResult != null) {
            Log.w(TAG, "Directory picker already in progress")
            return false
        }
        pendingResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            if (persistedUriPermission) {
                flags = flags or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
            }
            // Set the starting directory (for API 26+).
            if (startLocation != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                putExtra(
                    DocumentsContract.EXTRA_INITIAL_URI,
                    getMediaStoreUri(startLocation)
                )
            }
        }
        this.persistedUriPermission = persistedUriPermission // for later reference
        activity.startActivityForResult(intent, REQUEST_CODE_PICK_DIRECTORY)
        return true
    }


    /**
     * Handles the result from the directory picker activity, buy setting the [pendingResult] to the
     * result value. Returns null if the request was cancelled by the user, and errors if something
     * unusual happened
     *
     * @param requestCode The request code passed to startActivityForResult().
     * @param resultCode The result code returned by the child activity.
     * @param data An Intent, which can return result data to the caller.
     * @return True if the result was handled, false otherwise.
     */
    fun handleActivityResult(
        context: Context,
        requestCode: Int,
        resultCode: Int,
        data: Intent?
    ): Boolean {
        if (requestCode == REQUEST_CODE_PICK_DIRECTORY) {
            if (resultCode == Activity.RESULT_OK) {
                val directoryUri = data?.data
                if (persistedUriPermission && directoryUri != null) {
                    context.contentResolver.takePersistableUriPermission(
                        directoryUri,
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION
                    )
                }
                pendingResult?.success(directoryUri?.toString())
            } else {
                pendingResult?.success(null)
            }
            pendingResult = null // cancelled
            return true
        }
        return false
    }
}

/**
 * Helper class for launching the Android file picker to select one or more files.
 */
object FilePicker {
    const val TAG = "FilePicker"
    private var pendingResult: MethodChannel.Result? = null
    private var multipleAllowed: Boolean = false
    private var persistedUriPermission: Boolean = false
    private const val REQUEST_CODE_PICK_FILES = 265465106

    /**
     * Launches the Android file picker to select one or more files. Only read access is granted
     * to these files
     *
     * @param activity The current activity.
     * @param startLocation The shared storage location to start the picker in (ignored on API levels below Q).
     * @param allowedExtensions A list of allowed file extensions (without the dot), e.g., ["pdf", "jpg", "png"]. If null, all file types are allowed.
     * @param multipleAllowed Whether to allow the user to select multiple files.
     * @param persistedUriPermission Whether to persist the URI permission across device reboots.
     * @param result The MethodChannel result to complete when the picker is closed.
     *
     * Returns true if the picker was launched successfully, false otherwise.
     *
     * The result posted back is either a list of URIs as a String, or null (if the user has
     * cancelled the picker) or an error
     */
    fun pickFiles(
        activity: Activity,
        startLocation: SharedStorage?,
        allowedExtensions: List<String>?,
        multipleAllowed: Boolean = false,
        persistedUriPermission: Boolean = false,
        result: MethodChannel.Result
    ): Boolean {
        if (pendingResult != null) {
            Log.w(TAG, "File picker already in progress")
            return false
        }
        pendingResult = result
        this.multipleAllowed = multipleAllowed
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, multipleAllowed)
            flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            if (persistedUriPermission) {
                flags = flags or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
            }

            if (!allowedExtensions.isNullOrEmpty()) {
                val mimeTypes = extensionsToMimeTypes(allowedExtensions)
                if (mimeTypes.size == 1) {
                    type = mimeTypes[0]
                } else {
                    type = "*/*"
                    putExtra(Intent.EXTRA_MIME_TYPES, mimeTypes)
                }
            } else {
                type = "*/*" // Allow all file types if no extensions are specified
            }

            // Set the starting directory (for API 26+).
            if (startLocation != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                putExtra(
                    DocumentsContract.EXTRA_INITIAL_URI,
                    getMediaStoreUri(startLocation)
                )
            }
        }
        this.persistedUriPermission = persistedUriPermission // for later reference
        this.multipleAllowed = multipleAllowed // for later reference
        activity.startActivityForResult(intent, REQUEST_CODE_PICK_FILES)
        return true
    }

    /**
     * Handles the result from the file picker activity, by setting the [pendingResult] to the
     * result value. Grants read access only
     *
     * @param context The context, needed to persist permissions
     * @param requestCode The request code passed to startActivityForResult().
     * @param resultCode The result code returned by the child activity.
     * @param data An Intent, which can return result data to the caller.
     * @return True if the result was handled, false otherwise.
     */
    fun handleActivityResult(
        context: Context,
        requestCode: Int,
        resultCode: Int,
        data: Intent?
    ): Boolean {
        if (requestCode == REQUEST_CODE_PICK_FILES) {
            if (resultCode == Activity.RESULT_OK) {
                val uris = mutableListOf<String>()
                if (multipleAllowed && data?.clipData != null) {
                    // Multiple files selected
                    val clipData = data.clipData!!
                    for (i in 0 until clipData.itemCount) {
                        val uri = clipData.getItemAt(i).uri
                        if (persistedUriPermission) {
                            context.contentResolver.takePersistableUriPermission(
                                uri,
                                Intent.FLAG_GRANT_READ_URI_PERMISSION
                            )
                        }
                        uris.add(uri.toString())
                    }
                } else if (data?.data != null) {
                    // Single file selected
                    val uri = data.data!!
                    if (persistedUriPermission) {
                        context.contentResolver.takePersistableUriPermission(
                            uri,
                            Intent.FLAG_GRANT_READ_URI_PERMISSION
                        )
                    }
                    uris.add(uri.toString())
                }
                pendingResult?.success(uris)
            } else {
                pendingResult?.success(null) // cancelled
            }
            pendingResult = null // Reset the pending result
            return true
        }
        return false
    }

    /**
     * Converts a list of file extensions to a list of corresponding MIME types using the provided `getMimeType` function.
     *
     * @param extensions The list of file extensions (without the dot).
     * @return A list of MIME types.
     */
    private fun extensionsToMimeTypes(extensions: List<String>): Array<String> {
        return extensions.map { extension ->
            if (extension.startsWith('.'))
                getMimeType(extension)
            else getMimeType("file.$extension")
        }.toSet().toTypedArray()
    }
}

/**
 * Helper class for creating a new directory using the Android SAF.
 */
object DirectoryCreator {
    const val TAG = "DirectoryCreator"

    /**
     * Creates a new directory within the given parent directory.
     *
     * @param context The application context.
     * @param parentDirectoryUri The URI of the parent directory.
     * @param newDirectoryName The name of the new directory to create.
     * @param persistedUriPermission Whether to persist the URI permission across device reboots.
     * @param result The MethodChannel result to complete when the operation is finished.
     *
     * Returns true if the directory creation was initiated successfully, false otherwise.
     *
     * The result posted back is either a URI string, or an error
     */
    fun createDirectory(
        context: Context,
        parentDirectoryUri: Uri,
        newDirectoryName: String,
        persistedUriPermission: Boolean,
        result: MethodChannel.Result
    ) {
        val parentDir = DocumentFile.fromTreeUri(context, parentDirectoryUri)
        if (parentDir == null || !parentDir.exists() || !parentDir.isDirectory) {
            result.error(
                "INVALID_PARENT_URI",
                "Invalid or inaccessible parent directory URI",
                null
            )
            return
        }

        try {
            val newDir = parentDir.createDirectory(newDirectoryName)
            if (newDir != null) {
                if (persistedUriPermission) {
                    context.contentResolver.takePersistableUriPermission(
                        newDir.uri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                    )
                }
                result.success(newDir.uri.toString())
            } else {
                result.error(
                    "CREATE_FAILED",
                    "Failed to create directory",
                    null
                )
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error creating directory", e)
            result.error(
                "CREATE_FAILED",
                "Error creating directory: ${e.message}",
                null
            )
        }
    }
}
