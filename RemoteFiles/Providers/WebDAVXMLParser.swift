import Foundation

struct WebDAVEntry: Sendable {
    var path = "/"
    var displayName: String?
    var isCollection = false
    var size: Int64?
    var modifiedAt: Date?
    var createdAt: Date?
    var eTag: String?
    var contentType: String?
}

final class WebDAVXMLParser: NSObject, XMLParserDelegate {
    private var entries: [WebDAVEntry] = []
    private var current: WebDAVEntry?
    private var buffer = ""

    func parse(_ data: Data) throws -> [WebDAVEntry] {
        entries = []
        current = nil
        buffer = ""
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = self
        guard parser.parse() else {
            throw parser.parserError ?? RemoteProviderError.invalidResponse("Unable to parse WebDAV XML.")
        }
        return entries
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        buffer = ""
        switch elementName.lowercased() {
        case "response": current = WebDAVEntry()
        case "collection": current?.isCollection = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased()
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "href": current?.path = value
        case "displayname": current?.displayName = value
        case "getcontentlength": current?.size = Int64(value)
        case "getlastmodified": current?.modifiedAt = Self.httpDate.date(from: value)
        case "creationdate": current?.createdAt = ISO8601DateFormatter().date(from: value)
        case "getetag": current?.eTag = value
        case "getcontenttype": current?.contentType = value
        case "response":
            if let current { entries.append(current) }
            current = nil
        default: break
        }
        buffer = ""
    }

    private static let httpDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter
    }()
}

