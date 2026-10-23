import Foundation

/// Sends a request and returns the answer. The real one uses URLSession; tests use a stand-in.
protocol HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// The lines of a streamed answer. A failing status ends the stream with an error that carries the start of the body.
    func lines(_ request: URLRequest) -> AsyncThrowingStream<String, Error>
}

struct HTTPFailure: Error { let status: Int; let body: Data }

/// URLSession with nothing kept: no cookies, no cache, no stored credentials, and no following of redirects, so a key sent in a
/// header can never be passed on to another address.
final class URLSessionTransport: NSObject, HTTPTransport, URLSessionTaskDelegate {
    static let shared = URLSessionTransport()
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIError.badResponse }
        return (data, http)
    }

    func lines(_ request: URLRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw AIError.badResponse }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = Data()
                        for try await byte in bytes { body.append(byte); if body.count >= 4000 { break } }
                        throw HTTPFailure(status: http.statusCode, body: body)
                    }
                    for try await line in bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

enum AIErrorMapper {
    /// A transport or HTTP failure, in Kriya's own terms. Provider messages are cleaned of anything that looks like a secret.
    static func map(_ error: Error) -> AIError {
        if let error = error as? AIError { return error }
        if error is CancellationError { return .cancelled }
        if let failure = error as? HTTPFailure { return fromStatus(failure.status, failure.body) }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed: return .offline
            case .timedOut: return .timeout
            case .cancelled: return .cancelled
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
                return .provider("The secure connection could not be verified.")
            default: return .offline
            }
        }
        return .provider(clean(error.localizedDescription))
    }

    static func fromStatus(_ status: Int, _ body: Data) -> AIError {
        switch status {
        case 401, 403: return .unauthorized
        case 429: return .rateLimited
        default:
            let message = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]).flatMap { AIWireSupport.errorMessage($0) }
            return .provider(clean(message ?? "HTTP \(status)"))
        }
    }

    static func clean(_ text: String) -> String { String(SecretRedactor.redact(text).text.prefix(200)) }
}
