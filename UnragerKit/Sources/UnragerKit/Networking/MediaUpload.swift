import Foundation

/// `POST /api/media/upload` — the minted media id for `compose` `media_ids`.
public struct MediaUploadResult: Decodable, Sendable, Equatable {
    public let mediaID: String

    enum CodingKeys: String, CodingKey {
        case mediaID = "media_id"
    }

    public init(mediaID: String) {
        self.mediaID = mediaID
    }
}

/// Typed client for the publish pipeline: per-attachment media upload
/// (`POST /api/media/upload`, multipart `media` field → media id) and compose
/// with uploaded ids and/or a quote (`POST /api/compose` with `media_ids` /
/// `quote_tweet_id`, `POST /api/reply/{id}` with `media_ids`) — fields the
/// shared `APIClient.compose` predates. Standalone so the new surface ships
/// without touching the shared client.
public final class MediaUploadAPI: Sendable {
    private let transport: HTTPTransport
    private let baseURL: @Sendable () -> URL

    public init(transport: HTTPTransport = URLSessionTransport(),
                baseURL: @escaping @Sendable () -> URL) {
        self.transport = transport
        self.baseURL = baseURL
    }

    /// Uploads one attachment and returns its minted media id. Callers upload
    /// sequentially so per-item progress and per-item retry stay simple.
    public func upload(_ media: ComposeMedia) async throws -> String {
        var form = MultipartForm()
        form.appendFile(name: "media", media)
        let result: MediaUploadResult = try await send(form, to: "api/media/upload")
        return result.mediaID
    }

    /// Posts a tweet composed of `text`, previously-uploaded media ids, and an
    /// optional quoted tweet.
    public func compose(text: String, mediaIDs: [String] = [], quoteTweetID: String? = nil) async throws -> ComposeResult {
        var form = MultipartForm()
        if !text.isEmpty { form.appendField(name: "text", value: text) }
        for id in mediaIDs { form.appendField(name: "media_ids", value: id) }
        if let quoteTweetID { form.appendField(name: "quote_tweet_id", value: quoteTweetID) }
        return try await send(form, to: "api/compose")
    }

    /// Posts a reply to `tweetID` with `text` and previously-uploaded media ids.
    public func reply(to tweetID: String, text: String, mediaIDs: [String] = []) async throws -> ComposeResult {
        var form = MultipartForm()
        if !text.isEmpty { form.appendField(name: "text", value: text) }
        for id in mediaIDs { form.appendField(name: "media_ids", value: id) }
        return try await send(form, to: "api/reply/\(RequestPlumbing.pathSegment(tweetID))")
    }

    private func send<T: Decodable>(_ form: MultipartForm, to path: String) async throws -> T {
        let request = HTTPRequest(
            method: .post,
            url: RequestPlumbing.url(base: baseURL(), path: path),
            headers: ["Content-Type": form.contentType],
            body: form.finalized())
        return try await RequestPlumbing.perform(request, over: transport)
    }
}

/// Minimal `multipart/form-data` builder for the publish endpoints.
struct MultipartForm {
    let boundary = "unrager.\(UUID().uuidString)"
    private var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func appendField(name: String, value: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append(value)
        append("\r\n")
    }

    mutating func appendFile(name: String, _ file: ComposeMedia) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(file.filename)\"\r\n")
        append("Content-Type: \(file.mimeType)\r\n\r\n")
        body.append(file.data)
        append("\r\n")
    }

    func finalized() -> Data {
        var closed = body
        closed.append(Data("--\(boundary)--\r\n".utf8))
        return closed
    }

    private mutating func append(_ string: String) {
        body.append(Data(string.utf8))
    }
}
