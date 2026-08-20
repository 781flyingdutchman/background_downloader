import re

file_path = 'doc/parameters.md'
with open(file_path, 'r') as f:
    content = f.read()

# Replace occurrences of the priority comment
old_comment = "The `priority` field must be 0 <= priority <= 10 with 0 being the highest priority, and defaults to 5. On Desktop and iOS all priority levels are supported. On Android, priority levels <5 are handled as 'expedited', and >=5 is handled as a normal task. If priority is set to 0, has an associated notification, and the task is on Android 14 (API 34) or above, the downloader will use the User Initiated Data Transfer (UIDT) service, which does not have a 9 minute timeout and is less likely to be killed by the OS."
new_comment = "The `priority` field must be 0 <= priority <= 10 with 0 being the highest priority, and defaults to 5. On Desktop and iOS all priority levels are supported. On Android, priority levels <5 are handled as 'expedited', and >=5 is handled as a normal task. If priority is set to 0, has an associated notification, and the task is on Android 14 (API 34) or above, the downloader will use the User Initiated Data Transfer (UIDT) service, which does not have a 9 minute timeout and is less likely to be killed by the OS. Note that using UIDT requires the `android.permission.RUN_USER_INITIATED_JOBS` permission in your app's `AndroidManifest.xml`. If the permission is missing, the downloader will automatically fall back to using a standard foreground service."

content = content.replace(old_comment, new_comment)

with open(file_path, 'w') as f:
    f.write(content)
