package com.bbflight.background_downloader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GroupNotificationTest {

    private fun createTask(taskId: String): Task {
        return Task(
            taskId = taskId,
            url = "https://example.com/file",
            filename = "file_$taskId.txt",
            headers = mapOf(),
            baseDirectory = BaseDirectory.applicationDocuments,
            group = "testGroup",
            updates = Updates.statusAndProgress,
            taskType = "DownloadTask",
            displayName = "File $taskId"
        )
    }

    private fun createNotificationConfig(
        groupNotificationId: String = "testGroup",
        running: TaskNotification? = null,
        complete: TaskNotification? = null,
        error: TaskNotification? = null,
        paused: TaskNotification? = null,
        canceled: TaskNotification? = null,
        progressBar: Boolean = true,
        tapOpensFile: Boolean = false
    ): NotificationConfig {
        return NotificationConfig(
            running = running,
            complete = complete,
            error = error,
            paused = paused,
            canceled = canceled,
            progressBar = progressBar,
            tapOpensFile = tapOpensFile,
            groupNotificationId = groupNotificationId
        )
    }

    @Test
    fun groupNotificationInitialState() {
        val config = createNotificationConfig()
        val group = GroupNotification("testGroup", config)

        assertEquals("testGroup", group.name)
        assertEquals("groupNotificationtestGroup".hashCode(), group.notificationId)
        assertEquals(0, group.numTotal)
        assertEquals(0, group.numFinished)
        assertEquals(0, group.numFailed)
        assertEquals(2.0, group.progress, 0.001)
        assertTrue(group.isFinished)
        assertFalse(group.hasError)
        assertTrue(group.runningTasks.isEmpty())
    }

    @Test
    fun groupNotificationTransitions() {
        val config = createNotificationConfig()
        val group = GroupNotification("testGroup", config)
        val t1 = createTask("1")
        val t2 = createTask("2")

        // Enqueue t1 and t2 as running
        assertTrue(group.update(t1, NotificationType.running))
        assertEquals(1, group.numTotal)
        assertEquals(0, group.numFinished)
        assertFalse(group.isFinished)
        assertEquals(0.0, group.progress, 0.001)

        // Duplicate update returns false
        assertFalse(group.update(t1, NotificationType.running))

        assertTrue(group.update(t2, NotificationType.running))
        assertEquals(2, group.numTotal)
        assertEquals(0, group.numFinished)
        assertFalse(group.isFinished)

        // Finish t1 as complete
        assertTrue(group.update(t1, NotificationType.complete))
        assertEquals(2, group.numTotal)
        assertEquals(1, group.numFinished)
        assertEquals(0.5, group.progress, 0.001)
        assertFalse(group.isFinished)
        assertFalse(group.hasError)

        // Finish t2 as canceled (as in issue #756)
        assertTrue(group.update(t2, NotificationType.canceled))
        assertEquals(2, group.numTotal)
        assertEquals(2, group.numFinished)
        assertEquals(1.0, group.progress, 0.001)
        assertTrue(group.isFinished)
        assertFalse(group.hasError)
        assertTrue(group.runningTasks.isEmpty())
    }

    @Test
    fun groupNotificationWithError() {
        val config = createNotificationConfig()
        val group = GroupNotification("testGroup", config)
        val t1 = createTask("1")
        val t2 = createTask("2")

        group.update(t1, NotificationType.running)
        group.update(t2, NotificationType.running)

        // t1 finishes with error
        group.update(t1, NotificationType.error)
        assertEquals(1, group.numFailed)
        assertTrue(group.hasError)
        assertFalse(group.isFinished)

        // t2 canceled
        group.update(t2, NotificationType.canceled)
        assertEquals(2, group.numFinished)
        assertEquals(1, group.numFailed)
        assertTrue(group.isFinished)
        assertTrue(group.hasError)
    }
}
