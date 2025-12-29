package com.bbflight.background_downloader

import android.content.Context
import androidx.work.WorkerParameters

class DownloadTaskWorker(applicationContext: Context, workerParams: WorkerParameters) :
    TaskWorker(applicationContext, workerParams) {

    override fun createExecutor(
        task: Task,
        notificationConfigJsonString: String?,
        resumeData: ResumeData?
    ): TaskExecutor {
        return DownloadTaskExecutor(this, task, notificationConfigJsonString, resumeData)
    }
}
