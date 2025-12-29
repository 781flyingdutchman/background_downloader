package com.bbflight.background_downloader

import android.content.Context
import androidx.work.WorkerParameters

class UploadTaskWorker(applicationContext: Context, workerParams: WorkerParameters) :
    TaskWorker(applicationContext, workerParams) {

    override fun createExecutor(
        task: Task,
        notificationConfigJsonString: String?,
        resumeData: ResumeData?
    ): TaskExecutor {
        return UploadTaskExecutor(this, task, notificationConfigJsonString, resumeData)
    }
}
