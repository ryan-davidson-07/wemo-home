import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum SOAPAction: String, Sendable {
    case getBinaryState = "GetBinaryState"
    case setBinaryState = "SetBinaryState"
}

public enum SOAPEnvelope {
    public static let service = "urn:Belkin:service:basicevent:1"
    static let namespace = "http://schemas.xmlsoap.org/soap/envelope/"

    public static func encode(_ action: SOAPAction, state: BinaryState? = nil) throws -> Data {
        let arguments: String
        switch action {
        case .getBinaryState:
            arguments = ""
        case .setBinaryState:
            guard let state else { throw WemoError.invalidResponse("Missing requested state.") }
            arguments = "<BinaryState>\(state.rawValue)</BinaryState>"
        }
        // Only closed action/state enums enter the envelope; no interpolated user text.
        return Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="\(namespace)" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body><u:\(action.rawValue) xmlns:u="\(service)">\(arguments)</u:\(action.rawValue)></s:Body>
        </s:Envelope>
        """.utf8)
    }
}

public enum WemoXML {
    public static func deviceDescription(_ data: Data) throws -> DeviceDescription {
        let root = try XMLDocument.parse(data)
        guard root.name == "root", root.namespace == "urn:Belkin:device-1-0",
              let device = root.onlyChild("device"),
              let name = device.onlyChild("friendlyName")?.value, !name.isEmpty,
              let manufacturer = device.onlyChild("manufacturer")?.value,
              manufacturer.localizedCaseInsensitiveContains("Belkin"),
              let model = device.onlyChild("modelName")?.value, model == "LightSwitch",
              device.onlyChild("deviceType")?.value == "urn:Belkin:device:lightswitch:1",
              let services = device.onlyChild("serviceList"),
              services.children.contains(where: {
                  $0.name == "service" &&
                  $0.onlyChild("serviceType")?.value == SOAPEnvelope.service &&
                  $0.onlyChild("controlURL")?.value == "/upnp/control/basicevent1"
              }) else {
            throw WemoError.invalidResponse("Expected a Belkin LightSwitch with the basic event service.")
        }
        let firmware = device.onlyChild("firmwareVersion")?.value
        return DeviceDescription(friendlyName: name, manufacturer: manufacturer, model: model,
                                 firmware: firmware?.isEmpty == false ? firmware : nil)
    }

    public static func binaryState(_ data: Data, action: SOAPAction) throws -> BinaryState? {
        let body = try soapBody(data)
        try throwFault(in: body)
        guard body.children.count == 1, let response = body.children.first,
              response.name == action.rawValue + "Response",
              response.namespace == SOAPEnvelope.service else {
            throw WemoError.invalidResponse("Expected \(action.rawValue)Response.")
        }
        let states = response.children.filter { $0.name == "BinaryState" }
        if states.isEmpty && action == .setBinaryState {
            // Some firmware acknowledges a setter without echoing BinaryState.
            // The store always performs a separate GetBinaryState afterward.
            return nil
        }
        guard states.count == 1, let node = states.first, node.children.isEmpty,
              node.namespace.isEmpty || node.namespace == SOAPEnvelope.service,
              let raw = Int(node.value), let state = BinaryState(rawValue: raw),
              node.value == String(raw) else {
            throw WemoError.invalidResponse("Expected one BinaryState value of 0 or 1.")
        }
        return state
    }

    public static func fault(_ data: Data) throws -> SOAPFault? {
        let body = try soapBody(data)
        return try parseFault(in: body)
    }

    private static func soapBody(_ data: Data) throws -> XMLNode {
        let root = try XMLDocument.parse(data)
        guard root.name == "Envelope", root.namespace == SOAPEnvelope.namespace,
              let body = root.onlyChild("Body"), body.namespace == SOAPEnvelope.namespace else {
            throw WemoError.invalidResponse("Expected a SOAP 1.1 envelope and body.")
        }
        return body
    }

    private static func throwFault(in body: XMLNode) throws {
        if let fault = try parseFault(in: body) { throw WemoError.soapFault(fault) }
    }

    private static func parseFault(in body: XMLNode) throws -> SOAPFault? {
        guard let fault = body.children.first(where: { $0.name == "Fault" && $0.namespace == SOAPEnvelope.namespace }) else {
            return nil
        }
        guard body.children.count == 1,
              let code = fault.onlyChild("faultcode")?.value, !code.isEmpty,
              let message = fault.onlyChild("faultstring")?.value, !message.isEmpty else {
            throw WemoError.invalidResponse("Malformed SOAP fault.")
        }
        let upnp = fault.onlyChild("detail")?.onlyChild("UPnPError")
        return SOAPFault(code: code, message: message,
                         upnpCode: upnp?.onlyChild("errorCode")?.value,
                         upnpDescription: upnp?.onlyChild("errorDescription")?.value)
    }
}

private final class XMLNode {
    let name: String
    let namespace: String
    var text = ""
    var children: [XMLNode] = []
    var value: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    init(name: String, namespace: String) {
        self.name = name
        self.namespace = namespace
    }

    func onlyChild(_ name: String) -> XMLNode? {
        let matches = children.filter { $0.name == name }
        return matches.count == 1 ? matches.first : nil
    }
}

private final class XMLDocument: NSObject, XMLParserDelegate {
    private var root: XMLNode?
    private var stack: [XMLNode] = []
    private var nodeCount = 0
    private var rejected = false
    private var endedDocument = false

    static func parse(_ data: Data) throws -> XMLNode {
        guard data.count <= 1_048_576 else { throw WemoError.responseTooLarge }
        try XMLInputSafety.validate(data)
        let document = XMLDocument()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.allowedExternalEntityURLs = []
        parser.delegate = document
        // FoundationXML can recover from some errors and still return true.
        guard parser.parse(), parser.parserError == nil, !document.rejected,
              document.endedDocument, document.stack.isEmpty,
              let root = document.root else { throw WemoError.invalidXML }
        return root
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        nodeCount += 1
        guard stack.count < 32, nodeCount <= 10_000 else { reject(parser); return }
        let node = XMLNode(name: elementName, namespace: namespaceURI ?? "")
        if let parent = stack.last { parent.children.append(node) }
        else if root == nil { root = node }
        else { reject(parser); return }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let text = String(data: CDATABlock, encoding: .utf8) else { reject(parser); return }
        stack.last?.text += text
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        guard let node = stack.last, node.name == elementName,
              node.namespace == (namespaceURI ?? "") else { reject(parser); return }
        stack.removeLast()
    }

    func parserDidEndDocument(_ parser: XMLParser) { endedDocument = true }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { reject(parser) }

    func parser(_ parser: XMLParser, validationErrorOccurred validationError: Error) { reject(parser) }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        reject(parser)
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String,
                publicID: String?, systemID: String?) { reject(parser) }

    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        reject(parser)
        return nil
    }

    private func reject(_ parser: XMLParser) {
        // abortParsing can itself report a delegate error on Apple Foundation.
        guard !rejected else { return }
        rejected = true
        parser.abortParsing()
    }
}
