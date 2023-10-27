//
//  SharedStorage.swift
//  background_downloader
//
//  Created on 3/26/23.
//

import Foundation
import os.log
import Photos

public enum SharedStorage: Int {
    case downloads,
         images,
         video,
         audio,
         files,
         external
}

/// Move file at [filePath] to shared storage [destination] with optional [directory]
public func moveToSharedStorage(filePath: String, destination: SharedStorage, directory: String, complete: @escaping (String?) -> Void) {
    switch destination {
    case .images:
        saveImageToPhotos(filePath: filePath, complete: complete)
    case .video:
        saveVideoToPhotos(filePath: filePath, complete: complete)
    default:
        complete(moveToFakeSharedStorage(filePath: filePath, destination: destination, directory: directory))
    }
}

private func saveImageToPhotos(filePath: String, complete: @escaping (String?) -> Void) {
    var localId: String?

    PHPhotoLibrary.shared().performChanges({
        guard let fileURL: URL = URL(string: filePath) else {
            complete(nil)
            return
        }

        let assetChangeRequest = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
        localId = assetChangeRequest?.placeholderForCreatedAsset?.localIdentifier
    }) { saved, _ in
        guard saved, let unwrappedId = localId else {
            complete(nil)
            return
        }

        let assetResult: PHFetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [unwrappedId], options: nil)

        guard let asset = assetResult.firstObject else {
            complete(nil)
            return
        }

        asset.requestContentEditingInput(with: nil, completionHandler: { input, _ in
            complete(input?.fullSizeImageURL?.path)
        })
    }
}

private func saveVideoToPhotos(filePath: String, complete: @escaping (String?) -> Void) {
    var localId: String?

    PHPhotoLibrary.shared().performChanges({
        guard let fileURL: URL = URL(string: filePath) else {
            os_log("not a valid URL %@", log: log, type: .error, filePath)
            complete(nil)
            return
        }

        let assetChangeRequest = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
        localId = assetChangeRequest?.placeholderForCreatedAsset?.localIdentifier
    }) { (saved, error: Error?) in
        guard saved, let unwrappedId = localId else {
            if let unwrappedError = error {
                os_log("not saved %@", log: log, type: .info, String(describing: unwrappedError))
            }
            complete(nil)
            return
        }

        let assetResult: PHFetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [unwrappedId], options: nil)

        guard let asset = assetResult.firstObject else {
            os_log("no assets found", log: log, type: .info)
            complete(nil)
            return
        }

        asset.requestContentEditingInput(with: nil, completionHandler: { input, _ in
            if let urlAsset = input?.audiovisualAsset as? AVURLAsset {
                complete(urlAsset.url.path)
            } else {
                complete(nil)
            }
        })
    }
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

private func moveToFakeSharedStorage(filePath: String, destination: SharedStorage, directory: String) -> String? {
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
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
