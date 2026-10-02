import Foundation
@testable import UnragerKit

/// A fake transport that answers each `send` with the next scripted outcome
/// (the last one repeats) and records every request it was given.
actor ScriptedTransport: HTTPTransport {
    enum Outcome: Sendable {
        case response(status: Int, body: String, headers: [String: String] = [:])
        case failure(APIError)
    }

    private var outcomes: [Outcome]
    private(set) var requests: [HTTPRequest] = []

    init(_ outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    init(status: Int = 200, body: String, headers: [String: String] = [:]) {
        self.init([.response(status: status, body: body, headers: headers)])
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        let outcome = outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0]
        switch outcome {
        case let .response(status, body, headers):
            return HTTPResponse(status: status, headers: headers, body: Data(body.utf8))
        case let .failure(error):
            throw error
        }
    }

    func stream(_ request: HTTPRequest) async throws -> (Int, AsyncThrowingStream<String, Error>) {
        requests.append(request)
        return (200, AsyncThrowingStream { $0.finish() })
    }

    func last() -> HTTPRequest? { requests.last }
}

extension URL {
    static let testServer = URL(string: "http://server:7777")!
}
