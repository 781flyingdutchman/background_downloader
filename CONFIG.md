# Configuration

The downloader can be configured by calling `FileDownloader().configure` before executing any downloads or uploads. Configurations can be set for Global, Android, iOS or Desktop separately, where only the `globalConfig` is applied to every platform.

A configuration can be single config or a list of configs, and every config is a Record with the first element a String indicating what to configure, and the remaining parameters are the configuration.

The following configurations are supported:
* Timeouts
  - `('resourceTimeout', Duration? duration)` sets the iOS resourceTimeout, or if null resets to default
  - `('requestTimeout', Duration? duration)` sets the iOS requestTimeout, or if null resets to default
* HTTP Proxies
  - `('proxy', String address, int port)` sets the proxy to this address and port
  - `('proxy', false)` removes the proxy
* Android: run task in foreground (removes 9 minute timeout and may improve chances of task surviving background). Note that for a task to run in foreground it _must_ have a `running` notification configured, otherwise it will execute normally regardless of this setting
  - `('runInForeground', bool activate)` activates or de-activates foreground mode for all tasks
  - `('runInForegroundIfFileLargerThan', int fileSize)` activates foreground mode for downloads/uploads that exceed this file size, expressed in MB
