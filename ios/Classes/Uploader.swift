//
//  Uploader.swift
//  background_downloader
//
//  Created on 2/11/23.
//

import Foundation
import os.log

enum StreamError: Error {
    case Closed
}

/// Uploader associated with one URLSessionUploadTask
public class Uploader : NSObject, URLSessionTaskDelegate, StreamDelegate {
    
//    let log = OSLog.init(subsystem: "FileDownloaderPlugin", category: "Uploader")
    
    var task: Task
    let outputFilename: String
    var contentDispositionString: String = ""
    var contentTypeString: String = ""
    var totalBytesWritten: Int64 = 0
    static let boundary = "-----background_downloader-akjhfw281onqciyhnIk"
    let lineFeed = "\r\n"

    let bufferSize = 8192
    
    
    /// Initialize an Uploader for this Task and urlSessionTaskIdentifies
    init(task: Task) {
        self.task = task
        outputFilename = NSUUID().uuidString
    }
    
    /// Creates the multipart file so it can be uploaded
    ///
    /// Returns true if successful, false otherwise
    public func createMultipartFile() -> Bool {
        // Create and open the fileInputStream
        guard let directory = try? directoryForTask(task: task)  else {return false}
        let fileUrl = directory.appendingPathComponent(task.filename)
        let resourceValues = try? fileUrl.resourceValues(forKeys: [.fileSizeKey])
        let fileSize = Int64(resourceValues?.fileSize ?? 0)
        guard let inputStream = InputStream(url: fileUrl) else {
            os_log("Could not open file to upload", log: log, type: .info)
            return false
        }
        // determine the file related components of the preamble
        contentDispositionString =
        "Content-Disposition: form-data; name=\"file\"; filename=\"\(task.filename)\""
        let mimeType = mimeType(url: fileUrl)
        contentTypeString = "Content-Type: \(mimeType.isEmpty ? "application/octet-stream" : mimeType)"
        // create the output file and write preamble, file bytes and epilogue
        FileManager.default.createFile(atPath: outputFileUrl().path,  contents:Data(" ".utf8), attributes: nil)
        guard let fileHandle = try? FileHandle(forWritingTo: outputFileUrl()) else {
            os_log("Could not open temporary file %@", log: log, type: .error, outputFileUrl().path)
            return false
        }
        return writePreamble(fileHandle: fileHandle) && writeFileBytes(fileHandle: fileHandle, inputStream: inputStream) && writeEpilogue(fileHandle: fileHandle)
    }
    
    /// Return the URL of the generated outputfile with multipart data
    ///
    /// Should only be called after calling createMultipartFile, and only when that returns true
    func outputFileUrl() -> URL {
        return FileManager.default.temporaryDirectory.appendingPathComponent(outputFilename)
    }
    
    
    /// Write the preamble for the multipart form to the fileHandle
    ///
    /// Writes content disposition and content type preceded by the boundary, and calculates totalBytesExpectedToWrite
    ///
    /// Returns true if successful, false otherwise
    private func writePreamble(fileHandle: FileHandle) -> Bool {
        // construct the preamble
        guard let preamble = "--\(Uploader.boundary)\(lineFeed)\(contentDispositionString)\(lineFeed)\(contentTypeString)\(lineFeed)\(lineFeed)".data(using: .utf8) else {
            os_log("Could not create preamble")
            return false
        }
        fileHandle.write(preamble)
        totalBytesWritten += Int64(preamble.count)
        return true
    }
    
    /// Write the data bytes from the provided inputStream to the fileHandle
    ///
    /// Retruns true if successful, false otherwise
    private func writeFileBytes(fileHandle: FileHandle, inputStream: InputStream) -> Bool {
        inputStream.open()
        while inputStream.hasBytesAvailable {
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer {
                buffer.deallocate()
            }
            let bytesRead = inputStream.read(buffer, maxLength: bufferSize)
            if bytesRead < 0 {
                // Stream error occured
                os_log("Error reading from file for taskId %@", log: log, type: .info, task.taskId)
                inputStream.close()
                return false
            } else if bytesRead == 0 {
                inputStream.close()
                return true
            }
            let data = Data.init(bytesNoCopy: buffer, count: bytesRead, deallocator: .none)
            fileHandle.write(data)
        }
        inputStream.close()
        return true
    }
    
    /// Write the final portion of the request body to the fileHandle
    ///
    /// Retruns true if successful, false otherwise
    private func writeEpilogue(fileHandle: FileHandle) -> Bool {
        guard let epilogue = "\(lineFeed)--\(Uploader.boundary)--\(lineFeed)".data(using: .utf8) else {
            os_log("Could not create epilogue")
            return false
        }
        fileHandle.write(epilogue)
        totalBytesWritten += Int64(epilogue.count)
        return true
    }
    
}
