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

public class UriUtilsMethodCallHelper: NSObject, FlutterPlugin, UIDocumentPickerDelegate {
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
           let startLocationUri = decodeUriParameter(uriString: startLocationUriString) {
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
        
        // This code assumes the current view controller is accessible through the key window's root view controller.
        // Adjust this as needed based on your app's view hierarchy.
        if let rootViewController = UIApplication.shared.keyWindow?.rootViewController {
            rootViewController.present(documentPicker, animated: true, completion: nil)
        } else {
            result(FlutterError(code: "NO_ROOT_VIEW_CONTROLLER", message: "Could not find root view controller", details: nil))
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
           let startLocationUri = decodeUriParameter(uriString: startLocationUriString) {
            startLocation = startLocationUri
        } else if let startLocationOrdinal = args[0] as? Int,
                  let sharedStorage = SharedStorage(rawValue: startLocationOrdinal) {
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
        if #available(iOS 14.0, *), let startLocation = startLocation {
            documentPicker.directoryURL = startLocation
        }
        
        // Present the document picker
        // Similar to `pickDirectory`, this code assumes access to the current view controller through the key window's root view controller.
        if let rootViewController = UIApplication.shared.keyWindow?.rootViewController {
            rootViewController.present(documentPicker, animated: true, completion: nil)
        } else {
            result(FlutterError(code: "NO_ROOT_VIEW_CONTROLLER", message: "Could not find root view controller", details: nil))
        }
    }
    
    
    private func createDirectory(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [Any],
              let parentDirectoryUriString = args[0] as? String,
              let newDirectoryName = args[1] as? String,
              let persistedUriPermission = args[2] as? Bool,
              let parentDirectoryUri = decodeUriParameter(uriString: parentDirectoryUriString)
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
    
    // MARK: - UIDocumentPickerDelegate
    
    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        
        if multipleAllowed {
            var resultUrls: [String] = []
            
            for url in urls {
                // Start accessing the security-scoped resource.
                if !url.startAccessingSecurityScopedResource() {
                    // Handle access error (e.g., by skipping this URL and logging an error message)
                    print("Failed to access security-scoped resource: \(url)")
                    continue
                }
                accessedSecurityScopedUrls.insert(url)
                
                let pickedUrl: URL
                if persistedUriPermission {
                    do {
                        pickedUrl = try createBookmarkUriFromUrl(fileURL: url)
                    } catch {
                        flutterResult?(FlutterError(code: "CREATE_PERSISTED_URI_FAILED", message: "Failed to create persisted URI: \(error.localizedDescription)", details: nil))
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
                return
            }
            accessedSecurityScopedUrls.insert(url)
            
            let pickedUrl: URL
            if persistedUriPermission {
                do {
                    pickedUrl = try createBookmarkUriFromUrl(fileURL: url)
                } catch {
                    flutterResult?(FlutterError(code: "CREATE_PERSISTED_URI_FAILED", message: "Failed to create persisted URI: \(error.localizedDescription)", details: nil))
                    return
                }
            } else {
                pickedUrl = url
            }
            flutterResult?(pickedUrl.absoluteString)
        }
    }
    
    
    
    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        flutterResult?(nil)
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
    
    /**
     * Creates a bookmark URI from a file URL on iOS.
     *
     * - Parameter fileURL: The file URL to create a bookmark from.
     * - Returns: A URI with the `urlbookmark` scheme containing the bookmark data.
     */
    private func createBookmarkUriFromUrl(fileURL: URL) throws -> URL {
        let bookmarkData = try fileURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let bookmarkDataBase64 = bookmarkData.base64EncodedString()
        let bookmarkUriString = "urlbookmark://\(bookmarkDataBase64)"
        
        guard let bookmarkUri = URL(string: bookmarkUriString) else {
            throw NSError(domain: "UriUtilsMethodCallHelper", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to create bookmark URI from '\(bookmarkUriString)'"])
        }
        return bookmarkUri
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
    private func decodeUriParameter(uriString: String) -> URL? {
        if uriString.starts(with: "urlbookmark://") {
            // Decode base64 bookmark data
            let base64String = String(uriString.dropFirst("urlbookmark://".count))
            guard let bookmarkData = Data(base64Encoded: base64String) else {
                return nil
            }
            
            do {
                var isStale = false
                let resolvedUrl = try URL(resolvingBookmarkData: bookmarkData, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
                
                if isStale {
                    // Handle stale bookmark data appropriately.
                    print("Warning: Bookmark data is stale for \(resolvedUrl)")
                    return nil
                }
                
                // Access to resolved URLs that are not persisted, is started when they are actually used
                // (i.e. when creating a subdirectory in it, or picking it to download a file into)
                // And stopped in the deinit
                return resolvedUrl
            } catch {
                print("Error resolving bookmark data: \(error)")
                return nil
            }
        } else {
            // Regular file URL
            return URL(string: uriString)
        }
    }
    
    // Stop accessing security-scoped resources when appropriate.
    deinit {
        // Iterate through all stored URLs and stop accessing the security-scoped resources.
        for url in accessedSecurityScopedUrls {
            url.stopAccessingSecurityScopedResource()
        }
    }
}
