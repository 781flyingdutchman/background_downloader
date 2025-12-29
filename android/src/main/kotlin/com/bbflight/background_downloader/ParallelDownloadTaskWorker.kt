package com.bbflight.background_downloader

import android.content.Context
import androidx.work.WorkerParameters

class ParallelDownloadTaskWorker(applicationContext: Context, workerParams: WorkerParameters) :
    TaskWorker(applicationContext, workerParams) {

    override fun createExecutor(
        task: Task,
        notificationConfigJsonString: String?,
        resumeData: ResumeData?
    ): TaskExecutor {
        return ParallelDownloadTaskExecutor(this, task, notificationConfigJsonString, resumeData)
    }
}
