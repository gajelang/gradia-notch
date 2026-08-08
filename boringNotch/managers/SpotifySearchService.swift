//
//  SpotifySearchService.swift
//  Gradia
//
//  Searches the Spotify catalogue and hands results to the local Spotify app
//  to play.
//
//  Two halves, deliberately:
//    • Searching needs the Web API — Spotify's AppleScript dictionary has no
//      search command at all (verified against its .sdef).
//    • Playing uses AppleScript `play track "spotify:track:…"`, which drives
//      the desktop app directly. The Web API's playback endpoints require
//      Premium; AppleScript does not, so this works on free accounts too.
//
//  Auth uses the client-credentials flow: it reaches the public catalogue with
//  no user login, no redirect URI, and no access to anyone's account. The
//  secret lives in the Keychain and is never written to preferences.
//

import AppKit
import Combine
import Foundation

// MARK: - Result model

struct SpotifyTrack: Identifiable, Equatable {
    let id: String
    let uri: String
    let title: String
    let artist: String
    let album: String
    let artworkURL: URL?
    let durationMs: Int

    var durationText: String {
        let total = durationMs / 1000
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Credential storage

/// Keychain-backed. Preferences are a plist in the container — readable by
/// anything that can read the user's files — which is no place for a secret.
enum SpotifyCredentials {
    private static let service = "com.elangsamudra.gradia.spotify"
    private static let clientIDKey = "clientID"
    private static let clientSecretKey = "clientSecret"

    static var clientID: String? {
        get { read(clientIDKey) }
        set { write(clientIDKey, newValue) }
    }

    static var clientSecret: String? {
        get { read(clientSecretKey) }
        set { write(clientSecretKey, newValue) }
    }

    static var isConfigured: Bool {
        !(clientID ?? "").isEmpty && !(clientSecret ?? "").isEmpty
    }

    static func clear() {
        write(clientIDKey, nil)
        write(clientSecretKey, nil)
    }

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func read(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private static func write(_ account: String, _ value: String?) -> Bool {
        let q = query(account)
        SecItemDelete(q as CFDictionary)

        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return true }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        // Ignoring this meant a locked or refusing Keychain still showed
        // "Saved", and search then failed with a credentials error that pointed
        // the user at a typo they never made.
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("Spotify credentials: Keychain write failed (OSStatus \(status))")
        }
        return status == errSecSuccess
    }

    /// True only if both halves are actually readable back out of the Keychain.
    static func verifyStored(id: String, secret: String) -> Bool {
        clientID == id && clientSecret == secret
    }
}

// MARK: - Service

@MainActor
final class SpotifySearchService: ObservableObject {
    static let shared = SpotifySearchService()

    enum State: Equatable {
        case idle
        case needsCredentials
        case searching
        case results([SpotifyTrack])
        case empty
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published var query: String = "" {
        didSet { scheduleSearch() }
    }

    private var searchTask: Task<Void, Never>?
    private var token: (value: String, expiry: Date)?

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        return URLSession(configuration: config)
    }()

    private init() {}

    // MARK: Searching

    func refreshCredentialState() {
        if !SpotifyCredentials.isConfigured {
            state = .needsCredentials
        } else if query.isEmpty {
            state = .idle
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state = SpotifyCredentials.isConfigured ? .idle : .needsCredentials
            return
        }
        guard SpotifyCredentials.isConfigured else {
            state = .needsCredentials
            return
        }

        state = .searching
        searchTask = Task { [weak self] in
            // Debounce: nobody wants a request per keystroke, and Spotify
            // rate-limits hard.
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            await self?.performSearch(trimmed)
        }
    }

    private func performSearch(_ text: String) async {
        do {
            let accessToken = try await validToken()
            guard !Task.isCancelled else { return }

            var components = URLComponents(string: "https://api.spotify.com/v1/search")!
            components.queryItems = [
                URLQueryItem(name: "q", value: text),
                URLQueryItem(name: "type", value: "track"),
                URLQueryItem(name: "limit", value: "8"),
            ]

            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await session.data(for: request)
            guard !Task.isCancelled else { return }

            guard let http = response as? HTTPURLResponse else {
                state = .failed("No response from Spotify")
                return
            }
            if http.statusCode == 401 {
                // Token went stale mid-flight; drop it so the next attempt refetches.
                token = nil
                state = .failed("Spotify rejected the token — try again")
                return
            }
            if http.statusCode == 429 {
                state = .failed("Rate limited by Spotify — wait a moment")
                return
            }
            guard http.statusCode == 200 else {
                state = .failed("Spotify returned \(http.statusCode)")
                return
            }

            let tracks = try decodeTracks(data)
            state = tracks.isEmpty ? .empty : .results(tracks)
        } catch is CancellationError {
            return
        } catch let error as SearchError {
            state = .failed(error.message)
        } catch {
            state = .failed("Couldn't reach Spotify")
        }
    }

    private func decodeTracks(_ data: Data) throws -> [SpotifyTrack] {
        struct Response: Decodable {
            struct Tracks: Decodable { let items: [Item] }
            struct Item: Decodable {
                struct Artist: Decodable { let name: String }
                struct Album: Decodable {
                    struct Image: Decodable { let url: String; let width: Int? }
                    let name: String
                    let images: [Image]
                }
                let id: String
                let uri: String
                let name: String
                let artists: [Artist]
                let album: Album
                let durationMs: Int

                enum CodingKeys: String, CodingKey {
                    case id, uri, name, artists, album
                    case durationMs = "duration_ms"
                }
            }
            let tracks: Tracks
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return decoded.tracks.items.map { item in
            // Smallest image that exists — these render at 32pt.
            let art = item.album.images
                .filter { $0.width != nil }
                .min { ($0.width ?? .max) < ($1.width ?? .max) }
                ?? item.album.images.last

            return SpotifyTrack(
                id: item.id,
                uri: item.uri,
                title: item.name,
                artist: item.artists.map(\.name).joined(separator: ", "),
                album: item.album.name,
                artworkURL: art.flatMap { URL(string: $0.url) },
                durationMs: item.durationMs
            )
        }
    }

    // MARK: Token

    private struct SearchError: Error { let message: String }

    private func validToken() async throws -> String {
        // 30s of slack so a token doesn't expire between check and use.
        if let token, token.expiry > Date().addingTimeInterval(30) {
            return token.value
        }

        guard let id = SpotifyCredentials.clientID,
              let secret = SpotifyCredentials.clientSecret
        else { throw SearchError(message: "Spotify credentials are missing") }

        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        // Credentials go in a Basic header, which is what Spotify documents for
        // this flow. Passing them as body parameters also happens to work, but
        // following the documented path avoids depending on undocumented
        // leniency — and keeps the secret out of the request body.
        let pair = Data("\(id):\(secret)".utf8).base64EncodedString()
        request.setValue("Basic \(pair)", forHTTPHeaderField: "Authorization")

        var body = URLComponents()
        body.queryItems = [URLQueryItem(name: "grant_type", value: "client_credentials")]
        request.httpBody = body.query?.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SearchError(message: "No response from Spotify")
        }
        guard http.statusCode == 200 else {
            // The overwhelmingly common cause is a typo in the ID or secret.
            throw SearchError(message: "Spotify rejected the credentials — check the Client ID and Secret")
        }

        struct TokenResponse: Decodable {
            let accessToken: String
            let expiresIn: Int
            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case expiresIn = "expires_in"
            }
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        token = (decoded.accessToken, Date().addingTimeInterval(TimeInterval(decoded.expiresIn)))
        return decoded.accessToken
    }

    /// Discards any cached token, so corrected credentials take effect at once.
    func invalidateToken() {
        token = nil
    }

    // MARK: Playback

    /// Hands the track to the desktop app. Web API playback needs Premium;
    /// this doesn't.
    ///
    /// The URI is interpolated into a script, so it is validated against the
    /// exact shape Spotify documents first. It arrives over the network, and
    /// unchecked text reaching AppleScript is a code-execution path — a quote
    /// in the wrong place would end the string literal and run whatever follows.
    func play(_ track: SpotifyTrack) {
        guard Self.isValidTrackURI(track.uri) else {
            NSLog("Spotify search: refusing to play malformed URI")
            return
        }

        // Spotify pulls itself to the front whenever it receives `play track`
        // — measured, not assumed. Opening the `spotify:track:` URL with
        // `activates = false` doesn't help either: it steals focus just the
        // same and doesn't even change the track. So the only route left is to
        // hand focus back afterwards.
        //
        // The app to hand it back to is *not* whatever is frontmost right now:
        // typing in the search field made Gradia frontmost, and re-activating
        // ourselves would leave Spotify sitting on top.
        let previous = Self.appToRestoreFocusTo()

        Task {
            try? await AppleScriptHelper.executeVoid(
                "tell application \"Spotify\" to play track \"\(track.uri)\""
            )
            // Let Spotify finish coming forward, otherwise its activation lands
            // after ours and wins.
            try? await Task.sleep(for: .milliseconds(180))

            await MainActor.run {
                guard let previous, !previous.isTerminated else { return }
                previous.activate()
            }
        }
    }

    /// The app the user was actually in. Falls back to the one recorded when
    /// the notch took keyboard focus, and never returns Gradia or Spotify —
    /// activating either of those defeats the purpose.
    @MainActor
    private static func appToRestoreFocusTo() -> NSRunningApplication? {
        let excluded: Set<String> = [
            Bundle.main.bundleIdentifier ?? "",
            "com.spotify.client",
        ]

        if let front = NSWorkspace.shared.frontmostApplication,
           let id = front.bundleIdentifier, !excluded.contains(id) {
            return front
        }
        if let remembered = NotchKeyboardFocus.shared.appBeforeFocus,
           let id = remembered.bundleIdentifier, !excluded.contains(id) {
            return remembered
        }
        return nil
    }

    /// `spotify:track:` followed by a base-62 id. Nothing else is accepted.
    static func isValidTrackURI(_ uri: String) -> Bool {
        guard uri.hasPrefix("spotify:track:") else { return false }
        let id = uri.dropFirst("spotify:track:".count)
        return !id.isEmpty && id.count <= 40 && id.allSatisfy(\.isASCII)
            && id.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// Fallback when no credentials are set: let the Spotify app do the
    /// searching, so the feature is still useful with zero setup.
    func searchInSpotifyApp() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let encoded = text.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "spotify:search:\(encoded)")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
