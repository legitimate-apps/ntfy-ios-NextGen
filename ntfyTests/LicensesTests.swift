import XCTest
@testable import ntfy

/// The shipped binary must carry the notices its licenses require (MIT, Apache-2.0 §4, zlib §3).
/// These fail if a component, its copyright line or its license text goes missing.
final class LicensesTests: XCTestCase {
    private let required: [(name: String, license: String, copyright: String, licenseMarker: String)] = [
        ("ntfy for iOS", "MIT License", "Copyright (c) 2022 Copephobia", "Permission is hereby granted"),
        ("Firebase", "Apache License 2.0", "Copyright 2017-2021 Google LLC", "Version 2.0, January 2004"),
        ("GoogleUtilities", "Apache License 2.0", "Google LLC", "Version 2.0, January 2004"),
        ("GoogleUtilities: isAppEncrypted", "MIT License", "Copyright (c) 2017 Landon J. Fuller",
         "Permission is hereby granted"),
        ("GoogleDataTransport", "Apache License 2.0", "Google LLC", "Version 2.0, January 2004"),
        ("Promises", "Apache License 2.0", "Google Inc.", "Version 2.0, January 2004"),
        ("nanopb", "zlib License", "Copyright (c) 2011 Petteri Aimonen",
         "This notice may not be removed or altered from any source"),
    ]

    func testEveryRequiredComponentCarriesItsCopyrightAndLicenseText() {
        let byName = Dictionary(uniqueKeysWithValues: OpenSourceLicenses.components.map { ($0.name, $0) })
        XCTAssertEqual(byName.count, OpenSourceLicenses.components.count, "component names must be unique")
        for entry in required {
            guard let component = byName[entry.name] else {
                XCTFail("missing license entry for \(entry.name)")
                continue
            }
            XCTAssertEqual(component.licenseName, entry.license, entry.name)
            XCTAssertTrue(component.fullText.contains(entry.copyright), "\(entry.name): copyright line missing")
            XCTAssertTrue(component.fullText.contains(entry.licenseMarker), "\(entry.name): license text missing")
        }
    }

    func testAppEntryCarriesTheFullMITNotice() {
        let app = OpenSourceLicenses.components.first { $0.name == "ntfy for iOS" }
        XCTAssertTrue(app?.fullText.contains("Copephobia") ?? false)
        XCTAssertTrue(app?.fullText.contains("Permission is hereby granted") ?? false)
        XCTAssertTrue(app?.fullText.contains("shall be included in all\ncopies or substantial portions") ?? false)
    }

    func testApacheTextIsCompleteAndSharedByEveryApacheComponent() {
        let apache = OpenSourceLicenses.apache2Text
        XCTAssertTrue(apache.contains("TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION"))
        XCTAssertTrue(apache.contains("4. Redistribution."))
        XCTAssertTrue(apache.contains("END OF TERMS AND CONDITIONS"))
        for component in OpenSourceLicenses.components where component.licenseName == "Apache License 2.0" {
            XCTAssertEqual(component.licenseText, apache, component.name)
        }
    }

    func testReflowKeepsEveryWordAndParagraph() {
        for component in OpenSourceLicenses.components {
            let original = component.fullText.split(whereSeparator: \.isWhitespace)
            let shown = OpenSourceLicenses.reflowed(component.fullText).split(whereSeparator: \.isWhitespace)
            XCTAssertEqual(original, shown, component.name)
        }
        XCTAssertEqual(OpenSourceLicenses.reflowed("a\n  b\n\n\nc\nd"), "a b\n\nc d")
    }
}
