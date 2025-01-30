//
//  OpenFile.swift
//  background_downloader
//
//  Created on 4/27/23.
//

import Foundation
import MobileCoreServices
import UIKit

///
func doOpenFile(filePath: String, mimeType: String?) -> Bool {
    let fileUrl = URL(string: "file:///\(filePath)")!
    let documentInteractionController = UIDocumentInteractionController(url: fileUrl)
    let delegate = DocumentInteractionControllerDelegate()
    documentInteractionController.delegate = delegate
    if (mimeType != nil) {
        if let uti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassMIMEType, mimeType! as NSString, nil)?.takeRetainedValue()
        {
            documentInteractionController.uti = uti as String
        }
    }
    guard let view = UIApplication.shared.delegate?.window??.rootViewController?.view
    else {
        return false
    }
    if !documentInteractionController.presentPreview(animated: true) {
        documentInteractionController.presentOpenInMenu(from: view.bounds, in: view, animated: true)
        return true
    }
    return true
}

class DocumentInteractionControllerDelegate: NSObject, UIDocumentInteractionControllerDelegate {
    
    func documentInteractionControllerViewControllerForPreview(_ controller: UIDocumentInteractionController) -> UIViewController {
        return (UIApplication.shared.delegate?.window??.rootViewController)!
    }
}
