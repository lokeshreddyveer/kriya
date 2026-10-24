import CryptoKit
import Foundation

/// Signing requests for S3-compatible storage (Amazon S3, Cloudflare R2, Backblaze B2, MinIO) with AWS Signature Version 4, so a
/// capture can be uploaded to a bucket the person owns without any outside software. Nothing here touches the network.
struct S3Signer {
    var accessKey: String
    var secretKey: String
    var region: String
    var service = "s3"

    // MARK: Pieces

    static func hex(_ data: some Sequence<UInt8>) -> String { data.map { String(format: "%02x", $0) }.joined() }
    static func sha256Hex(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

    static func hmac(_ key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    static func amzDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }

    /// Percent-encoding the way AWS wants it: everything but letters, digits and `-._~` is encoded; a slash stays in a path.
    static func encode(_ text: String, keepSlash: Bool = false) -> String {
        var out = ""
        for b in text.utf8 {
            switch b {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
                out.append(Character(UnicodeScalar(b)))
            case UInt8(ascii: "/") where keepSlash: out.append("/")
            default: out += String(format: "%%%02X", b)
            }
        }
        return out
    }

    /// The key the signature is made with, derived from the secret, the day, the region and the service.
    func signingKey(day: String) -> Data {
        let k1 = Self.hmac(Data(("AWS4" + secretKey).utf8), day)
        let k2 = Self.hmac(k1, region)
        let k3 = Self.hmac(k2, service)
        return Self.hmac(k3, "aws4_request")
    }

    func scope(day: String) -> String { "\(day)/\(region)/\(service)/aws4_request" }

    struct Request {
        var method: String
        /// The path, already as it will be sent (encoded, starting with a slash).
        var path: String
        var query: [(String, String)] = []
        var host: String
        var headers: [(String, String)] = []
        var payloadHash: String
    }

    /// The canonical request text and the header names that were signed.
    func canonical(_ r: Request) -> (text: String, signedHeaders: String) {
        var headers: [(String, String)] = [("host", r.host)]
        for (name, value) in r.headers { headers.append((name.lowercased(), value.trimmingCharacters(in: .whitespaces))) }
        headers.sort { $0.0 < $1.0 }
        let names: String = headers.map { $0.0 }.joined(separator: ";")
        var pairs: [(String, String)] = []
        for (name, value) in r.query { pairs.append((Self.encode(name), Self.encode(value))) }
        pairs.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        let query: String = pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        let headerText: String = headers.map { "\($0.0):\($0.1)\n" }.joined()
        let parts: [String] = [r.method, r.path, query, headerText, names, r.payloadHash]
        return (parts.joined(separator: "\n"), names)
    }

    func signature(canonicalRequest: String, date: Date) -> String {
        let stamp = Self.amzDate(date), day = String(stamp.prefix(8))
        let toSign = ["AWS4-HMAC-SHA256", stamp, scope(day: day), Self.sha256Hex(Data(canonicalRequest.utf8))].joined(separator: "\n")
        return Self.hex(Self.hmac(signingKey(day: day), toSign))
    }

    // MARK: Uploading and sharing

    /// The headers for a PUT of `body` to `key` in `bucket`: the date, the content hash, and the signed Authorization.
    func putHeaders(host: String, path: String, body: Data, contentType: String, date: Date = Date()) -> [String: String] {
        let stamp = Self.amzDate(date), day = String(stamp.prefix(8)), hash = Self.sha256Hex(body)
        let extra = [("content-type", contentType), ("x-amz-content-sha256", hash), ("x-amz-date", stamp)]
        let (text, names) = canonical(Request(method: "PUT", path: path, host: host, headers: extra, payloadHash: hash))
        let sig = signature(canonicalRequest: text, date: date)
        return [
            "Content-Type": contentType, "x-amz-content-sha256": hash, "x-amz-date": stamp,
            "Authorization": "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope(day: day)), SignedHeaders=\(names), Signature=\(sig)",
        ]
    }

    /// A link that lets anyone who has it read one object until it expires (at most 7 days, the limit AWS sets).
    func presignedGetURL(scheme: String = "https", host: String, path: String, expires: Int, date: Date = Date()) -> URL? {
        let stamp = Self.amzDate(date), day = String(stamp.prefix(8))
        let seconds = min(max(expires, 1), 604_800)
        let query: [(String, String)] = [
            ("X-Amz-Algorithm", "AWS4-HMAC-SHA256"), ("X-Amz-Credential", "\(accessKey)/\(scope(day: day))"), ("X-Amz-Date", stamp),
            ("X-Amz-Expires", String(seconds)), ("X-Amz-SignedHeaders", "host"),
        ]
        let (text, _) = canonical(Request(method: "GET", path: path, query: query, host: host, payloadHash: "UNSIGNED-PAYLOAD"))
        let sig = signature(canonicalRequest: text, date: date)
        let q = (query + [("X-Amz-Signature", sig)]).map { "\(Self.encode($0.0))=\(Self.encode($0.1))" }.joined(separator: "&")
        return URL(string: "\(scheme)://\(host)\(path)?\(q)")
    }
}

/// Where a capture goes and how the link is made, kept apart from the secret key (which lives in the Keychain).
struct CaptureUploadConfig: Codable, Equatable {
    var enabled = false
    /// `s3.amazonaws.com`, `ACCOUNT.r2.cloudflarestorage.com`, `s3.us-west-004.backblazeb2.com`, a MinIO host…
    var endpoint = ""
    var region = "auto"
    var bucket = ""
    var accessKey = ""
    /// A folder-like prefix for the uploaded files, such as `captures/`.
    var prefix = "captures/"
    /// Where files can be read from if the bucket is public (a custom domain or r2.dev address). Empty makes an expiring link instead.
    var publicBase = ""
    var linkMinutes = 60
    var deleteLocalAfterUpload = false
    var usePathStyle = true

    var isComplete: Bool { !endpoint.isEmpty && !bucket.isEmpty && !accessKey.isEmpty }

    /// The host to talk to and the path of the object, in the style the provider uses.
    func target(objectKey: String) -> (host: String, path: String) {
        let cleanHost = endpoint.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encodedKey = S3Signer.encode(objectKey, keepSlash: true)
        return usePathStyle ? (cleanHost, "/\(S3Signer.encode(bucket))/\(encodedKey)") : ("\(bucket).\(cleanHost)", "/\(encodedKey)")
    }

    /// `captures/2026/10/Capture 14.05.png`, never starting with a slash or holding `..`.
    func objectKey(fileName: String, date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy/MM"
        let folder = prefix.split(separator: "/").map(String.init).filter { $0 != ".." && $0 != "." && !$0.isEmpty }.joined(separator: "/")
        let name = fileName.replacingOccurrences(of: "/", with: "-")
        return (folder.isEmpty ? "" : folder + "/") + f.string(from: date) + "/" + name
    }

    /// The link to hand out for an uploaded object: the public address when there is one, otherwise nil (an expiring link is made).
    func publicURL(objectKey: String) -> String? {
        let base = publicBase.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return nil }
        return base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + S3Signer.encode(objectKey, keepSlash: true)
    }
}
