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
    
    var task: Task
    let outputFilename: String
    var contentDispositionString = ""
    var contentTypeString = ""
    var fieldsString = ""
    var totalBytesWritten: Int64 = 0
    static let boundary = "-----background_downloader-akjhfw281onqciyhnIk"
    let lineFeed = "\r\n"
    let asciiOnly = try! NSRegularExpression(pattern: "^[\\x00-\\x7F]+$")
    let newlineRegExp = try! NSRegularExpression(pattern: "\r\n|\r|\n")
    let bufferSize = 2 << 13
    
    
    /// Initialize an Uploader for this Task
    init(task: Task) {
        self.task = task
        outputFilename = NSUUID().uuidString
    }
    
    
    /// Creates the multipart file so it can be uploaded
    ///
    /// Returns true if successful, false otherwise
    public func createMultipartFile() -> Bool {
        // create the output file
        FileManager.default.createFile(atPath: outputFileUrl().path,  contents:Data(" ".utf8), attributes: nil)
        guard let fileHandle = try? FileHandle(forWritingTo: outputFileUrl()) else {
            os_log("Could not open temporary file %@", log: log, type: .error, outputFileUrl().path)
            return false
        }
        // field portion of the multipart
        for entry in task.fields ?? [:] {
            fieldsString += fieldEntry(name: entry.key, value: entry.value)
        }
        if (!writeFields(fileHandle: fileHandle)) {
            os_log("Could not write to temporary file %@", log: log, type: .error, outputFileUrl().path)
            return false
        }
        // File portion of the multi-part
        // Assumes list of files. If only one file, that becomes a list of length one.
        // For each file, determine contentDispositionString, contentTypeString
        // and file length, so that we can calculate total size of upload
        let separator = "\(lineFeed)--\(Uploader.boundary)\(lineFeed)" // between files
        let terminator = "\(lineFeed)--\(Uploader.boundary)--\(lineFeed)" // after last file
        guard let filePath = getFilePath(for: task) else {return false}
        let filesData = filePath.isEmpty
        ? extractFilesData(task: task) // MultiUpload case
        : [(task.fileField!, filePath, task.mimeType!)] // one file Upload case
        for (fileField, path, mimeType) in filesData {
            if !FileManager.default.fileExists(atPath: path) {
                os_log("File to upload does not exist at %@", log: log, type: .error, path)
                return false
            }
            let contentDispositionString =
            "Content-Disposition: form-data; name=\"\(browserEncode(fileField))\"; "
            + "filename=\"\(browserEncode(path.components(separatedBy: "/").last!))\"\(lineFeed)"
            let contentTypeString = "Content-Type: \(mimeType)\(lineFeed)\(lineFeed)"
            let fileUrl = URL(fileURLWithPath: path)
            guard let inputStream = InputStream(url: fileUrl) else {
                os_log("Could not open file to upload at %@", log: log, type: .error, path)
                return false
            }
            if (!writeFileBytes(fileHandle: fileHandle, inputStream: inputStream, contentDisposition: contentDispositionString, contentType: contentTypeString)) {
                os_log("Could not upload file at %@", log: log, type: .error, path)
                return false
            }
            if (!writeText(fileHandle: fileHandle, text: path == filesData.last!.1 ?
                           terminator : separator)) {
                os_log("Could not write separator for file at %@", log: log, type: .error, path)
                return false
            }
        }
        return true
    }
    
    /// Return the URL of the generated outputfile with multipart data
    ///
    /// Should only be called after calling createMultipartFile, and only when that returns true
    func outputFileUrl() -> URL {
        return FileManager.default.temporaryDirectory.appendingPathComponent(outputFilename)
    }
    
    /// Write form fields
    ///
    /// Returns true if successful, false otherwise
    private func writeFields(fileHandle: FileHandle) -> Bool {
        // construct the preamble
        return writeText(fileHandle: fileHandle, text: "\(fieldsString)--\(Uploader.boundary)\(lineFeed)")
    }
    
    /// Write the data bytes from the provided inputStream to the fileHandle
    ///
    /// Retruns true if successful, false otherwise
    private func writeFileBytes(fileHandle: FileHandle, inputStream: InputStream, contentDisposition: String, contentType: String) -> Bool {
        // multipart file header
        if !(writeText(fileHandle: fileHandle, text: contentDisposition) &&
             writeText(fileHandle: fileHandle, text: contentType)) {
            return false
        }
        // file bytes
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
    
    /// Write text to the [fileHandle] and return true if successful
    private func writeText(fileHandle: FileHandle, text: String) -> Bool {
        guard let epilogue = text.data(using: .utf8) else {
            os_log("Could not create text")
            return false
        }
        fileHandle.write(epilogue)
        totalBytesWritten += Int64(epilogue.count)
        return true
    }
    
    
    /// Returns the multipart entry for one field name/value pair
    private func fieldEntry(name: String, value: String) -> String {
        return "--\(Uploader.boundary)\(lineFeed)\(headerForField(name: name, value: value))\(value)\(lineFeed)"
    }
    
    /// Returns the header string for a field
    ///
    /// The return value is guaranteed to contain only ASCII characters
    private func headerForField(name: String, value: String) -> String {
        var header = "content-disposition: form-data; name=\"\(browserEncode(name))\""
        if (!isPlainAscii(value)) {
            header = "\(header)\r\n" +
            "content-type: text/plain; charset=utf-8\r\n" +
            "content-transfer-encoding: binary"
        }
        return "\(header)\r\n\r\n"
    }
    
    
    /// Returns whether [string] is composed entirely of ASCII-compatible characters
    private func isPlainAscii(_ string: String)-> Bool {
        let result = asciiOnly.matches(in: string,
                                       range: NSMakeRange(0, (string as NSString).length))
        return !result.isEmpty
    }
    
    /// Encode [value] in the same way browsers do
    private func browserEncode(_ value: String)-> String {
        // http://tools.ietf.org/html/rfc2388 mandates some complex encodings for
        // field names and file names, but in practice user agents seem not to
        // follow this at all. Instead, they URL-encode `\r`, `\n`, and `\r\n` as
        // `\r\n`; URL-encode `"`; and do nothing else (even for `%` or non-ASCII
        // characters). We follow their behavior.
        let newlinesReplaced = newlineRegExp.stringByReplacingMatches(
            in: value,
            options: [],
            range: NSMakeRange(0, (value as NSString).length), withTemplate: "%0D%0A")
        return newlinesReplaced.replacingOccurrences(of: "\"", with: "%22")
    }
    
}


