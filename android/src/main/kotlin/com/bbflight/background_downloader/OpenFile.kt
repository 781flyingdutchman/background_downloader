package com.bbflight.background_downloader

import android.app.Activity
import android.content.Intent
import android.util.Log
import androidx.core.content.FileProvider
import androidx.core.content.FileProvider.getUriForFile
import java.io.File


class OpenFileProvider : FileProvider(R.xml.bgd_file_paths)

fun doOpenFile(activity: Activity, filePath: String, mimeType: String): Boolean {
    val intent = Intent(Intent.ACTION_VIEW)
    try {
        if (BDPlugin.activity != null) {
            val contentUri = getUriForFile(
                activity,
                activity.packageName + ".com.bbflight.background_downloader.fileprovider",
                File(filePath)
            )
            intent.setDataAndType(contentUri, mimeType)
            intent.addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            )
            activity.startActivity(intent)
            return true
        }
    } catch (e: Exception) {
        Log.i(BDPlugin.TAG, "Failed to open file $filePath: $e")
    }
    return false
}
