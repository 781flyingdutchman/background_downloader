import re

file_path = 'lib/src/task.dart'
with open(file_path, 'r') as f:
    content = f.read()

# Replace occurrences of the priority comment
old_comment = "/// [priority] in range 0 <= priority <= 10 with 0 highest, defaults to 5"
new_comment = """/// [priority] in range 0 <= priority <= 10 with 0 highest, defaults to 5.
  /// On Android 14+, setting priority to 0 requires the
  /// `android.permission.RUN_USER_INITIATED_JOBS` permission in AndroidManifest.xml."""

content = content.replace(old_comment, new_comment)

with open(file_path, 'w') as f:
    f.write(content)
