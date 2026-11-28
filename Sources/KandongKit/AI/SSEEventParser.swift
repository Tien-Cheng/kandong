import Foundation

/// Frames Server-Sent Events across arbitrary byte fragments, including CRLF and multi-line `data:` fields.
struct SSEEventParser {
    struct Event {
        let type: String?
        let data: String
    }

    private let providerName: String
    private var line = Data()
    private var data: [String] = []
    private var type: String?
    private var eventSize = 0

    init(providerName: String) {
        self.providerName = providerName
    }

    mutating func append(_ byte: UInt8) throws -> Event? {
        guard byte == 10 else {
            line.append(byte)
            guard line.count + eventSize <= 1_048_576 else {
                throw BackendError.badResponse("\(providerName) sent an oversized stream event.")
            }
            return nil
        }
        if line.last == 13 { line.removeLast() }
        let value = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)
        if value.isEmpty {
            defer { data.removeAll(keepingCapacity: true); type = nil; eventSize = 0 }
            return data.isEmpty ? nil : Event(type: type, data: data.joined(separator: "\n"))
        }
        guard !value.hasPrefix(":"), let colon = value.firstIndex(of: ":") else { return nil }
        let field = value[..<colon]
        var text = String(value[value.index(after: colon)...])
        if text.hasPrefix(" ") { text.removeFirst() }
        if field == "data" { data.append(text); eventSize += text.utf8.count }
        else if field == "event" { type = text }
        return nil
    }
}
