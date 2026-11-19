package com.bbflight.background_downloader

import android.app.Notification
import android.content.Context
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test
import java.util.ArrayDeque

class NotificationQueueTest {

    private class FakeJobContext(
        override var notificationId: Int,
        override var runInForeground: Boolean
    ) : TaskJobContext {
        override val appContext: Context
            get() = error("appContext not used in queue test")
        override lateinit var task: Task
        override var notificationConfig: NotificationConfig? = null
        override var notificationProgress: Double = 2.0
        override var networkSpeed: Double = -1.0
        override var taskCanResume: Boolean = false
        override var notificationConfigJsonString: String? = null
        override val isTaskStopped: Boolean = false
        override val runId: String? = null
        override val isActive: Boolean = true

        override suspend fun setForegroundNotification(
            notificationId: Int,
            notification: Notification,
            notificationType: Int
        ) {}

        override fun getInputLong(key: String, defaultValue: Long): Long = defaultValue
        override fun getInputString(key: String): String? = null
        override suspend fun updateNotification(
            task: Task,
            status: TaskStatus,
            progress: Double,
            timeRemaining: Long
        ) {}

        override fun updateEstimatedNetworkBytes(downloadBytes: Long, uploadBytes: Long) {}
    }

    @Test
    fun foregroundWorkersSharingGroupNotificationIdAreNotCollapsed() {
        val groupNotificationId = 42
        val job1 = FakeJobContext(notificationId = groupNotificationId, runInForeground = true)
        val job2 = FakeJobContext(notificationId = groupNotificationId, runInForeground = true)
        val enqueueWorker = FakeJobContext(notificationId = groupNotificationId, runInForeground = false)

        val queue = ArrayDeque<NotificationData>().apply {
            add(NotificationData(job1, NotificationType.running, null))
            add(NotificationData(enqueueWorker, NotificationType.running, null))
            add(NotificationData(job2, NotificationType.running, null))
        }

        val first = NotificationService.dequeueNextNotificationLocked(queue)
        val second = NotificationService.dequeueNextNotificationLocked(queue)
        val third = NotificationService.dequeueNextNotificationLocked(queue)
        val fourth = NotificationService.dequeueNextNotificationLocked(queue)

        assertSame(job1, first?.taskWorker)
        assertSame(enqueueWorker, second?.taskWorker)
        assertSame(job2, third?.taskWorker)
        assertNull(fourth)
    }

    @Test
    fun sameWorkerRunningUpdatesStillCollapse() {
        val groupNotificationId = 42
        val job1 = FakeJobContext(notificationId = groupNotificationId, runInForeground = true)
        val job2 = FakeJobContext(notificationId = groupNotificationId, runInForeground = true)

        val firstUpdate = NotificationData(job1, NotificationType.running, null)
        val secondUpdate = NotificationData(job1, NotificationType.running, null)
        val otherJobUpdate = NotificationData(job2, NotificationType.running, null)

        val queue = ArrayDeque<NotificationData>().apply {
            add(firstUpdate)
            add(otherJobUpdate)
            add(secondUpdate)
        }

        val first = NotificationService.dequeueNextNotificationLocked(queue)
        val second = NotificationService.dequeueNextNotificationLocked(queue)

        assertSame(secondUpdate, first)
        assertSame(otherJobUpdate, second)
        assertEquals(0, queue.size)
    }

    @Test
    fun nonForegroundWorkersSharingGroupNotificationIdStillCollapse() {
        val groupNotificationId = 42
        val worker1 = FakeJobContext(notificationId = groupNotificationId, runInForeground = false)
        val worker2 = FakeJobContext(notificationId = groupNotificationId, runInForeground = false)

        val firstUpdate = NotificationData(worker1, NotificationType.running, null)
        val secondUpdate = NotificationData(worker2, NotificationType.running, null)

        val queue = ArrayDeque<NotificationData>().apply {
            add(firstUpdate)
            add(secondUpdate)
        }

        val first = NotificationService.dequeueNextNotificationLocked(queue)
        assertSame(secondUpdate, first)
        assertEquals(0, queue.size)
    }
}
