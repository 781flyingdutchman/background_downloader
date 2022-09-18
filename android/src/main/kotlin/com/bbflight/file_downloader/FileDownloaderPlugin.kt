package com.bbflight.file_downloader

import android.util.Log
import androidx.annotation.NonNull
import androidx.work.*

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/** FlutterDownloaderPlugin */
class FileDownloaderPlugin : FlutterPlugin, MethodCallHandler {
    companion object {
        const val TAG = "FlutterDownloaderPlugin"
        private var channel: MethodChannel? = null
        var backgroundChannel: MethodChannel? = null
        private lateinit var workManager: WorkManager
    }

    override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        channel =
            MethodChannel(flutterPluginBinding.binaryMessenger, "com.bbflight.file_downloader")
        backgroundChannel =
            MethodChannel(flutterPluginBinding.binaryMessenger, "com.bbflight.file_downloader.background")
        channel?.setMethodCallHandler(this)
        workManager = WorkManager.getInstance(flutterPluginBinding.applicationContext)
    }

    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        backgroundChannel = null
    }

    override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
        Log.d(TAG, "method call: ${call.method}")
        when (call.method) {
            "reset" -> methodReset(call, result)
            "enqueueDownload" -> methodEnqueueDownload(call, result)
            else -> result.notImplemented()
        }
    }


    /// Initialization: store the handler to the workerDispatcher and the debug mode
    private fun methodReset(@NonNull call: MethodCall, @NonNull result: Result) {
        workManager.cancelAllWorkByTag(TAG)
        result.success(null)
    }

    private fun methodEnqueueDownload(@NonNull call: MethodCall, @NonNull result: Result) {
        Log.d(TAG, "Enqueueing task  ${call.arguments as String}")
        val data = Data.Builder()
            .putString(DownloadWorker.keyDownloadTask, call.arguments as String)
            .build()
        val constraints = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED)
            .build()
        val request = OneTimeWorkRequestBuilder<DownloadWorker>()
            .setInputData(data)
            .setConstraints(constraints)
            .addTag(TAG)
            .build()
        val operation = workManager.enqueue(request)
        Log.d(TAG, "Operation ${operation.result}")
        result.success(null)
    }
}


