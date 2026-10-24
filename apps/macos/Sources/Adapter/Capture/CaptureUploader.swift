import AppKit
import Security

/// Uploading a capture to a bucket the person owns (Amazon S3, Cloudflare R2, Backblaze B2, MinIO). Off until it is set up; the
/// secret key lives in the Keychain, never in preferences; nothing goes anywhere else, and Kriya runs no server of its own.
enum CaptureUploadKeychain {
    private static let service = "app.kriya.capture.upload"

    static func secret(for accessKey: String, service override: String? = nil) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: override ?? service,
                                    kSecAttrAccount as String: accessKey, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func setSecret(_ secret: String, for accessKey: String, service override: String? = nil) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: override ?? service, kSecAttrAccount as String: accessKey]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(secret.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func deleteSecret(for accessKey: String, service override: String? = nil) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: override ?? service, kSecAttrAccount as String: accessKey] as CFDictionary)
    }
}

final class CaptureUploadStore: ObservableObject {
    static let shared = CaptureUploadStore()
    private let key = "capture.upload.v1"
    @Published var config: CaptureUploadConfig { didSet { if let data = try? JSONEncoder().encode(config) { UserDefaults.standard.set(data, forKey: key) } } }

    private init() { config = UserDefaults.standard.data(forKey: "capture.upload.v1").flatMap { try? JSONDecoder().decode(CaptureUploadConfig.self, from: $0) } ?? CaptureUploadConfig() }

    var ready: Bool { config.enabled && config.isComplete && CaptureUploadKeychain.secret(for: config.accessKey) != nil }
}

enum CaptureUploader {
    struct Uploaded { let objectKey: String; let link: String }

    enum UploadError: LocalizedError {
        case notSetUp, localOnly, noSecret, failed(Int, String), badURL
        var errorDescription: String? {
            switch self {
            case .notSetUp: return "Uploads are not set up. Add a bucket in Settings › Capture."
            case .localOnly: return "Local-only mode is on, so nothing is uploaded."
            case .noSecret: return "The secret key for this bucket is not in the Keychain."
            case .failed(let code, let note): return "The bucket answered \(code)\(note.isEmpty ? "" : ": " + note)."
            case .badURL: return "The bucket address is not valid."
            }
        }
    }

    /// Sends `data` and calls back with the link. The request is signed here and sent straight to the bucket's address.
    static func upload(_ data: Data, fileName: String, contentType: String, config: CaptureUploadConfig = CaptureUploadStore.shared.config, session: URLSession = .shared,
                       completion: @escaping (Result<Uploaded, Error>) -> Void) {
        guard config.enabled, config.isComplete else { return completion(.failure(UploadError.notSetUp)) }
        guard !LocalOnly.isOn else { return completion(.failure(UploadError.localOnly)) }
        guard let secret = CaptureUploadKeychain.secret(for: config.accessKey) else { return completion(.failure(UploadError.noSecret)) }
        let key = config.objectKey(fileName: fileName)
        let target = config.target(objectKey: key)
        let signer = S3Signer(accessKey: config.accessKey, secretKey: secret, region: config.region)
        guard let url = URL(string: "https://\(target.host)\(target.path)") else { return completion(.failure(UploadError.badURL)) }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "PUT"
        for (name, value) in signer.putHeaders(host: target.host, path: target.path, body: data, contentType: contentType) { request.setValue(value, forHTTPHeaderField: name) }
        AuditLog.shared.record(.network, "Uploading a capture to \(target.host)")
        session.uploadTask(with: request, from: data) { body, response, error in
            if let error { return completion(.failure(error)) }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                let note = body.flatMap { String(data: $0.prefix(200), encoding: .utf8) }?.replacingOccurrences(of: "\n", with: " ") ?? ""
                return completion(.failure(UploadError.failed(code, note)))
            }
            let link = config.publicURL(objectKey: key) ?? signer.presignedGetURL(host: target.host, path: target.path, expires: config.linkMinutes * 60)?.absoluteString
            guard let link else { return completion(.failure(UploadError.badURL)) }
            completion(.success(Uploaded(objectKey: key, link: link)))
        }.resume()
    }
}
