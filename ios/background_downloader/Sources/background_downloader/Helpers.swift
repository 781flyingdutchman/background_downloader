//
//  Helpers.swift
//  background_downloader
//
//  Created by Bram on 12/31/23.
//

import Foundation
import os.log

extension URL {
    /// Uses .appending for iOS 16 and up, and .appendingPathComponent
    /// for earlier versions
    func appendingPath(_ component: String, isDirectory: Bool = false) -> URL {
        if #available(iOS 16.0, *) {
            return appending(path: component, directoryHint: isDirectory ? .isDirectory : .notDirectory)
        } else {
            return appendingPathComponent(component, isDirectory: isDirectory)
        }
    }
    
    /// Excludes URL from backup
    mutating func setCloudBackup(exclude: Bool) throws {
        var resource = URLResourceValues()
        resource.isExcludedFromBackup = exclude
        try self.setResourceValues(resource)
    }
}

/// Returns the task's URL if it can be parsed, otherwise null
func validateUrl(_ task: Task) -> URL? {
    let url: URL?
    // encodingInvalidCharacters is only available when compiling with Xcode 15, which uses Swift version 5.9
#if swift(>=5.9)
    if #available(iOS 17.0, *) {
        url = URL(string: task.url, encodingInvalidCharacters: false)
    } else {
        url = URL(string: task.url)
    }
#else
    url = URL(string: task.url)
#endif
    return url
}

/// Converts the [map] to a [String:String] map with lowercased keys
func lowerCasedStringStringMap(_ map: [AnyHashable: Any]?) -> [String: String]? {
    if map == nil {return nil}
    var result: [String: String] = [:]
    for (key, value) in map! {
        if let stringKey = key as? String, let stringValue = value as? String {
            result[stringKey.lowercased()] = stringValue
        }
    }
    return result
}

/// Create a temp file that contains a subset of the [fileURL] based on [start] and [contentLength]
///
/// Returns the URL of the temp file, or nil if there was a problem (problem is logged)
func createTempFileWithRange(from fileURL: URL, start: UInt64, contentLength: UInt64) -> URL? {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory
    let tempFileURL = tempDir.appendingPathComponent(UUID().uuidString) // Create a unique temporary file
    
    // Create the temporary file
    fileManager.createFile(atPath: tempFileURL.path, contents: nil, attributes: nil)
    guard let inputStream = InputStream(url: fileURL),
          let outputStream = OutputStream(toFileAtPath: tempFileURL.path, append: false) else {
        os_log("Cannot create input or output stream for partial upload temporary file creation", log: log, type: .error)
        return nil
    }
    inputStream.open()
    outputStream.open()
    defer {
        inputStream.close()
        outputStream.close()
    }
    let chunkSize = 1024 * 1024 // 1MB chunks
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
    defer { buffer.deallocate() }
    var remainingBytes = contentLength
    var totalRead: UInt64 = 0
    
    // Seek to the start position
    while totalRead < start {
        let seekBytes = min(chunkSize, Int(start - totalRead))
        let bytesRead = inputStream.read(buffer, maxLength: seekBytes)
        if bytesRead < 0 {
            os_log("Cannot read data up to desired start from original file for partial upload temporary file creation", log: log, type: .error)
            return nil
        }
        if bytesRead == 0 { break } // EOF
        totalRead += UInt64(bytesRead)
    }
    
    // Read only the required range
    while remainingBytes > 0 {
        let bytesToRead = min(chunkSize, Int(remainingBytes))
        let bytesRead = inputStream.read(buffer, maxLength: bytesToRead)
        if bytesRead <= 0 { break } // EOF
        let bytesWritten = outputStream.write(buffer, maxLength: bytesRead)
        if bytesWritten < 0 {
            os_log("Cannot write data to new temporary file for partial upload", log: log, type: .error)
            return nil
        }
        remainingBytes -= UInt64(bytesWritten)
    }
    return tempFileURL
}
