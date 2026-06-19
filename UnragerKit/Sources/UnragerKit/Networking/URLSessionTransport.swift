import Foundation

/// `HTTPTransport` over `URLSession`. Cross-platform (Foundation only), so both
/// the iOS and macOS apps share it.
public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 60
            configuration.waitsForConnectivity = false
            configuration.httpAdditionalHeaders = ["Accept-Encoding": "gzip, br"]
            self.session = URLSession(configuration: configuration)
        }
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        do {
            let (data, response) = try await session.data(for: urlRequest(from: request))
            guard let http = response as? HTTPURLResponse else {
                throw APIError.network("Non-HTTP response")
            }
            return HTTPResponse(status: http.statusCode, headers: headers(http), body: data)
        } catch let error as APIError {
            throw error
        } catch let error as URLError {
            throw Self.map(error)
        } catch {
            throw APIError.network(error.localizedDescription)
        }
    }

    public func stream(_ request: HTTPRequest) async throws -> (Int, AsyncThrowingStream<String, Error>) {
        var urlRequest = urlRequest(from: request)
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.timeoutInterval = 300

        do {
            let (bytes, response) = try await session.bytes(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.network("Non-HTTP response")
            }
            let stream = AsyncThrowingStream<String, Error> { continuation in
                let task = Task {
                    do {
                        for try await line in bytes.lines {
                            continuation.yield(line)
                        }
                        continuation.finish()
                    } catch is CancellationError {
                        continuation.finish()
                    } catch let error as URLError where error.code == .cancelled {
                        continuation.finish()
                    } catch let error as URLError {
                        continuation.finish(throwing: Self.map(error))
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
            return (http.statusCode, stream)
        } catch let error as URLError {
            throw Self.map(error)
        }
    }

    private func urlRequest(from request: HTTPRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        return urlRequest
    }

    private func headers(_ http: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String { result[key] = "\(value)" }
        }
        return result
    }

    private static func map(_ error: URLError) -> APIError {
        switch error.code {
        case .timedOut: return .timeout
        case .cancelled: return .cancelled
        case .notConnectedToInternet, .cannotConnectToHost, .networkConnectionLost,
             .cannotFindHost, .dnsLookupFailed:
            return .network(error.localizedDescription)
        default:
            return .network(error.localizedDescription)
        }
    }
}
