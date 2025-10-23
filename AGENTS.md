# AGENTS.md

This document provides guidance for AI agents working with the `background_downloader` Flutter plugin codebase.

## Overview

This Flutter plugin provides multi-platform background file downloading and uploading capabilities. It allows defining tasks, enqueuing them, and monitoring their progress.

## Architecture

The plugin's architecture separates the public API from the internal implementation.

- **Public API:** The main entry point is `lib/background_downloader.dart`, which exports all the public-facing classes and functions. The primary class is `FileDownloader`, which provides all the functionality of the plugin.
- **Core Logic:** The core logic resides in the `lib/src` directory. Key classes include:
    - `Task`: The base class for all tasks, with subclasses `DownloadTask` and `UploadTask`.
    - `FileDownloader`: The main interface for the plugin.
    - `BaseDownloader`: An abstract class that defines the platform-specific downloader interface.
- **Platform-Specific Code:** Platform-specific code is located in the `android`, `ios`, `linux`, `macos`, and `windows` directories. Communication between the Dart layer and the native platform code is handled using `MethodChannel`.
- **State Management:** Task state and progress are managed through streams and callbacks. The `FileDownloader.updates` stream provides `TaskUpdate` objects for all tasks that do not have a registered callback.

## Coding Conventions

- Subclasses intended for internal use within a library should be made private by prefixing their names with an underscore (`_`).

## Testing

To run the tests for this plugin, use the following command:

```bash
flutter test
```
