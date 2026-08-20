import re

file_path = 'README.md'
with open(file_path, 'r') as f:
    content = f.read()

# Replace occurrences of the priority comment
old_readme = "or (on Android 14 and above) set the task's [priority](doc/parameters.md#priority) to 0 to use the User Initiated Data Transfer (UIDT) service."
new_readme = "or (on Android 14 and above) set the task's [priority](doc/parameters.md#priority) to 0 to use the User Initiated Data Transfer (UIDT) service (requires `android.permission.RUN_USER_INITIATED_JOBS` in `AndroidManifest.xml`)."

content = content.replace(old_readme, new_readme)

old_readme_case_issue = "[priority](doc/PARAMETERS.md#priority)"
content = content.replace(old_readme_case_issue, "[priority](doc/parameters.md#priority)")

with open(file_path, 'w') as f:
    f.write(content)
