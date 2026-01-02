# Architecture and Technical Design

This document describes the architecture and technical design of the `background_downloader` plugin. It is intended for maintainers and contributors who wish to understand the internal workings of the package.

## Overview

The `background_downloader` plugin provides a unified API for downloading and uploading files in the background across Android, iOS, MacOS, Windows, and Linux. The core design philosophy is to leverage native platform capabilities for background execution on mobile (Android/iOS) while providing a robust, Isolate-based implementation for desktop platforms where such native background APIs are different or less standardized.

The plugin consists of:
1.  **Dart Layer**: The public-facing API, state management, and coordination.
2.  **Native Android Layer**: Kotlin implementation using `WorkManager` and `JobScheduler`.
3.  **Native iOS Layer**: Swift implementation using `URLSession`.
4.  **Desktop Layer**: Pure Dart implementation using `Isolate`s and the `http` package.

## Dart Interface & Core Logic

The entry point for the plugin is the `FileDownloader` class, which is a singleton. It delegates actual task execution to a `BaseDownloader` implementation depending on the platform:
*   `NativeDownloader`: For Android and iOS (uses MethodChannels).
*   `DesktopDownloader`: For Windows, Linux, and MacOS (uses Dart Isolates).
*   `WebDownloader`: A stub for web compatibility (functionality is limited/different on web).

### Key Classes

*   **`FileDownloader`**: Singleton facade. Manages the database, updates streams, and delegates commands.
*   **`Task`**: The base class for all operations. Subclasses include `DownloadTask`, `UploadTask`, `MultiUploadTask`, and `ParallelDownloadTask`.
*   **`Database`**: Uses `localstore` (a file-based NoSQL database) to persist tasks and tracking information within the Dart context.
*   **`TaskStatusUpdate` / `TaskProgressUpdate`**: Data classes flowing from the platform implementation back to the Dart layer to notify listeners.

### Communication

Communication between Dart and Native (Android/iOS) layers happens via `MethodChannel`.
*   **Main Channel** (`com.bbflight.background_downloader`): Used for commands sent from Dart to Native (enqueue, cancel, pause, etc.).
*   **Background Channel** (`com.bbflight.background_downloader.background`): Used for callbacks from Native to Dart (status updates, progress updates) and background handler registration.

## Android Implementation

The Android implementation is written in Kotlin and resides in `android/src/main/kotlin/com/bbflight/background_downloader/`. It is designed to work reliably even if the app is terminated.

### Core Components

1.  **`BDPlugin.kt`**: The main plugin class handling `MethodChannel` calls. It manages the `HoldingQueue`.
2.  **`WorkManager` Integration**:
    *   The primary mechanism for background execution is `androidx.work.WorkManager`.
    *   **`TaskWorker`**: A `CoroutineWorker` that wraps the execution logic. It delegates the actual work to a `TaskRunner`.
    *   **`TaskRunner`**: Abstract base class for running tasks. Subclasses like `DownloadTaskRunner`, `UploadTaskRunner`, and `ParallelDownloadTaskRunner` implement specific logic (using `HttpURLConnection` or similar).
3.  **`JobScheduler` (UIDT)**:
    *   For Android 14+ (API 34+), "User Initiated Data Transfer" (UIDT) is supported via `UIDTJobService`. This is used for high-priority tasks requiring immediate execution.
    *   It bypasses `WorkManager` for these specific cases to comply with stricter Android foreground service restrictions.
4.  **`HoldingQueue`**:
    *   A buffer that holds tasks before submitting them to `WorkManager`. This allows for concurrency control (limiting max concurrent downloads) which `WorkManager` does not natively support with the granularity required (e.g., by host or group).
5.  **Notifications**:
    *   `Notifications.kt` handles creating and updating notifications.
    *   Progress updates are throttled to avoid overwhelming the Notification manager.

### Persistence & State

*   Task configurations and states are serialized to JSON and passed to the workers.
*   `SharedPreferences` are used to persist `ResumeData` and status updates that couldn't be immediately delivered to Dart (e.g., if the app was killed).

## iOS Implementation

The iOS implementation is written in Swift and resides in `ios/background_downloader/Sources/background_downloader/`. It relies heavily on `URLSession` with a background configuration.

### Core Components

1.  **`BDPlugin.swift`**: The main plugin class. It handles `MethodChannel` calls and initializes the `URLSession`.
2.  **`UrlSessionDelegate`**:
    *   Implements `URLSessionDelegate`, `URLSessionDownloadDelegate`, and `URLSessionDataDelegate`.
    *   Handles callbacks from the OS regarding task completion, progress, and authentication challenges.
    *   Reconstructs `Task` objects from the `URLSessionTask` descriptions or stored metadata.
3.  **`URLSession`**:
    *   A single `URLSession` with a background configuration (`com.bbflight.background_downloader.Downloader`) is used.
    *   This allows downloads to continue even if the app is suspended or terminated.
    *   On app relaunch, `application:handleEventsForBackgroundURLSession:` reconnects to the session.
4.  **`HoldingQueue`**:
    *   Similar to Android, a `HoldingQueue` manages concurrency before creating `URLSessionTask`s, as `URLSession` executes tasks immediately upon resume.

### Data Flow

*   When a task is enqueued, a `URLSessionDownloadTask` (or `UploadTask`) is created.
*   The `Task` object is serialized to JSON and stored in the `taskDescription` of the `URLSessionTask` (or managed separately if too large).
*   Progress and Status updates are sent back to Dart via the `backgroundChannel`.

## Desktop Implementation

The Desktop implementation (Windows, Linux, MacOS) is written in Dart and resides in `lib/src/desktop/`. Unlike mobile, desktop OSs generally allow long-running processes, so `WorkManager` or `URLSession` equivalents are not used.

### Core Components

1.  **`DesktopDownloader`**:
    *   Manages a queue of tasks (`_queue`, `_running`).
    *   Implements concurrency limits (max concurrent, max per host, max per group).
2.  **Isolates**:
    *   Each download/upload task runs in its own `Isolate` (`doTask` in `isolate.dart`).
    *   This prevents blocking the main UI thread during heavy I/O or processing.
    *   `Isolate.spawn` is used to start the worker.
3.  **`http` Package**:
    *   The standard `package:http` (specifically `package:http/io_client.dart`) is used for network requests.
    *   Custom `HttpClient` is configured for proxies and TLS bypass.

### Persistence

*   There is no "system" persistence for tasks on Desktop. If the app closes, the Isolate dies, and the download stops.
*   The Dart-side `Database` persists the *record* of the task, allowing for resumption (via `Range` headers) upon app restart if logic allows.

## Parallel Downloads

Parallel downloads (chunked downloads) are implemented differently per platform but share the same concept: a large file is split into chunks, downloaded concurrently, and stitched together.

*   **Dart**: `ParallelDownloadTask` is a container.
*   **Android**: `ParallelDownloadTaskWorker` orchestrates multiple child `DownloadTaskWorker`s.
*   **iOS**: `ParallelDownloader` manages multiple `URLSessionTask`s and stitches the result.
*   **Desktop**: The `DesktopDownloader` manages `ParallelDownloadTask` by spawning a supervisor Isolate that spawns child Isolates for chunks.

## Data Persistence Strategy

1.  **Dart Database**:
    *   Used for tracking all tasks, providing `allTasks`, `tasksFinished`, etc.
    *   Implementation: `LocalStore`.
2.  **Native Persistence (Mobile)**:
    *   Mobile platforms persist minimal data (JSON of the Task, Resume Data) to survive process death.
    *   **Android**: `SharedPreferences` + `WorkManager` Data.
    *   **iOS**: `UserDefaults` + `URLSessionTask` metadata.

## Summary of Key Differences

| Feature | Android | iOS | Desktop |
| :--- | :--- | :--- | :--- |
| **Background Engine** | `WorkManager` / `JobScheduler` | `URLSession` (Background) | Dart `Isolate` |
| **Concurrency** | `HoldingQueue` | `HoldingQueue` | Custom Dart Queue |
| **Http Client** | `HttpURLConnection` (via Runners) | `URLSession` | `package:http` |
| **Persistence** | System (survives reboot/kill) | System (survives kill) | App Lifecycle only |
