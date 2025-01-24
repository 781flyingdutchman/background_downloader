package com.bbflight.background_downloader


import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.ext.SdkExtensions
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.util.Log
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.RequiresExtension
import androidx.core.net.toUri
import androidx.documentfile.provider.DocumentFile
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import java.io.File
import java.io.IOException


object UriUtils {

    /**
     * Packs [filename] and [uri] into a single String.
     *
     * Use [unpack] to retrieve the filename and uri from the packed String.
     */
    fun pack(filename: String, uri: Uri): String = ":::$filename::::::${uri.toString()}:::"

    /**
     * Unpacks [packedString] into a filename and uri. If this is not a packed
     * string, returns the original [packedString] as the filename and null.
     */
    fun unpack(packedString: String): Pair<String?, Uri?> {
        val regex = Regex(":::([\\s\\S]*?)::::::([\\s\\S]*?):::")
        val match = regex.find(packedString)

        return if (match != null && match.groupValues.size == 3) {
            val filename = match.groupValues[1]
            val uriString = match.groupValues[2]
            val uri = Uri.parse(uriString)
            val scheme = uri?.scheme
            Pair(filename, if (scheme?.isNotEmpty() == true) uri else null)
        } else {
            val uri = Uri.parse(packedString)
            val scheme = uri?.scheme
            if (scheme?.isNotEmpty() == true) Pair(null, uri)
            else Pair(packedString, null)
        }
    }

    /**
     * Returns the Uri represented by [value], or null if the String is not a
     * valid Uri or packed Uri string.
     *
     * [value] should be a full Uri string, or a packed String containing
     * a Uri (see [pack]).
     */
    fun uriFromStringValue(value: String): Uri? {
        val (_, uri) = unpack(value)
        return uri
    }

    /**
     * Returns true if [value] is a valid Uri or packed Uri string.
     *
     * [value] should be a full Uri string, or a packed String containing
     * a Uri (see [pack]).
     */
    fun containsUri(value: String): Boolean = uriFromStringValue(value) != null
}

/**
 * Handles method calls from Flutter related to file and directory picking/creation.
 */
class UriUtilsMethodCallHelper(private val plugin: BDPlugin) : MethodCallHandler {

    private val TAG = "MethodCallHelper"

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val activity = plugin.activity
        if (activity == null) {
            result.error("NO_ACTIVITY", "No activity found", null)
            return
        }

        when (call.method) {
            "pickDirectory" -> {
                /**
                 * results in selected directory URI (or null) for the [SharedStorage] starting location, which
                 * may be null for no selection. If persistedUriPermission is true, the URI will be persisted
                 *
                 * Arguments are startLocationOrdinal (of [SharedStorage]) and persistedUriPermission (bool)
                 */
                val args = call.arguments as? List<*>
                val startLocationOrdinal = args?.get(0) as Int?
                val startLocationUriString = args?.get(1) as? String
                val persistedUriPermission = args?.get(2) as? Boolean ?: false
                Log.wtf(
                    DirectoryPicker.TAG,
                    "pickDirectory with $args and  startLocation $startLocationOrdinal and persist $persistedUriPermission"
                )

                val startLocation =
                    if (startLocationOrdinal != null) SharedStorage.entries[startLocationOrdinal] else null
                val startLocationUri = startLocationUriString?.toUri()

                if (!DirectoryPicker.pickDirectory(
                        activity,
                        startLocation,
                        startLocationUri,
                        persistedUriPermission,
                        result
                    )
                ) {
                    result.error(
                        "PICK_DIRECTORY_FAILED",
                        "Failed to launch directory picker",
                        null
                    )
                }
            }

            "pickFiles" -> {
                /**
                 * Results in selected file URI(s) for the [SharedStorage] starting location, which
                 * may be null for no selection. If allowedExtensions is not null, only files with the
                 * given extensions will be allowed. If multipleAllowed is true, multiple files can be
                 * selected. If persistedUriPermission is true, the URI will be persisted.
                 *
                 * Arguments are startLocationOrdinal (of [SharedStorage]), allowedExtensions (list of
                 * strings, or null), multipleAllowed (bool), and persistedUriPermission (bool).
                 */
                val args = call.arguments as? List<*>
                val startLocationOrdinal = args?.get(0) as Int?
                val startLocationUriString = args?.get(1) as? String
                val allowedExtensionsAnyList = args?.get(2) as? List<*>
                val allowedExtensions = allowedExtensionsAnyList?.map { it as String }
                val multipleAllowed = args?.get(3) as? Boolean == true
                val persistedUriPermission = args?.get(4) as? Boolean == true

                val startLocation =
                    if (startLocationOrdinal != null) SharedStorage.entries[startLocationOrdinal] else null
                val startLocationUri = startLocationUriString?.toUri()

                if (startLocation == SharedStorage.images || startLocation == SharedStorage.video) {
                    if (!FilePicker.pickMedia(
                            activity,
                            startLocation,
                            multipleAllowed,
                            persistedUriPermission,
                            result
                        )
                    ) {
                        result.error("PICK_FILES_FAILED", "Failed to launch media picker", null)
                    }
                } else {
                    if (!FilePicker.pickFiles(
                            activity,
                            startLocation,
                            startLocationUri,
                            allowedExtensions,
                            multipleAllowed,
                            persistedUriPermission,
                            result
                        )
                    ) {
                        result.error("PICK_FILES_FAILED", "Failed to launch file picker", null)
                    }
                }
            }

            "createDirectory" -> {
                /**
                 * Creates a new directory with the given name inside the specified parent directory
                 * URI. Results in the URI of the new directory
                 *
                 * Arguments are parentDirectoryUri (string), newDirectoryName (string), and
                 * persistedUriPermission (bool).
                 */
                val args = call.arguments as? List<*>
                val parentDirectoryUriString = args?.get(0) as? String
                val newDirectoryName = args?.get(1) as? String
                val persistedUriPermission = args?.get(2) as? Boolean == true

                if (parentDirectoryUriString == null || newDirectoryName == null) {
                    result.error(
                        "INVALID_ARGUMENTS",
                        "Parent directory URI and new directory name are required",
                        null
                    )
                    return
                }
                Log.wtf(TAG, "parent dir URIstring: $parentDirectoryUriString")
                val parentDirectoryUri = Uri.parse(parentDirectoryUriString)
                Log.wtf(TAG, "parent dir URI: $parentDirectoryUri")

                DirectoryCreator.createDirectory(
                    activity,
                    parentDirectoryUri,
                    newDirectoryName,
                    persistedUriPermission,
                    result
                )
            }

            "getFileBytes" -> {
                val uriString = call.arguments as? String
                if (uriString == null) {
                    result.error("INVALID_ARGUMENTS", "URI string is required", null)
                    return
                }
                val fileBytes = getFile(activity, Uri.parse(uriString))
                if (fileBytes != null) {
                    result.success(fileBytes)
                } else {
                    result.error("GET_FILE_FAILED", "Failed to get file", null)
                }
            }

            "deleteFile" -> {
                val uriString = call.arguments as? String
                if (uriString == null) {
                    result.error("INVALID_ARGUMENTS", "URI string is required", null)
                    return
                }
                val uri = Uri.parse(uriString)
                if (uri.scheme == "content") {
                    val docFile = DocumentFile.fromSingleUri(activity, Uri.parse(uriString))
                    if (docFile != null && docFile.delete()) {
                        result.success(null)
                    } else {
                        result.error("DELETE_FILE_FAILED", "Failed to delete file", null)
                    }
                    return
                }
                if (uri.scheme == "file") {
                    val file = File(uri.path!!)
                    if (file.delete()) {
                        result.success(null)
                    } else {
                        result.error("DELETE_FILE_FAILED", "Failed to delete file", null)
                    }
                    return
                }
                result.error("DELETE_FILE_FAILED", "Invalid URI: $uri", null)
            }

            else -> result.notImplemented()
        }
    }

    /**
     * Gets the file content as a byte array for a given URI.
     *
     * @param context The application context.
     * @param uri The URI of the file.
     * @return The file content as a byte array, or null if an error occurred.
     */
    private fun getFile(context: Context, uri: Uri): ByteArray? {
        return try {
            context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
        } catch (e: IOException) {
            Log.e(TAG, "Error reading file: $uri", e)
            null
        }
    }
}


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
        startLocationUri: Uri?,
        persistedUriPermission: Boolean = false,
        result: MethodChannel.Result
    ): Boolean {
        if (pendingResult != null) {
            Log.w(TAG, "Directory picker already in progress")
            return false
        }
        pendingResult = result
        Log.wtf(
            TAG,
            "pickDirectory with startLocation $startLocation and persist $persistedUriPermission"
        )
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            if (persistedUriPermission) {
                flags = flags or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
            }
            // Set the starting directory (for API 26+).
            if ((startLocation != null || startLocationUri != null) && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                putExtra(
                    DocumentsContract.EXTRA_INITIAL_URI,
                    if (startLocationUri != null) startLocationUri else getInitialDirectoryUri(
                        startLocation!!
                    )
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
    private const val REQUEST_CODE_PICK_MEDIA = 36546510

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
        startLocationUri: Uri?,
        allowedExtensions: List<String>?,
        multipleAllowed: Boolean = false,
        persistedUriPermission: Boolean = false,
        result: MethodChannel.Result
    ): Boolean {
        if (pendingResult != null) {
            Log.w(TAG, "File picker already in progress")
            return false
        }
        this.multipleAllowed = multipleAllowed
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, multipleAllowed)
            flags = Intent.FLAG_GRANT_READ_URI_PERMISSION
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
            if ((startLocation != null || startLocationUri != null) && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                putExtra(
                    DocumentsContract.EXTRA_INITIAL_URI,
                    if (startLocationUri != null) startLocationUri else getInitialDirectoryUri(
                        startLocation!!
                    )
                )
            }
        }
        this.persistedUriPermission = persistedUriPermission // for later reference
        this.multipleAllowed = multipleAllowed // for later reference
        pendingResult = result
        activity.startActivityForResult(intent, REQUEST_CODE_PICK_FILES)
        return true
    }

    /**
     * Launches the Android photo picker to select one or more media files (images or videos).
     *
     * @param activity The current activity.
     * @param startLocation The shared storage location to start the picker in (images or video).
     * @param multipleAllowed Whether to allow the user to select multiple files.
     * @param persistedUriPermission Whether to persist the URI permission across device reboots.
     * @param result The MethodChannel result to complete when the picker is closed.
     *
     * Returns true if the picker was launched successfully, false otherwise.
     *
     * The result posted back is either a list of URIs as a String, or null (if the user has
     * cancelled the picker) or an error
     */
    fun pickMedia(
        activity: Activity,
        startLocation: SharedStorage,
        multipleAllowed: Boolean = false,
        persistedUriPermission: Boolean = false,
        result: MethodChannel.Result
    ): Boolean {
        if (pendingResult != null) {
            Log.w(TAG, "Media picker already in progress")
            return false
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && SdkExtensions.getExtensionVersion(
                Build.VERSION_CODES.R
            ) >= 2
        ) {
            // on Android version >R.2 we use the new photo picker
            val photoPickerIntent = Intent(MediaStore.ACTION_PICK_IMAGES).apply {
                if (multipleAllowed) {
                    val maxImages = MediaStore.getPickImagesMaxLimit()
                    putExtra(MediaStore.EXTRA_PICK_IMAGES_MAX, maxImages)
                }
            }
            photoPickerIntent.apply {
                if (startLocation == SharedStorage.images) {
                    type = "image/*"
                } else if (startLocation == SharedStorage.video) {
                    type = "video/*"
                }
            }
            this.persistedUriPermission = persistedUriPermission // for later reference
            this.multipleAllowed = multipleAllowed // for later reference
            pendingResult = result
            activity.startActivityForResult(photoPickerIntent, REQUEST_CODE_PICK_MEDIA)
            return true
        } else {
            // for older Android versions we use the filePicker with image or video extensions
            return pickFiles(
                activity,
                startLocation,
                null,
                if (startLocation == SharedStorage.images) listOf(
                    "jpg",
                    "jpeg",
                    "png",
                    "gif",
                    "webp",
                    "bmp",
                    "heic",
                    "heif",
                    "svg"
                ) else listOf("mp4", "webm", "ogg", "webm", "mov", "avi", "mkv"),
                multipleAllowed,
                persistedUriPermission,
                result
            )
        }
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
        if (requestCode == REQUEST_CODE_PICK_FILES || requestCode == REQUEST_CODE_PICK_MEDIA) {
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
        } else if (requestCode == REQUEST_CODE_PICK_MEDIA) {
            if (resultCode == Activity.RESULT_OK) {
                val uris = mutableListOf<String>()
                if (multipleAllowed && data?.clipData != null) {
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
                pendingResult?.success(null)
            }
            pendingResult = null
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
     * If the new directory path contains multiple levels, it creates all intermediate directories as needed.
     *
     * @param context The application context.
     * @param parentDirectoryUri The URI of the parent directory.
     * @param newDirectoryName The name of the new directory to create (can be a path).
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

        // Sanitize the new directory name by removing leading/trailing path separators
        val sanitizedDirectoryName = newDirectoryName.trim(File.separatorChar)

        try {
            var currentDir: DocumentFile = parentDir
            val directoryPathParts = sanitizedDirectoryName.split(File.separatorChar)

            for (directoryName in directoryPathParts) {
                Log.wtf(TAG, "direName=$directoryName, currentDir=$currentDir")
                var newDir = currentDir.findFile(directoryName)
                Log.wtf(TAG, "newDir=$newDir")

                if (newDir == null || !newDir.exists()) {
                    newDir = currentDir.createDirectory(directoryName)
                } else if (!newDir.isDirectory) {
                    result.error(
                        "INVALID_PATH",
                        "Invalid path: $directoryName is not a directory",
                        null
                    )
                    return
                }
                Log.wtf(TAG, "newDir after createDirectory=$newDir")
                if (newDir == null) {
                    result.error(
                        "CREATE_FAILED",
                        "Failed to create directory: $directoryName",
                        null
                    )
                    return
                }
                currentDir = newDir
                // Grant permissions to intermediate directories as well
                if (persistedUriPermission) {
                    context.contentResolver.takePersistableUriPermission(
                        newDir.uri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                    )
                }
            }
            Log.wtf(TAG, "currentDir after loop=$currentDir and uri=${currentDir.uri}")

            // Return the URI of the final directory
            result.success(currentDir.uri.toString())

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


/**
 * Gets the initial directory URI based on the specified shared storage location.
 *
 * @param location The shared storage location.
 * @return The URI of the corresponding directory, or null if the location is unknown or not applicable.
 */
private fun getInitialDirectoryUri(location: SharedStorage): Uri? {
    return when (location) {
        SharedStorage.downloads -> {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                MediaStore.Downloads.EXTERNAL_CONTENT_URI
            } else {
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                    .toUri()
            }
        }

        SharedStorage.images -> {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                "content://com.android.externalstorage.documents/tree/primary%3APictures".toUri()
            } else {
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES)
                    .toUri()
            }
        }

        SharedStorage.video -> {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                "content://com.android.externalstorage.documents/tree/primary%3AMovies".toUri()
            } else {
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES)
                    .toUri()
            }
        }

        SharedStorage.audio -> {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                "content://com.android.externalstorage.documents/tree/primary%3AMusic".toUri()
            } else {
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MUSIC)
                    .toUri()
            }
        }

        SharedStorage.external -> {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                "content://com.android.externalstorage.documents/tree/secondary%3A".toUri()
            } else {
                Environment.getExternalStorageDirectory().toUri()
            }
        }

        SharedStorage.files -> {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                "content://com.android.externalstorage.documents/tree/primary%3A".toUri()
            } else {
                Environment.getDataDirectory().toUri()
            }
        }

        else -> null // Handle unknown or unsupported locations
    }
}