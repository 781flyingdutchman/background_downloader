//
//  OpenFile.swift
//  background_downloader
//
//  Created on 4/27/23.
//

import Foundation

///
func doOpenFile(filePath: String) -> Bool {
    let fileUrl = NSURL(fileURLWithPath: filePath)
    let documentInteractionController = UIDocumentInteractionController(url: fileUrl as URL)
    let delegate = DocumentInteractionControllerDelegate()
    documentInteractionController.delegate = delegate
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
