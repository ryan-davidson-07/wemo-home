import Foundation
import XCTest
@testable import WemoCore

final class XMLTests: XCTestCase {
    func testGetOnAndOff() throws {
        for (text, expected) in [("0", BinaryState.off), ("1", .on)] {
            XCTAssertEqual(try WemoXML.binaryState(Data(Fixtures.state(text).utf8), action: .getBinaryState), expected)
        }
    }

    func testWhitespaceAndAlternatePrefixes() throws {
        let xml = Fixtures.envelope("<b:GetBinaryStateResponse xmlns:b=\"urn:Belkin:service:basicevent:1\"><b:BinaryState> \n1\t </b:BinaryState></b:GetBinaryStateResponse>", prefix: "soap")
        XCTAssertEqual(try WemoXML.binaryState(Data(xml.utf8), action: .getBinaryState), .on)
    }

    func testSetterEchoAndEmptyAcknowledgment() throws {
        XCTAssertEqual(try WemoXML.binaryState(Data(Fixtures.state("1", action: "SetBinaryState").utf8), action: .setBinaryState), .on)
        XCTAssertNil(try WemoXML.binaryState(Data(Fixtures.emptySet.utf8), action: .setBinaryState))
    }

    func testStructuredFault() throws {
        let fault = try XCTUnwrap(WemoXML.fault(Data(Fixtures.fault.utf8)))
        XCTAssertEqual(fault.code, "s:Client")
        XCTAssertEqual(fault.message, "UPnPError")
        XCTAssertEqual(fault.upnpCode, "501")
        XCTAssertEqual(fault.upnpDescription, "Action Failed")
        XCTAssertThrowsError(try WemoXML.binaryState(Data(Fixtures.fault.utf8), action: .getBinaryState)) {
            XCTAssertEqual($0 as? WemoError, .soapFault(fault))
        }
    }

    func testInvalidAndTruncatedXML() {
        for xml in ["", "not XML", "<s:Envelope", "<root><child></root>"] {
            XCTAssertThrowsError(try WemoXML.binaryState(Data(xml.utf8), action: .getBinaryState)) {
                XCTAssertEqual($0 as? WemoError, .invalidXML)
            }
        }
    }

    func testRejectsInvalidStateEncodings() {
        for value in ["", "2", "-1", "true", "1|0", "01", "+1", "1.0"] {
            XCTAssertThrowsError(try WemoXML.binaryState(Data(Fixtures.state(value).utf8), action: .getBinaryState))
        }
    }

    func testRejectsWrongActionEnvelopeNamespaceAndNestedState() {
        let cases = [
            Fixtures.emptySet,
            Fixtures.state("1").replacingOccurrences(of: "urn:Belkin:service:basicevent:1", with: "urn:other"),
            Fixtures.state("1").replacingOccurrences(of: "http://schemas.xmlsoap.org/soap/envelope/", with: "urn:other"),
            Fixtures.state("1").replacingOccurrences(of: "<BinaryState>1</BinaryState>", with: "<Other><BinaryState>1</BinaryState></Other>"),
            Fixtures.state("1").replacingOccurrences(of: "<BinaryState>1</BinaryState>", with: "<BinaryState>1</BinaryState><BinaryState>0</BinaryState>"),
            Fixtures.state("<Nested>1</Nested>")
        ]
        for xml in cases {
            XCTAssertThrowsError(try WemoXML.binaryState(Data(xml.utf8), action: .getBinaryState))
        }
    }

    func testIdentificationAndEntityDecoding() throws {
        let info = try WemoXML.deviceDescription(Data(Fixtures.description.utf8))
        XCTAssertEqual(info.friendlyName, "Rayns & Home")
        XCTAssertEqual(info.model, "LightSwitch")
        XCTAssertEqual(info.manufacturer, "Belkin International Inc.")
        XCTAssertEqual(info.firmware, "test-firmware")
    }

    func testFirmwareIsOptional() throws {
        let xml = Fixtures.description.replacingOccurrences(of: "<firmwareVersion>test-firmware</firmwareVersion>", with: "")
        XCTAssertNil(try WemoXML.deviceDescription(Data(xml.utf8)).firmware)
    }

    func testRejectsWrongDeviceAndServerSelectedControlURL() {
        for xml in [Fixtures.description.replacingOccurrences(of: "LightSwitch", with: "Socket"),
                    Fixtures.description.replacingOccurrences(of: "/upnp/control/basicevent1", with: "http://example.com/control")] {
            XCTAssertThrowsError(try WemoXML.deviceDescription(Data(xml.utf8)))
        }
    }

    func testRejectsEntitiesDepthAndOversizedDocuments() {
        let entity = "<!DOCTYPE root [<!ENTITY x 'expanded'>]><root>&x;</root>"
        XCTAssertThrowsError(try WemoXML.deviceDescription(Data(entity.utf8))) {
            XCTAssertEqual($0 as? WemoError, .invalidXML)
        }
        let deep = String(repeating: "<a>", count: 40) + String(repeating: "</a>", count: 40)
        XCTAssertThrowsError(try WemoXML.deviceDescription(Data(deep.utf8))) {
            XCTAssertEqual($0 as? WemoError, .invalidXML)
        }
        XCTAssertThrowsError(try WemoXML.deviceDescription(Data(repeating: 65, count: 1_048_577))) {
            XCTAssertEqual($0 as? WemoError, .responseTooLarge)
        }
    }

    func testRejectsUsedAndUnusedInternalDeclarationsInValidDeviceDescription() {
        for declaration in [
            "<!DOCTYPE root [<!ENTITY custom 'Rayns'>]>",
            "<!DOCTYPE root [<!ENTITY a 'Rayns'><!ENTITY custom '&a;&a;'>]>"
        ] {
            for useEntity in [false, true] {
                let xml = withProlog(declaration, body: Fixtures.description.replacingOccurrences(
                    of: "Rayns &amp; Home", with: useEntity ? "&custom;" : "Rayns"))
                assertInvalidDescription(Data(xml.utf8))
            }
        }
    }

    func testRejectsExternalAndParameterEntitiesAndExternalSubsets() {
        // Inert file URLs, never opened: the entire DTD must be rejected before parsing.
        for declaration in [
            "<!DOCTYPE root SYSTEM 'file:///wemo-tests/never-read.dtd'>",
            "<!DOCTYPE root PUBLIC '-//Wemo Tests//DTD Test//EN' 'file:///wemo-tests/never-read.dtd'>",
            "<!DOCTYPE root [<!ENTITY custom SYSTEM 'file:///wemo-tests/never-read.xml'>]>",
            "<!DOCTYPE root [<!ENTITY % custom SYSTEM 'file:///wemo-tests/never-read.dtd'>%custom;]>",
            "<!DOCTYPE root [<!ENTITY % custom \"<!ENTITY other 'value'>\">%custom;]>",
            "<!DOCTYPE root [<!NOTATION n SYSTEM 'inert'><!ENTITY custom SYSTEM 'inert' NDATA n>]>"
        ] {
            assertInvalidDescription(Data(withProlog(declaration).utf8))
        }
    }

    func testRejectsDTDWithoutEntitiesAndMalformedDeclarations() {
        for declaration in ["<!DOCTYPE root>", "<!DOCTYPE root []>", "<!doctype root>",
                            "<!ENTITY custom 'unused'>", "<!DOCTYPE root [", "<!DOCTYPE"] {
            assertInvalidDescription(Data(withProlog(declaration).utf8))
        }
    }

    func testDTDIsRejectedAtEveryPublicParserEntryPoint() {
        let cases: [(String, (Data) throws -> Void)] = [
            (Fixtures.state("1"), { _ = try WemoXML.binaryState($0, action: .getBinaryState) }),
            (Fixtures.emptySet, { _ = try WemoXML.binaryState($0, action: .setBinaryState) }),
            (Fixtures.fault, { _ = try WemoXML.fault($0) })
        ]
        for (body, parse) in cases {
            let xml = "<!DOCTYPE s:Envelope [<!ENTITY unused 'value'>]>" + body
            XCTAssertThrowsError(try parse(Data(xml.utf8))) {
                XCTAssertEqual($0 as? WemoError, .invalidXML)
            }
        }
    }

    func testRejectsDeclarationsAcrossUnicodeEncodings() throws {
        let cases: [(String.Encoding, [UInt8], String)] = [
            (.utf8, [0xEF, 0xBB, 0xBF], "UTF-8"),
            (.utf16LittleEndian, [0xFF, 0xFE], "UTF-16"),
            (.utf16BigEndian, [0xFE, 0xFF], "UTF-16"),
            (.utf32LittleEndian, [0xFF, 0xFE, 0x00, 0x00], "UTF-32"),
            (.utf32BigEndian, [0x00, 0x00, 0xFE, 0xFF], "UTF-32")
        ]
        for (encoding, bom, name) in cases {
            let xml = "<?xml version='1.0' encoding='\(name)'?>" + withProlog("<!DOCTYPE root [<!ENTITY x 'value'>]>")
            var data = Data(bom)
            data.append(try XCTUnwrap(xml.data(using: encoding)))
            assertInvalidDescription(data)
        }
    }

    func testValidUTF8BOMAndUTF16DocumentsStillParse() throws {
        for (encoding, bom, name) in [
            (String.Encoding.utf8, [UInt8(0xEF), 0xBB, 0xBF], "UTF-8"),
            (.utf16LittleEndian, [0xFF, 0xFE], "UTF-16"),
            (.utf16BigEndian, [0xFE, 0xFF], "UTF-16")
        ] {
            let xml = "<?xml version='1.0' encoding='\(name)'?>" + withProlog("")
            var data = Data(bom)
            data.append(try XCTUnwrap(xml.data(using: encoding)))
            XCTAssertEqual(try WemoXML.deviceDescription(data).model, "LightSwitch")
        }
    }

    func testRejectsUnsupportedAndMismatchedDeclaredEncodings() {
        for name in ["UTF-7", "ISO-8859-1", "EBCDIC", "UTF-16", "UTF-32"] {
            let xml = "<?xml version='1.0' encoding='\(name)'?>" + withProlog("")
            assertInvalidDescription(Data(xml.utf8))
        }
        // UTF-7 can encode markup without literal ASCII <, so a raw-byte search alone is insufficient.
        for space in [" ", "\t", "\n", "\r", "\r\n"] {
            let utf7 = "<?xml\(space)version='1.0' encoding='UTF-7'?>+ADw-!DOCTYPE root+AD4-+ADw-root/+AD4-"
            assertInvalidDescription(Data(utf7.utf8))
        }
    }

    func testAllowsLiteralDeclarationTextInCommentsCDATAAndProcessingInstructions() throws {
        let prolog = "<!-- <!DOCTYPE root [<!ENTITY unused 'value'>]> --><?test <!DOCTYPE literal>?>"
        let body = Fixtures.description.replacingOccurrences(of: "Rayns &amp; Home", with: "<![CDATA[Rayns <!ENTITY literal 'text'>]]>")
        let info = try WemoXML.deviceDescription(Data(withProlog(prolog, body: body).utf8))
        XCTAssertEqual(info.friendlyName, "Rayns <!ENTITY literal 'text'>")
    }

    func testPredefinedAndNumericReferencesRemainAllowed() throws {
        let body = Fixtures.description.replacingOccurrences(of: "Rayns &amp; Home", with: "&lt;&gt;&amp;&quot;&apos;&#65;&#x42;")
        XCTAssertEqual(try WemoXML.deviceDescription(Data(body.utf8)).friendlyName, "<>&\"'AB")
        XCTAssertEqual(try WemoXML.binaryState(Data(Fixtures.state("&#49;").utf8), action: .getBinaryState), .on)
    }

    func testRejectsMalformedDocumentsEvenIfFoundationCanRecover() {
        let valid = withProlog("")
        for xml in [
            valid + valid, valid + "trailing text", "<?xml version='1.0'?>",
            valid.replacingOccurrences(of: "<device>", with: "<device x='a' x='b'>"),
            valid.replacingOccurrences(of: "<device>", with: "<device x='raw < value'>"),
            valid.replacingOccurrences(of: "</device>", with: "</wrong>"),
            valid.replacingOccurrences(of: "Rayns &amp; Home", with: "&undeclared;"),
            valid.replacingOccurrences(of: "Rayns &amp; Home", with: "&#0;"),
            valid.replacingOccurrences(of: "Rayns &amp; Home", with: "bare & value"),
            valid.replacingOccurrences(of: "Rayns &amp; Home", with: "\u{0000}"),
            valid.replacingOccurrences(of: "<device>", with: "<unknown:device>"),
            "<!-- unterminated", "<?test unterminated", "<![CDATA[unterminated",
            String(valid.dropLast(3))
        ] {
            assertInvalidDescription(Data(xml.utf8))
        }
        assertInvalidDescription(Data([0x3C, 0xFF, 0x3E]))
        for count in 0..<4 { assertInvalidDescription(Data(repeating: 0x20, count: count)) }
    }

    func testPreservesNodeCountLimit() {
        let xml = withProlog("").replacingOccurrences(of: "<device>", with: "<device>" + String(repeating: "<extra/>", count: 10_000))
        assertInvalidDescription(Data(xml.utf8))
    }

    private func withProlog(_ prolog: String, body: String = Fixtures.description) -> String {
        prolog + body.replacingOccurrences(of: "<?xml version=\"1.0\"?>", with: "")
    }

    private func assertInvalidDescription(_ data: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try WemoXML.deviceDescription(data), file: file, line: line) {
            XCTAssertEqual($0 as? WemoError, .invalidXML, file: file, line: line)
        }
    }

    func testEnvelopeConstructionUsesOnlyBinaryState() throws {
        let data = try SOAPEnvelope.encode(.setBinaryState, state: .off)
        let xml = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(xml.contains("<BinaryState>0</BinaryState>"))
        XCTAssertFalse(xml.contains("Duration"))
        XCTAssertThrowsError(try SOAPEnvelope.encode(.setBinaryState))
    }
}
