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
    
    let log = OSLog.init(subsystem: "FileDownloaderPlugin", category: "Uploader")
    
    var task: Task
    var urlSessionTaskIdentifier: Int
    var fileUrl: URL?
    var fileInputStream: InputStream?
    var fileSize: Int64 = 0
    var contentDispositionString: String
    var contentTypeString: String
    var totalBytesExpectedToSend: Int64 = 0
    var haveWrittenPreamble = false
    var haveWrittenEpilogue = false
    var haveSentFinalState = false // if true, don't send another .complete, .failed or .canceled
    static let boundary = "-----background_downloader-akjhfw281onqciyhnIk"
    let lineFeed = "\r\n"
    
    let bufferSize = 8192
    
    struct Streams {
        let input: InputStream
        let output: OutputStream
    }
    var boundStreams: Streams?
    
    /// Initialize an Uploader for this Task and urlSessionTaskIdentifies
    init(task: Task, urlSessionTaskIdentifier: Int) {
        self.task = task
        self.urlSessionTaskIdentifier = urlSessionTaskIdentifier
        let directory = try? directoryForTask(task: task)
        fileUrl = directory?.appendingPathComponent(task.filename)
        let resourceValues = try? fileUrl!.resourceValues(forKeys: [.fileSizeKey])
        fileSize = Int64(resourceValues?.fileSize ?? 0)
        contentDispositionString =
        "Content-Disposition: form-data; name=\"file\"; filename=\"\(task.filename)\""
        let mimeType = fileUrl != nil ? mimeType(url: fileUrl!) : ""
        contentTypeString = "Content-Type: \(mimeType.isEmpty ? "application/octet-stream" : mimeType)"
        // determine the content length of the multi-part data
        totalBytesExpectedToSend =
            Int64(
                2 * Uploader.boundary.count + 6 * lineFeed.count + contentDispositionString.count
                + contentTypeString.count + 3 * "--".count
            ) + fileSize
    }
    
    /// Start the upload task by opening the inputstream on the file
    ///
    /// Returns true if successful, false otherwise
    public func start() -> Bool {
        // Create the fileInputStream
        guard let directory = try? directoryForTask(task: task) else {return false}
        fileUrl = directory.appendingPathComponent(task.filename)
        let resourceValues = try? fileUrl!.resourceValues(forKeys: [.fileSizeKey])
        fileSize = Int64(resourceValues?.fileSize ?? 0)
        fileInputStream = InputStream(url: fileUrl!)
        fileInputStream?.open()
        os_log("File size = %d bytes", log: self.log, fileSize)
        // create the bound streams
        os_log("Initializing boundStreams", log: self.log)
        var inputOrNil: InputStream? = nil
        var outputOrNil: OutputStream? = nil
        Stream.getBoundStreams(withBufferSize: bufferSize,
                               inputStream: &inputOrNil,
                               outputStream: &outputOrNil)
        guard let input = inputOrNil, let output = outputOrNil else {
            fatalError("On return of `getBoundStreams`, both `inputStream` and `outputStream` will contain non-nil streams.")
        }
        boundStreams = Streams(input: input, output: output)
        // configure and open output stream
        output.delegate = self
        output.schedule(in: .current, forMode: .default)
        output.open()
        RunLoop.current.run(until: Date().addingTimeInterval(5.0))
        os_log("Opened output stream", log: self.log)
        return true
    }
    
    /// Finalize the upload with [status]
    ///
    /// Closes all streams, sends the final status update for the task and removes the Uploader object
    /// from the Downloader, as the task has finished
    func finish(status: TaskStatus?) {
        os_log("Finishing Uploader", log: self.log)
        fileInputStream?.close()
        self.boundStreams?.output.close()
        self.boundStreams?.input.close()
        if status != nil && !haveSentFinalState {
            processStatusUpdate(task: self.task, status: status!)
            if isFinalState(status: status!) {
                haveSentFinalState = true
            }
        }
    }
    
    /// Clean up references to this Uploader and Task
    ///
    /// Call this at the end of the task
    func cleanUp() {
        Downloader.uploaderForUrlSessionTaskIdentifier.removeValue(forKey: urlSessionTaskIdentifier)
        Downloader.lastProgressUpdate.removeValue(forKey: task.taskId)
        Downloader.nextProgressUpdateTime.removeValue(forKey: task.taskId)
    }
    
    
    //MARK: MStreamDelegate
    
    public func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        guard aStream == self.boundStreams?.output else {
            os_log("Not my stream", log: self.log)
            return
        }
        switch (eventCode) {
        case Stream.Event.hasSpaceAvailable:
            os_log("Has space available", log: self.log)
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer {
                buffer.deallocate()
            }
            if haveWrittenPreamble {
                if haveWrittenEpilogue {
                    finish(status: nil)
                    return
                }
                os_log("Write raw bytes", log: self.log)
                // after the preamble, write the file as raw bytes to the output stream
                guard let inputStream = fileInputStream else {
                    os_log("File not available for taskId %@", log: self.log, type: .info, task.taskId)
                    finish(status: TaskStatus.failed)
                    return
                }
                guard let boundStreams = self.boundStreams else {
                    os_log("Streams unavailable", log: self.log, type: .error)
                    finish(status: TaskStatus.failed)
                    return
                }
                if inputStream.hasBytesAvailable {
                    os_log("Bytes available", log: self.log)
                    let bytesRead = inputStream.read(buffer, maxLength: bufferSize)
                    if bytesRead < 0 {
                        // Stream error occured
                        os_log("Error reading from file for taskId %@", log: self.log, type: .info, task.taskId)
                        finish(status: TaskStatus.failed)
                        return
                    } else if bytesRead == 0 {
                        // end of file. Note the '.complete' status update is generated
                        // when the task ends
                        os_log("End of file", log: self.log, type: .info)
                        writeEpilogue()
                        return
                    }
                    // normal case: write bytes and send progress update if needed
                    let bytesWritten = boundStreams.output.write(buffer, maxLength: bytesRead)
                    os_log("Wrote %d raw bytes", log: self.log, type: .info, bytesWritten)
                    if bytesWritten != bytesRead {
                        os_log("Mismatch bytes written %d vs read %d", log: self.log, type: .info, bytesWritten, bytesRead)
                        finish(status: TaskStatus.failed)
                        return
                    }
                    return
                }
                // no more bytes available, so write epilogue
                writeEpilogue()
                return
            }
            // before writing the file bytes, write the preamble for multipart form
            writePreamble()
            return
        case Stream.Event.errorOccurred:
            os_log("Error occured in stream for taskId %@", log: self.log, type: .error, task.taskId)
            finish(status: TaskStatus.failed)
        default:
            os_log("Unknown stream event", log: self.log, type: .info)
        }
    }
    
    /// Write the preamble for the multipart form
    ///
    /// Writes content disposition and content type preceded by the boundary, and calculates totalBytesExpectedToWrite
    private func writePreamble() {
        os_log("Writing preamble", log: self.log)
        // construct the preamble
        let preamble = "--\(Uploader.boundary)\(lineFeed)\(contentDispositionString)\(lineFeed)\(contentTypeString)\(lineFeed)\(lineFeed)"
        os_log("Preamble= %@", log: self.log, type: .info, preamble)
        guard let data = preamble.data(using: .utf8) else {
            finish(status: TaskStatus.failed)
            os_log("Could not convert preamble to data", log: self.log, type: .error)
            return
        }
        do {
            try self.boundStreams?.output.write(data: data)
            haveWrittenPreamble = true
        } catch {
            os_log("Error writing preamble")
            finish(status: TaskStatus.failed)
        }
    }
    
    /// Write final portion of the request body
    private func writeEpilogue() {
        os_log("Writing epilogue", log: self.log)
        let epilogue = "\(lineFeed)--\(Uploader.boundary)--\(lineFeed)"
        guard let data = epilogue.data(using: .utf8) else {
            finish(status: TaskStatus.failed)
            os_log("Could not convert epilogue to data", log: self.log, type: .error)
            return
        }
        do {
            try self.boundStreams?.output.write(data: data)
            haveWrittenEpilogue = true
        } catch {
            os_log("Error writing epilogue")
            finish(status: TaskStatus.failed)
        }
    }
    
}

/// Helper extension to write Data to an OuputStream
extension OutputStream {
    
    /// Write data to an outputStream
    func write(data: Data) throws {
        var remaining = data[...]
        while !remaining.isEmpty {
            let bytesWritten = remaining.withUnsafeBytes { buf in
                // The force unwrap is safe because we know that `remaining` is
                // not empty
                self.write(
                    buf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    maxLength: buf.count
                )
            }
            guard bytesWritten >= 0 else {
                throw StreamError.Closed
            }
            remaining = remaining.dropFirst(bytesWritten)
        }
    }
}
