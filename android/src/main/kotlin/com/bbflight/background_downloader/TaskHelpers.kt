package com.bbflight.background_downloader

import android.content.Context
import android.content.SharedPreferences
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlin.concurrent.read

/** Return the map of tasks stored in preferences */
fun getTaskMap(prefs: SharedPreferences): MutableMap<String, Task> {
    BDPlugin.prefsLock.read {
        val tasksMapJson = prefs.getString(BDPlugin.keyTasksMap, "{}") ?: "{}"
        return Json.decodeFromString(tasksMapJson)
    }
}

/**
 * Returns a [task] that may be modified through callbacks
 *
 * Callbacks would be attached to the task via its [Task.options] property, and if
 * present will be invoked by starting a taskDispatcher on a background isolate, then
 * sending the callback request via the MethodChannel
 *
 * First test is for auth refresh (the onAuth callback), then the onStart callback. Both
 * callbacks run in a Dart isolate, and may return a modified task, which will be used
 * for the actual task execution
 */
suspend fun getModifiedTask(context: Context, task: Task): Task {
    var authTask: Task? = null
    val auth = task.options?.auth
    if (auth != null) {
        // Refresh token if needed
        if (auth.isTokenExpired() && auth.hasOnAuthCallback()) {
            authTask = withContext(Dispatchers.IO) {
                Callbacks.invokeOnAuthCallback(context, task)
            }
        }
        authTask = authTask ?: task // Either original or newly authorized
        val newAuth = authTask.options?.auth ?: return authTask
        // Insert query parameters and headers
        val uri = newAuth.addOrUpdateQueryParams(
            url = authTask.url,
            queryParams = newAuth.getExpandedAccessQueryParams()
        )
        val headers =
            authTask.headers.toMutableMap().apply { putAll(newAuth.getExpandedAccessHeaders()) }
        authTask = authTask.copyWith(url = uri.toString(), headers = headers)
    }
    authTask = authTask ?: task
    if (task.options?.hasOnStartCallback() != true) {
        return authTask
    }
    // onStart callback
    val modifiedTask = withContext(Dispatchers.IO) {
        Callbacks.invokeOnTaskStartCallback(context, authTask)
    }
    return modifiedTask ?: authTask
}

/**
 * Returns the length of the [string] in bytes when utf-8 encoded
 */
fun lengthInBytes(string: String): Int {
    return string.toByteArray().size
}
