//
//  UriUtilsTest.swift
//  background_downloader
//
//  Created by Bram on 1/24/25.
//

import XCTest
@testable import background_downloader // Assuming your package is named 'background_downloader'

class UriUtilsTests: XCTestCase {

    func testPackShouldPackFilenameAndUriIntoASingleString() {
        let filename = "myFile.txt"
        let uri = URL(string: "content://com.example.app/document/123")!

        let packedString = pack(filename: filename, uri: uri)

        XCTAssertEqual(packedString, ":::\(filename)::::::\(uri.absoluteString):::")
    }

    func testUnpackShouldUnpackAValidPackedStringIntoFilenameAndUri() {
        let filename = "myFile.txt"
        let uri = URL(string: "content://com.example.app/document/123")!
        let packedString = ":::\(filename)::::::\(uri.absoluteString):::"

        let unpacked = unpack(packedString: packedString)

        XCTAssertEqual(unpacked.filename, filename)
        XCTAssertEqual(unpacked.uri, uri)
    }

    func testUnpackShouldReturnOriginalStringAndNilUriForSimpleFilenameString() {
        let invalidPackedString = "This is not a packed string"

        let unpacked = unpack(packedString: invalidPackedString)

        XCTAssertEqual(unpacked.filename, invalidPackedString)
        XCTAssertNil(unpacked.uri)
    }

    func testUnpackShouldReturnNilAndAUriForSimpleUriString() {
        let uriString = "https://www.example.com/path/to/resource"

        let unpacked = unpack(packedString: uriString)

        XCTAssertNil(unpacked.filename)
        XCTAssertEqual(unpacked.uri?.absoluteString, uriString)
    }

    func testUriFromStringValueShouldReturnUriForAValidUriString() {
        let uriString = "https://www.example.com/path/to/resource"
        let expectedUri = URL(string: uriString)!

        let resultUri = uriFromStringValue(maybePacked: uriString)

        XCTAssertEqual(resultUri, expectedUri)
    }

    func testUriFromStringValueShouldReturnUriFromAValidPackedString() {
        let filename = "myFile.txt"
        let uri = URL(string: "content://com.example.app/document/123")!
        let packedString = pack(filename: filename, uri: uri)

        let resultUri = uriFromStringValue(maybePacked: packedString)

        XCTAssertEqual(resultUri, uri)
    }

    func testUriFromStringValueShouldReturnNilForAnInvalidString() {
        let invalidString = "This is not a Uri or packed string"

        let resultUri = uriFromStringValue(maybePacked: invalidString)

        XCTAssertNil(resultUri)
    }

    func testUriFromStringValueShouldReturnNilForAPackedStringWithInvalidUri() {
        let filename = "myFile.txt"
        let invalidUri = "invalid"
        let packedString = ":::\(filename)::::::\(invalidUri):::"

        let resultUri = uriFromStringValue(maybePacked: packedString)

        XCTAssertNil(resultUri)
    }
    
    func testContainsUriReturnsTrueForValidUriString() {
        let uriString = "https://www.example.com"
        XCTAssertTrue(containsUri(maybePacked: uriString))
    }

    func testContainsUriReturnsTrueForValidPackedString() {
        let packedString = pack(filename: "file.txt", uri: URL(string: "https://www.example.com")!)
        XCTAssertTrue(containsUri(maybePacked: packedString))
    }

    func testContainsUriReturnsFalseForInvalidString() {
        let invalidString = "This is not a URI"
        XCTAssertFalse(containsUri(maybePacked: invalidString))
    }
}
