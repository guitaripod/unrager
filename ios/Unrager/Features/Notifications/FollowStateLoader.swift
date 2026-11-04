import UIKit
import UnragerKit

/// Whether the user follows each person a "followed you" row shows, so the row
/// can offer Follow back only to someone not yet followed. The server answers
/// this one account at a time, so lookups run two at a time, once per person,
/// as rows come on screen. A person whose state can't be read stays `unknown`
/// and gets no button rather than a guess; a lookup that failed is tried again
/// when the row next draws, once `retryAfter` has passed.
@MainActor
final class FollowStateLoader {
    enum State: Equatable {
        case unknown, loading, following, notFollowing, followingNow
    }

    private static let maxConcurrent = 2

    var onChange: ((String) -> Void)?
    /// Told the handle when a Follow back the server refused was put back.
    var onFollowFailed: ((String) -> Void)?

    private static let retryAfter: TimeInterval = 30

    private let social = SocialAPI(baseURL: { AppSettings.serverURL })
    private var states: [String: State] = [:]
    private var queue: [(restID: String, handle: String)] = []
    private var inFlight = 0
    private var failedAt: [String: Date] = [:]

    func state(for restID: String) -> State { states[restID] ?? .unknown }

    /// Starts reading `restID`'s state unless it is known or already being read.
    func request(restID: String, handle: String) {
        if let failed = failedAt[restID], Date().timeIntervalSince(failed) > Self.retryAfter {
            failedAt[restID] = nil
            states[restID] = nil
        }
        guard states[restID] == nil else { return }
        states[restID] = .loading
        queue.append((restID, handle))
        pump()
    }

    /// Follows `restID` at once on screen and tells the server; a refusal puts
    /// the button back.
    func follow(restID: String, handle: String) {
        guard state(for: restID) == .notFollowing else { return }
        set(.followingNow, for: restID)
        Haptics.success()
        Task {
            do {
                let result = try await social.follow(userID: restID)
                set(result.following ? .followingNow : .notFollowing, for: restID)
            } catch {
                AppLogger.shared.warn("follow back failed: \(error)", category: .timeline)
                Haptics.error()
                set(.notFollowing, for: restID)
                onFollowFailed?(handle)
            }
        }
    }

    private func pump() {
        while inFlight < Self.maxConcurrent, !queue.isEmpty {
            let next = queue.removeFirst()
            inFlight += 1
            Task {
                defer {
                    inFlight -= 1
                    pump()
                }
                do {
                    let view = try await social.profile(handle: next.handle, includeTweets: false)
                    let state: State = view.followedByMe.map { $0 ? .following : .notFollowing } ?? .unknown
                    set(state, for: next.restID)
                } catch {
                    AppLogger.shared.warn("follow state unavailable: \(error)", category: .timeline)
                    failedAt[next.restID] = Date()
                    set(.unknown, for: next.restID)
                }
            }
        }
    }

    private func set(_ state: State, for restID: String) {
        guard states[restID] != state else { return }
        states[restID] = state
        onChange?(restID)
    }
}
