package com.bbflight.background_downloader

import android.content.Context
import androidx.work.WorkerParameters

class DataTaskWorker(applicationContext: Context, workerParams: WorkerParameters) :
    TaskWorker(applicationContext, workerParams) {

    override fun createExecutor(
        task: Task,
        notificationConfigJsonString: String?,
        resumeData: ResumeData?
    ): TaskExecutor {
        return DataTaskExecutor(this, task, notificationConfigJsonString, resumeData)
    }
}
