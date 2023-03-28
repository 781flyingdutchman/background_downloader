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
        os_log("Cannot move to shared storage: file %@ does not exist", log: log, type: .info, filePath)
        return nil
    }
    let fileUrl = NSURL(fileURLWithPath: filePath)
    guard let directory = try? directoryForSharedStorage(destination: destination, directory: directory) else {
        os_log("Cannot move to shared storage: no permission for directory %@", log: log, type: .info, directory)
        return nil
    }
    do
    {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories:  true)
    } catch {
        os_log("Failed to create directory %@: %@", log: log, type: .error, directory.path, error.localizedDescription)
        return nil
    }
    let destUrl = directory.appendingPathComponent((filePath as NSString).lastPathComponent)
    do {
        try FileManager.default.moveItem(at: fileUrl as URL, to: destUrl)
    } catch {
        os_log("Failed to move file %@: %@", log: log, type: .error, filePath, error.localizedDescription)
        return nil
    }
    os_log("Moved from %@ to %@", log: log, type: .info, fileUrl, destUrl.path)
    return destUrl.path
}


/// Returns the URL of the directory associated with the [destination] and [directory], or nil
public func directoryForSharedStorage(destination: SharedStorage, directory: String) throws ->  URL? {
    var dir: FileManager.SearchPathDirectory
    switch destination {
    case .downloads:
        dir = .downloadsDirectory
    case .images:
        dir = .picturesDirectory
    case .video:
        dir = .moviesDirectory
    case .audio:
        dir = .musicDirectory
    case .files, .external:
        os_log("Cannot move to shared storage: destination .files and .external are not supported on iOS", log: log, type: .info)
        return nil
        
    }
    let documentsURL =
    try FileManager.default.url(for: dir,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: false)
    return directory.isEmpty
    ? documentsURL
    : documentsURL.appendingPathComponent(directory)
}
