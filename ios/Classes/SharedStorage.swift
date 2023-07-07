//
//  SharedStorage.swift
//  background_downloader
//
//  Created on 3/26/23.
//

import Foundation
import os.log

public enum SharedStorage: Int {
    case downloads,
         images,
         video,
         audio,
         files,
         external
}

/// Move file at [filePath] to shared storage [destination] with optional [directory]
public func moveToSharedStorage(filePath: String, destination: SharedStorage, directory: String) -> String? {
    guard FileManager().fileExists(atPath: filePath)
    else {
        os_log("Cannot move to shared storage: file %@ does not exist", log: log, type: .error, filePath)
        return nil
    }
    let fileUrl = NSURL(fileURLWithPath: filePath)
    guard let directory = try? directoryForSharedStorage(destination: destination, directory: directory) else {
        os_log("Cannot move to shared storage: no permission for directory %@", log: log, type: .error, directory)
        return nil
    }
    if !FileManager.default.fileExists(atPath: directory.path) {
        do
        {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories:  true)
        } catch {
            os_log("Cannot move to shared storage: failed to create directory %@: %@", log: log, type: .error, directory.path, error.localizedDescription)
            return nil
        }
    }
    let destUrl = directory.appendingPathComponent((filePath as NSString).lastPathComponent, isDirectory: false)
    if FileManager.default.fileExists(atPath: destUrl.path) {
        try? FileManager.default.removeItem(at: destUrl)
    }
    do {
        try FileManager.default.moveItem(at: fileUrl as URL, to: destUrl)
    } catch {
        os_log("Failed to move file %@ to %@: %@", log: log, type: .error, filePath, destUrl.path, error.localizedDescription)
        return nil
    }
    os_log("Moved from %@ to %@", log: log, type: .info, fileUrl, destUrl.path)
    return destUrl.path
}

/// Returns the path to the file at [filePath] in shared storage [destination] subdir [directory], or null
public func pathInSharedStorage(filePath: String, destination: SharedStorage, directory: String) -> String? {
    guard let directory = try? directoryForSharedStorage(destination: destination, directory: directory) else {
        os_log("Cannot determine path in shared storage: no permission for directory %@", log: log, type: .info, directory)
        return nil
    }
    let destUrl = directory.appendingPathComponent((filePath as NSString).lastPathComponent)
    return destUrl.path
}


/// Returns the URL of the directory associated with the [destination] and [directory], or nil
public func directoryForSharedStorage(destination: SharedStorage, directory: String) throws ->  URL? {
    var dir: String
    switch destination {
    case .downloads:
        dir = "Downloads"
    case .images:
        dir = "Pictures"
    case .video:
        dir = "Movies"
    case .audio:
        dir = "Music"
    case .files, .external:
        os_log("Destination .files and .external are not supported on iOS", log: log, type: .info)
        return nil
        
    }
    let documentsURL =
        try? FileManager.default.url(for: FileManager.SearchPathDirectory.documentDirectory,
                                 in: .userDomainMask,
                                 appropriateFor: nil,
                                 create: true)
    return directory.isEmpty
        ? documentsURL?.appendingPathComponent(dir)
        : documentsURL?.appendingPathComponent(dir).appendingPathComponent(directory)
}
