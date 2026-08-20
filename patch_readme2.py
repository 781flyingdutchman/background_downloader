import re

file_path = 'README.md'
with open(file_path, 'r') as f:
    content = f.read()

# Try again because it didn't match the casing of the doc link in the previous attempt
old_readme = "or (on Android 14 and above) set the task's [priority](doc/PARAMETERS.md#priority) to 0 to use the User Initiated Data Transfer (UIDT) service."
new_readme = "or (on Android 14 and above) set the task's [priority](doc/parameters.md#priority) to 0 to use the User Initiated Data Transfer (UIDT) service (requires `android.permission.RUN_USER_INITIATED_JOBS` in `AndroidManifest.xml`)."
content = content.replace(old_readme, new_readme)

old_readme2 = "or (on Android 14 and above) set the task's [priority](doc/parameters.md#priority) to 0 to use the User Initiated Data Transfer (UIDT) service."
new_readme2 = "or (on Android 14 and above) set the task's [priority](doc/parameters.md#priority) to 0 to use the User Initiated Data Transfer (UIDT) service (requires `android.permission.RUN_USER_INITIATED_JOBS` in `AndroidManifest.xml`)."
content = content.replace(old_readme2, new_readme2)


with open(file_path, 'w') as f:
    f.write(content)
