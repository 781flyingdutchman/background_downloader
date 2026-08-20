import re

file_path = 'android/src/main/kotlin/com/bbflight/background_downloader/BDPlugin.kt'
with open(file_path, 'r') as f:
    content = f.read()

# Fix setEstimatedNetworkBytes arguments
old_call = "jobInfoBuilder.setEstimatedNetworkBytes(1024 * 1024 * 10, JobInfo.NETWORK_BYTES_UNKNOWN)"
new_call = "jobInfoBuilder.setEstimatedNetworkBytes(1024L * 1024L * 10L, JobInfo.NETWORK_BYTES_UNKNOWN.toLong())"
content = content.replace(old_call, new_call)

with open(file_path, 'w') as f:
    f.write(content)
