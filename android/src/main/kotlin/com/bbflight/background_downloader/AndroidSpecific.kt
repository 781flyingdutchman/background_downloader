package com.bbflight.background_downloader

/// Scoped Storage destinations for Android
enum class ScopedStorage { files, downloads, images, video, audio, external }

/**
 * Moves the file from filePath to the scoped storage destination and returns true if successful
 */
fun moveToScopedStorage(filePath: String, destination: ScopedStorage) : Boolean {
    //TODO move the file from filePath to the scoped storage destination
    return false
}