import Foundation

/// Reject DTDs before XMLParser can expand entities or consult an external subset.
/// Declaration callbacks are not implemented consistently by FoundationXML, and
/// shouldResolveExternalEntities does not disable internal entity substitution.
/// This bounded lexical pass does not replace XMLParser's well-formedness checks.
enum XMLInputSafety {
    static func validate(_ data: Data) throws {
        let bytes = Array(data)
        let encoding: String.Encoding
        let allowedNames: Set<String>
        // Check UTF-32 before UTF-16 because their little-endian BOMs overlap.
        if bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) || bytes.starts(with: [0x00, 0x00, 0x00, 0x3C]) {
            encoding = .utf32BigEndian
            allowedNames = ["utf-32", "utf-32be"]
        } else if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) || bytes.starts(with: [0x3C, 0x00, 0x00, 0x00]) {
            encoding = .utf32LittleEndian
            allowedNames = ["utf-32", "utf-32le"]
        } else if bytes.starts(with: [0xFE, 0xFF]) || bytes.starts(with: [0x00, 0x3C]) {
            encoding = .utf16BigEndian
            allowedNames = ["utf-16", "utf-16be"]
        } else if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0x3C, 0x00]) {
            encoding = .utf16LittleEndian
            allowedNames = ["utf-16", "utf-16le"]
        } else {
            encoding = .utf8
            allowedNames = ["utf-8", "us-ascii"]
        }
        guard var text = String(data: data, encoding: encoding),
              !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw WemoError.invalidXML
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }

        // Do not let XMLParser reinterpret bytes in an encoding different from
        // this preflight (for example UTF-7 or EBCDIC). Wemo uses UTF-8; standard
        // UTF-16/32 signatures are supported too. Other encodings fail closed.
        if text.hasPrefix("<?xml"), text.dropFirst(5).unicodeScalars.first.map(isXMLSpace) == true {
            guard let end = text.range(of: "?>") else { throw WemoError.invalidXML }
            let declaration = String(text[..<end.upperBound])
            let pattern = #"\bencoding\s*=\s*(["'])([^"']*)\1"#
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(declaration.startIndex..., in: declaration)
            for match in regex.matches(in: declaration, range: range) {
                guard let nameRange = Range(match.range(at: 2), in: declaration),
                      allowedNames.contains(declaration[nameRange].lowercased()) else {
                    throw WemoError.invalidXML
                }
            }
        }

        var scanner = MarkupScanner(bytes: Array(text.utf8))
        try scanner.validate()
    }

    private static func isXMLSpace(_ scalar: Unicode.Scalar) -> Bool {
        // CRLF is one Swift Character but two XML whitespace scalars.
        [0x20, 0x09, 0x0D, 0x0A].contains(scalar.value)
    }

    private struct MarkupScanner {
        let bytes: [UInt8]
        var index = 0

        mutating func validate() throws {
            while index < bytes.count {
                guard bytes[index] == 0x3C else { index += 1; continue } // <
                if starts("<!--") {
                    try skip("-->", openingLength: 4)
                } else if starts("<![CDATA[") {
                    try skip("]]>", openingLength: 9)
                } else if starts("<?") {
                    try skip("?>", openingLength: 2)
                } else if starts("<!") {
                    // DTDs, entity declarations and all other declaration markup
                    // are unnecessary for setup/SOAP, whether used or unused.
                    throw WemoError.invalidXML
                } else {
                    try skipTag()
                }
            }
        }

        private func starts(_ token: String) -> Bool {
            bytes[index...].starts(with: token.utf8)
        }

        private mutating func skip(_ closing: String, openingLength: Int) throws {
            index += openingLength
            while index < bytes.count {
                if starts(closing) { index += closing.utf8.count; return }
                index += 1
            }
            throw WemoError.invalidXML
        }

        private mutating func skipTag() throws {
            index += 1
            var quote: UInt8?
            while index < bytes.count {
                let byte = bytes[index]
                // Raw < is illegal inside tags, including quoted attributes.
                // Reject it rather than allowing it to hide declaration markup.
                if byte == 0x3C { throw WemoError.invalidXML }
                if let current = quote {
                    if byte == current { quote = nil }
                } else if byte == 0x22 || byte == 0x27 {
                    quote = byte
                } else if byte == 0x3E {
                    index += 1
                    return
                }
                index += 1
            }
            throw WemoError.invalidXML
        }
    }
}
