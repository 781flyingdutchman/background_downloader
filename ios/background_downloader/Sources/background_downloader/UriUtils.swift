//
//  UriUtils.swift
//  background_downloader
//
//  Created by Bram on 1/18/25.
//

import Flutter
import UIKit
import UniformTypeIdentifiers
import MobileCoreServices
import PhotosUI
import os.log



public class UriUtilsMethodCallHelper: NSObject,
                                       FlutterPlugin,
                                       UIDocumentPickerDelegate,
                                       PHPickerViewControllerDelegate {
    private var flutterResult: FlutterResult?
    private var persistedUriPermission: Bool = false
    private var multipleAllowed: Bool = false
    private var accessedSecurityScopedUrls: Set<URL> = Set()
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "com.bbflight.background_downloader.uriutils", binaryMessenger: registrar.messenger())
        let instance = UriUtilsMethodCallHelper()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "pickDirectory":
            pickDirectory(call, result: result)
        case "pickFiles":
            pickFiles(call, result: result)
        case "createDirectory":
            createDirectory(call, result: result)
        case "getFileBytes":
            if let uriString = call.arguments as? String {
                result(getFileBytes(uriString: uriString))
            } else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Invalid arguments for getFile", details: nil))
            }
        case "deleteFile":
            deleteFile(call, result: result)
        case "openFile":
            openFile(call, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    private func pickDirectory(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [Any],
              let persistedUriPermission = args[2] as? Bool else {
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "Invalid arguments for pickDirectory", details: nil))
            return
        }
        
        self.persistedUriPermission = persistedUriPermission
        self.flutterResult = result
        
        var startLocation: URL? = nil
        
        if let startLocationUriString = args[1] as? String,
           let startLocationUri = decodePossibleBookmarkUriString(uriString: startLocationUriString) {
            startLocation = startLocationUri
        } else if let startLocationOrdinal = args[0] as? Int,
                  let sharedStorage = SharedStorage(rawValue: startLocationOrdinal) {
            startLocation = getInitialDirectoryUrl(location: sharedStorage)
        }
        
        let documentPicker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder], asCopy: false)
        documentPicker.delegate = self
        documentPicker.allowsMultipleSelection = false
        
        // Set the initial directory if available
        if #available(iOS 14.0, *), let startLocation = startLocation {
            documentPicker.directoryURL = startLocation
        }
        
        // Present the document picker
        if let rootViewController = UIApplication.shared.keyWindow?.rootViewController {
            rootViewController.present(documentPicker, animated: true, completion: nil)
        } else {
            result(FlutterError(code: "NO_ROOT_VIEW_CONTROLLER", message: "Could not find root view controller", details: nil))
            flutterResult = nil
        }
    }
    
    
    private func pickFiles(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [Any],
              let multipleAllowed = args[3] as? Bool,
              let persistedUriPermission = args[4] as? Bool else {
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "Invalid arguments for pickFiles", details: nil))
            return
        }
        
        self.persistedUriPermission = persistedUriPermission
        self.multipleAllowed = multipleAllowed
        self.flutterResult = result
        
        var startLocation: URL? = nil
        
        if let startLocationUriString = args[1] as? String,
           let startLocationUri = decodePossibleBookmarkUriString(uriString: startLocationUriString) {
            startLocation = startLocationUri
        } else if let startLocationOrdinal = args[0] as? Int,
                  let sharedStorage = SharedStorage(rawValue: startLocationOrdinal) {
            if sharedStorage == .images || sharedStorage == .video {
                pickMedia(startLocation: sharedStorage)
                return
            }
            startLocation = getInitialDirectoryUrl(location: sharedStorage)
        }
        
        // Convert allowed extensions to UTTypes
        var allowedContentTypes: [UTType] = []
        if let allowedExtensions = args[2] as? [String] {
            for ext in allowedExtensions {
                if let utType = UTType(filenameExtension: ext) {
                    allowedContentTypes.append(utType)
                }
            }
        }
        if allowedContentTypes.isEmpty {
            allowedContentTypes = [UTType.item]  // Allow all types if no valid extensions are provided
        }
        
        let documentPicker = UIDocumentPickerViewController(forOpeningContentTypes: allowedContentTypes, asCopy: false)
        documentPicker.delegate = self
        documentPicker.allowsMultipleSelection = multipleAllowed
        
        // Set the initial directory if available
        if let startLocation = startLocation {
            documentPicker.directoryURL = startLocation
        }
        
        // Present the document picker
        if let rootViewController = UIApplication.shared.keyWindow?.rootViewController {
            rootViewController.present(documentPicker, animated: true, completion: nil)
        } else {
            result(FlutterError(code: "NO_ROOT_VIEW_CONTROLLER", message: "Could not find root view controller", details: nil))
            flutterResult = nil
        }
    }
    
    /**
     * Launches the photo picker to select one or more media files (images or videos).
     *
     * Called only from [pickFiles] where argument
     * parsing has already happened
     *
     * @param startLocation The shared storage location to start the picker in (images or video).
     *
     * The result posted back is either a list of URIs as a String, or null (if the user has
     * cancelled the picker) or an error
     */
    private func pickMedia(startLocation: SharedStorage) {
        var configuration = PHPickerConfiguration()
        configuration.filter = startLocation == .images ? .images : .videos
        configuration.selectionLimit = multipleAllowed ? 0 : 1  // 0 means unlimited
        let pickerViewController = PHPickerViewController(configuration: configuration)
        pickerViewController.delegate = self

        if let rootViewController = UIApplication.shared.keyWindow?.rootViewController {
            rootViewController.present(pickerViewController, animated: true, completion: nil)
        } else {
            flutterResult?(FlutterError(code: "NO_ROOT_VIEW_CONTROLLER", message: "Could not find root view controller", details: nil))
            flutterResult = nil
        }
    }

    
    
    private func createDirectory(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [Any],
              let parentDirectoryUriString = args[0] as? String,
              let newDirectoryName = args[1] as? String,
              let persistedUriPermission = args[2] as? Bool,
              let parentDirectoryUri = decodePossibleBookmarkUriString(uriString: parentDirectoryUriString)
        else {
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "Invalid arguments for createDirectory", details: nil))
            return
        }
        
        do {
            let newDirectoryURL = parentDirectoryUri.appendingPathComponent(newDirectoryName, isDirectory: true)
            
            // Ensure we have access to the parent directory before attempting to create a subdirectory.
            if !parentDirectoryUri.startAccessingSecurityScopedResource() {
                result(FlutterError(code: "ACCESS_DENIED", message: "Failed to access parent directory: \(parentDirectoryUri)", details: nil))
                return
            }
            accessedSecurityScopedUrls.insert(parentDirectoryUri)
            
            // Create the directory
            try FileManager.default.createDirectory(at: newDirectoryURL, withIntermediateDirectories: true, attributes: nil)
            
            // If persistence is requested, we will also need to stop accessing and deallocate the URL when done.
            if persistedUriPermission {
                accessedSecurityScopedUrls.insert(newDirectoryURL)
                // Return the persisted URI (bookmark)
                let bookmarkUri = try createBookmarkUriFromUrl(fileURL: newDirectoryURL)
                result(bookmarkUri.absoluteString)
            } else {
                // Return the regular file URI
                result(newDirectoryURL.absoluteString)
            }
            
        } catch {
            result(FlutterError(code: "CREATE_DIRECTORY_FAILED", message: "Failed to create directory: \(error.localizedDescription)", details: nil))
        }
    }
    
    /**
     * Retrieves the file data (bytes) for a given URI string.
     *
     * - Parameter uriString: The URI string representing the file. This can be a regular file:// URI or a urlbookmark:// URI.
     * - Returns: The file data as a FlutterStandardTypedData (wrapping Data) if successful, or a FlutterError if an error occurs.
     */
    private func getFileBytes(uriString: String) -> Any {
        guard let fileUrl = decodePossibleBookmarkUriString(uriString: uriString) else {
            return FlutterError(code: "INVALID_URI", message: "Invalid or unresolvable URI: \(uriString)", details: nil)
        }
        
        // If this is a bookmark URI, we need to start accessing the security-scoped resource.
        if uriString.starts(with: "urlbookmark://") {
            if !fileUrl.startAccessingSecurityScopedResource() {
                return FlutterError(code: "ACCESS_DENIED", message: "Failed to access security-scoped resource: \(fileUrl)", details: nil)
            }
            accessedSecurityScopedUrls.insert(fileUrl)
        }
        
        do {
            let fileData = try Data(contentsOf: fileUrl)
            return FlutterStandardTypedData(bytes: fileData)
        } catch {
            return FlutterError(code: "FILE_READ_ERROR", message: "Failed to read file data: \(error.localizedDescription)", details: nil)
        }
    }
    
    private func deleteFile(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let uriString = call.arguments as? String,
              let fileUrl = URL(string: uriString),
              fileUrl.scheme == "file" else {
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "Invalid or non-file URI provided for deleteFile", details: nil))
            return
        }

        do {
            try FileManager.default.removeItem(at: fileUrl)
            result(true)
        } catch {
            result(FlutterError(code: "DELETE_FILE_FAILED", message: "Failed to delete file: \(error.localizedDescription)", details: nil))
        }
    }

    private func openFile(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [Any],
              let uriString = args[0] as? String,
              let fileUrl = URL(string: uriString) else {
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "Invalid arguments for openFile", details: nil))
            return
        }
        
        // For simplicity, we just open the file with the default application.
        // You might want to use QLPreviewController for a better preview experience.
        DispatchQueue.main.async {
            if UIApplication.shared.canOpenURL(fileUrl) {
                UIApplication.shared.open(fileUrl, options: [:]) { success in
                    if success {
                        result(true)
                    } else {
                        result(FlutterError(code: "OPEN_FILE_FAILED", message: "Failed to open file", details: nil))
                    }
                }
            } else {
                result(FlutterError(code: "OPEN_FILE_FAILED", message: "Could not open file with default application", details: nil))
            }
        }
    }
    
    // MARK: - UIDocumentPickerDelegate
    
    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        
        if multipleAllowed {
            var resultUrls: [String] = []
            
            for url in urls {
                // Start accessing the security-scoped resource.
                if !url.startAccessingSecurityScopedResource() {
                    // Handle access error (e.g., by skipping this URL and logging an error message)
                    os_log("Failed to access security-scoped resource for %@", log: log, type: .info, url.absoluteString)
                    continue
                }
                accessedSecurityScopedUrls.insert(url)
                
                let pickedUrl: URL
                if persistedUriPermission {
                    do {
                        pickedUrl = try createBookmarkUriFromUrl(fileURL: url)
                    } catch {
                        flutterResult?(FlutterError(code: "CREATE_PERSISTED_URI_FAILED", message: "Failed to create persisted URI: \(error.localizedDescription)", details: nil))
                        flutterResult = nil
                        return
                    }
                } else {
                    pickedUrl = url
                }
                
                resultUrls.append(pickedUrl.absoluteString)
            }
            
            flutterResult?(resultUrls)
        } else {
            // Single selection
            guard let url = urls.first else {
                flutterResult?(nil) // User cancelled
                return
            }
            
            // Start accessing the security-scoped resource.
            if !url.startAccessingSecurityScopedResource() {
                flutterResult?(FlutterError(code: "ACCESS_DENIED", message: "Failed to access security-scoped resource: \(url)", details: nil))
                flutterResult = nil
                return
            }
            accessedSecurityScopedUrls.insert(url)
            
            let pickedUrl: URL
            if persistedUriPermission {
                do {
                    pickedUrl = try createBookmarkUriFromUrl(fileURL: url)
                } catch {
                    flutterResult?(FlutterError(code: "CREATE_PERSISTED_URI_FAILED", message: "Failed to create persisted URI: \(error.localizedDescription)", details: nil))
                    flutterResult = nil
                    return
                }
            } else {
                pickedUrl = url
            }
            flutterResult?(pickedUrl.absoluteString)
        }
        flutterResult = nil
    }
    
    
    
    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        flutterResult?(nil)
    }
    
  
    // MARK: PHickerViewControllerelegate
    
        public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true, completion: nil)
            
            var pickedUrls: [String] = []
            
            let dispatchGroup = DispatchGroup()

            for result in results {
                os_log("Result: %@", log: log, type: .error, result.hashValue.description)
                dispatchGroup.enter()
                // Use item provider to load the file URL
                if result.itemProvider.canLoadObject(ofClass: URL.self) {
                    result.itemProvider.loadObject(ofClass: URL.self) { (url, error) in
                        os_log("URL: %@", log: log, type: .error, url?.absoluteString ?? "")
                        if let url = url {
                            
                            let fileUrl: URL
                            if self.persistedUriPermission {
                                do {
                                    fileUrl = try self.createBookmarkUriFromUrl(fileURL: url)
                                } catch {
                                    self.flutterResult?(FlutterError(code: "CREATE_PERSISTED_URI_FAILED", message: "Failed to create persisted URI: \(error.localizedDescription)", details: nil))
                                    self.flutterResult = nil
                                    return
                                }
                            } else {
                                fileUrl = url
                            }
                            
                            pickedUrls.append(fileUrl.absoluteString)
                        } else if let error = error {
                            os_log("Error loading file URL: %@", log: log, type: .error, error.localizedDescription)
                            // You might want to handle errors more gracefully, maybe add a placeholder or skip the item
                        }
                        os_log("About to leave", log: log, type: .error)

                        dispatchGroup.leave()
                    }
                } else {
                    os_log("Cannot load URL - hanging", log: log, type: .error)
                }

            }
            os_log("Waiting at notify", log: log, type: .error)

            dispatchGroup.notify(queue: .main) {
                os_log("In notify", log: log, type: .error)
                self.flutterResult?(pickedUrls)
                self.flutterResult = nil
            }
        }

    
    // MARK: - Helper Functions
    
    private func getInitialDirectoryUrl(location: SharedStorage) -> URL? {
        switch location {
        case SharedStorage.downloads:
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        case SharedStorage.images:
            return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        case SharedStorage.video:
            return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        case SharedStorage.audio:
            return FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
        case SharedStorage.files:
            return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        default:
            return nil
        }
    }
    
    private func createBookmarkUriFromUrl(fileURL: URL) throws -> URL {
        
        let bookmarkData = try fileURL.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        os_log("Raw bookmarkData is %d bytes", log: log, type: .info, bookmarkData.count)
        let bookmarkDataBase64 = bookmarkData.base64EncodedString()
        os_log("base64String: %d characters:%@", log: log, type: .info,bookmarkDataBase64.count, bookmarkDataBase64)
        let bookmarkUriString = "urlbookmark://\(bookmarkDataBase64)"
        
        guard let bookmarkUri = URL(string: bookmarkUriString) else {
            throw NSError(domain: "UriUtilsMethodCallHelper", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to create bookmark URI from '\(bookmarkUriString)'"])
        }
        return bookmarkUri
    }
    

    
    // Stop accessing security-scoped resources when appropriate.
    deinit {
        // Iterate through all stored URLs and stop accessing the security-scoped resources.
        for url in accessedSecurityScopedUrls {
            url.stopAccessingSecurityScopedResource()
        }
    }
}


/// Packs `filename` and `uri` into a single String
///
/// use `unpack` to retrieve the filename and uri from the packed String
func pack(filename: String, uri: URL) -> String {
    return ":::\(filename)::::::\(uri.absoluteString):::"
}

/// Unpacks `packedString` into a (filename, uri) tuple. If this is not a packed
/// string, returns the original `packedString` as (filename, nil) or,
/// if it is a Uri as (nil, the uri)
func unpack(packedString: String) -> (filename: String?, uri: URL?) {
    let regex = try! NSRegularExpression(pattern: ":::([\\s\\S]*?)::::::([\\s\\S]*?):::")
    let range = NSRange(packedString.startIndex..<packedString.endIndex, in: packedString)
    
    if let match = regex.firstMatch(in: packedString, range: range) {
        let filenameRange = match.range(at: 1)
        let uriStringRange = match.range(at: 2)

        if filenameRange.location != NSNotFound && uriStringRange.location != NSNotFound {
          let filename = String(packedString[Range(filenameRange, in: packedString)!])
          let uriString = String(packedString[Range(uriStringRange, in: packedString)!])
          
          if let uri = URL(string: uriString), uri.scheme != nil {
              return (filename: filename, uri: uri)
          } else {
              return (filename: filename, uri: nil)
          }
        }
    } else {
        if let uri = URL(string: packedString), uri.scheme != nil {
            return (filename: nil, uri: uri)
        }
    }
    return (filename: packedString, uri: nil)
}

/// Returns the Uri represented by `maybePacked`, or nil if the String is not a
/// valid Uri or packed Uri string.
///
/// `maybePacked` should be a full Uri string, or a packed String containing
/// a Uri (see `pack`)
func uriFromStringValue(maybePacked: String) -> URL? {
    let unpacked = unpack(packedString: maybePacked)
    return unpacked.uri
}

/// Returns true if `maybePacked` is a valid Uri or packed Uri string.
///
/// `maybePacked` should be a full Uri string, or a packed String containing
/// a Uri (see `pack`)
func containsUri(maybePacked: String) -> Bool {
    return uriFromStringValue(maybePacked: maybePacked) != nil
}

/**
 * Decodes a URI parameter on iOS.
 *
 * If the URI string starts with `urlbookmark://`, it decodes the base64 encoded bookmark data.
 * Otherwise, it returns the original URI as a URL object.
 *
 * - Parameter uriString: The URI string to decode.
 * - Returns: The decoded `URL` or `nil` if the URI string is invalid or the bookmark data cannot be resolved.
 */
func decodePossibleBookmarkUriString(uriString: String) -> URL? {
    if uriString.starts(with: "urlbookmark://") {
        // Decode base64 bookmark data
        os_log("Decoding bookmark data from URI: %@", log: log, type: .info, uriString)
        let base64String = String(uriString.dropFirst("urlbookmark://".count))
        os_log("base64String: %d characters:%@", log: log, type: .info,base64String.count, base64String)
        guard let bookmarkData = Data(base64Encoded: base64String) else {
            return nil
        }
        os_log("Decoded %d bytes", log: log, type: .info, bookmarkData.count)
        
        do {
            var isStale = false
            let resolvedUrl = try URL(resolvingBookmarkData: bookmarkData, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale)
            
            if isStale {
                os_log("Warning: Bookmark data is stale for %@", log: log, type: .info, resolvedUrl.absoluteString)
                return nil
            }
            
            // Access to resolved URLs that are not persisted, is started when they are actually used
            // (i.e. when creating a subdirectory in it, or picking it)
            // And stopped in the deinit
            return resolvedUrl
        } catch {
            os_log("Error resolving bookmark data: %@", log: log, type: .info, error.localizedDescription)
            return nil
        }
    } else {
        // Regular file URL
        return URL(string: uriString)
    }
}

/**
 Returns a URI that may be a bookmarkUri, or nil if not possible
 */
func decodePossibleBookmarkUri(uri: URL) -> URL? {
    if uri.scheme == "urlbookmark" {
        return decodePossibleBookmarkUriString(uriString: uri.absoluteString)
    }
    return uri
}
