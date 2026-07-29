import Foundation

/// The multipart body of a submission, assembled by hand.
///
/// Swift has no `FormData`, and the details here are not cosmetic — they are
/// transcribed from a submission the portal answered 201 to:
///
/// - The `obj` part carries **no `Content-Type` header** and its value is raw
///   UTF-8. Lisbon addresses are full of diacritics, so the encoding matters.
/// - Photos go in parts all named `files` — plural, repeated, not `files[]`.
/// - `POST /ficheiro-temp` is **skipped entirely**. The portal calls it to
///   drive its own preview thumbnail, but the id it returns is never referenced
///   and the bytes are re-sent here anyway.
public struct MultipartBody: Sendable {
    public let boundary: String
    public private(set) var data = Data()

    public init(boundary: String = "----ReparaFormBoundary\(UUID().uuidString)") {
        self.boundary = boundary
    }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    /// A field with no `Content-Type`, exactly as the browser sends `obj`.
    public mutating func append(name: String, value: Data) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(Self.escape(name))\"\r\n")
        append("\r\n")
        data.append(value)
        append("\r\n")
    }

    public mutating func append(name: String, value: String) {
        append(name: name, value: Data(value.utf8))
    }

    public mutating func append(
        name: String, filename: String, contentType: String, bytes: Data
    ) {
        append("--\(boundary)\r\n")
        append(
            "Content-Disposition: form-data; name=\"\(Self.escape(name))\"; "
                + "filename=\"\(Self.escape(filename))\"\r\n")
        append("Content-Type: \(contentType)\r\n")
        append("\r\n")
        data.append(bytes)
        append("\r\n")
    }

    public mutating func finish() {
        append("--\(boundary)--\r\n")
    }

    private mutating func append(_ string: String) {
        data.append(Data(string.utf8))
    }

    /// Per the multipart spec as browsers implement it: only quotes and line
    /// breaks are escaped, and the rest of the filename passes through as UTF-8.
    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "%0D%0A")
            .replacingOccurrences(of: "\n", with: "%0A")
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\"", with: "%22")
    }
}
