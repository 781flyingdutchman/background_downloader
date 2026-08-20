import re

file_path = "android/src/main/kotlin/com/bbflight/background_downloader/BDPlugin.kt"

with open(file_path, "r") as f:
    content = f.read()

# Add imports
imports = """import android.Manifest
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat"""

if "import android.Manifest" not in content:
    content = re.sub(r'(import android\.os\.Build)', r'\1\n' + imports, content)

# Modify useJobScheduler logic
old_logic = """            val useJobScheduler = task.priority == 0 &&
                                  notificationConfigJsonString != null &&
                                  Build.VERSION.SDK_INT >= 34"""

new_logic = """            var useJobScheduler = task.priority == 0 &&
                                  notificationConfigJsonString != null &&
                                  Build.VERSION.SDK_INT >= 34
            if (useJobScheduler) {
                // UIDT requires the RUN_USER_INITIATED_JOBS permission. If not granted, fallback to WorkManager.
                val permissionStatus = ContextCompat.checkSelfPermission(context, Manifest.permission.RUN_USER_INITIATED_JOBS)
                if (permissionStatus != PackageManager.PERMISSION_GRANTED) {
                    Log.w(TAG, "RUN_USER_INITIATED_JOBS permission not granted, falling back to WorkManager for task ${task.taskId}")
                    useJobScheduler = false
                }
            }"""
content = content.replace(old_logic, new_logic)

# Add setUserInitiated and setEstimatedNetworkBytes
old_builder = """                val jobInfoBuilder = JobInfo.Builder(task.taskId.hashCode(), componentName)
                    .setRequiredNetworkType(if (taskRequiresWifi) JobInfo.NETWORK_TYPE_UNMETERED else JobInfo.NETWORK_TYPE_ANY)
                    .setRequiresCharging(false)
                    .setExtras(extras)"""

new_builder = """                val jobInfoBuilder = JobInfo.Builder(task.taskId.hashCode(), componentName)
                    .setRequiredNetworkType(if (taskRequiresWifi) JobInfo.NETWORK_TYPE_UNMETERED else JobInfo.NETWORK_TYPE_ANY)
                    .setRequiresCharging(false)
                    .setExtras(extras)

                if (Build.VERSION.SDK_INT >= 34) {
                    jobInfoBuilder.setUserInitiated(true)
                    // Provide a default estimate if actual size is unknown to help OS scheduling
                    jobInfoBuilder.setEstimatedNetworkBytes(1024 * 1024 * 10, JobInfo.NETWORK_BYTES_UNKNOWN)
                }"""
content = content.replace(old_builder, new_builder)


with open(file_path, "w") as f:
    f.write(content)
