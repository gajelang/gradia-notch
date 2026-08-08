//
//  LyricsManager.swift
//  Gradia
//
//  Fetches and tracks time-synced lyrics for whatever is currently playing.
//
//  Lyrics come from LRCLIB (https://lrclib.net), which is free and needs no
//  auth. The tricky part is picking the *right* record: a title+artist search
//  routinely returns twenty near-identical entries whose timings differ by
//  seconds, so matching leans on track duration first and only falls back to
//  fuzzy search when an exact lookup misses.
//

import AppKit
import Combine
import Defaults
import Foundation

// MARK: - Models

/// One line of a lyric sheet. A line with empty `text` is a deliberate gap
/// (instrumental break) — LRCLIB emits those as timestamped blank lines, and
/// keeping them is what lets the UI clear the screen between verses.
struct LyricLine: Identifiable, Equatable, Codable {
    let id: Int
    let time: TimeInterval
    let text: String

    var isGap: Bool { text.isEmpty }
}

enum LyricsStatus: String, Equatable, Codable {
    /// Nothing playing, or lyrics turned off.
    case idle
    case loading
    /// Timestamped lines — karaoke highlighting works.
    case synced
    /// Lyrics found, but with no timings. Displayed as a static block.
    case plain
    /// LRCLIB knows this track and says it has no words.
    case instrumental
    case notFound
    case failed

    var isResolved: Bool {
        switch self {
        case .synced, .plain, .instrumental: return true
        case .idle, .loading, .notFound, .failed: return false
        }
    }
}

/// Resolved lyrics for one track, whatever the source.
struct LyricsOutcome {
    var lines: [LyricLine] = []
    var plainText: String = ""
    var status: LyricsStatus = .notFound
}

/// Identity of a track for lookup + cache purposes.
struct LyricsTrackKey: Equatable, Hashable {
    let title: String
    let artist: String
    let album: String
    /// Whole seconds. Playback position jitters, durations don't, but rounding
    /// keeps a 200.4s vs 200.0s report from splitting the cache in two.
    let duration: Int

    init(title: String, artist: String, album: String, duration: TimeInterval) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration.isFinite && duration > 0 ? Int(duration.rounded()) : 0
    }

    var isUsable: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Stable filename for the on-disk cache.
    var cacheFilename: String {
        let raw = "\(title.lowercased())|\(artist.lowercased())|\(album.lowercased())|\(duration)"
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(raw.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        return String(format: "%016llx.json", hash)
    }
}

// MARK: - Manager

@MainActor
final class LyricsManager: ObservableObject {
    static let shared = LyricsManager()

    @Published private(set) var lines: [LyricLine] = []
    @Published private(set) var status: LyricsStatus = .idle
    @Published private(set) var currentKey: LyricsTrackKey?

    /// Plain-text body, kept for the unsynced case and for copy-to-clipboard.
    @Published private(set) var plainText: String = ""

    private let client = LRCLIBClient()
    private let cache = LyricsCache()

    private var memoryCache: [LyricsTrackKey: (lines: [LyricLine], plain: String, status: LyricsStatus)] = [:]
    private var fetchTask: Task<Void, Never>?
    private var currentBundleIdentifier: String?

    private init() {}

    // MARK: Loading

    /// Entry point called by `MusicManager` whenever track metadata changes.
    /// Safe to call repeatedly with the same track — repeats are ignored.
    func load(title: String, artist: String, album: String, duration: TimeInterval,
              bundleIdentifier: String? = nil) {
        currentBundleIdentifier = bundleIdentifier
        guard Defaults[.enableLyrics] else {
            clear()
            return
        }

        let key = LyricsTrackKey(title: title, artist: artist, album: album, duration: duration)
        guard key.isUsable else {
            clear()
            return
        }
        // Same track — nothing to do. Without this, a duration that lands a
        // hair differently on each poll would refetch on every update.
        guard key != currentKey else { return }

        currentKey = key
        fetchTask?.cancel()

        if let hit = memoryCache[key] {
            apply(lines: hit.lines, plain: hit.plain, status: hit.status)
            return
        }

        lines = []
        plainText = ""
        status = .loading

        fetchTask = Task { [weak self] in
            guard let self else { return }

            // Small delay so rapid track-skipping doesn't fire a request per skip.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }

            if let cached = await self.cache.read(key: key) {
                guard !Task.isCancelled, self.currentKey == key else { return }
                self.memoryCache[key] = (cached.lines, cached.plainText, cached.status)
                self.apply(lines: cached.lines, plain: cached.plainText, status: cached.status)
                return
            }

            let outcome = await self.resolve(key: key)
            guard !Task.isCancelled, self.currentKey == key else { return }

            self.memoryCache[key] = (outcome.lines, outcome.plainText, outcome.status)
            self.apply(lines: outcome.lines, plain: outcome.plainText, status: outcome.status)

            // Don't persist transient network failures — those should retry.
            if outcome.status != .failed {
                await self.cache.write(key: key, lines: outcome.lines,
                                       plainText: outcome.plainText, status: outcome.status)
            }
        }
    }

    /// LRCLIB first — it's the only source with timings. Apple Music keeps its
    /// own (unsynced) lyrics for tracks in your library, which is worth falling
    /// back to when the community database comes up empty.
    private func resolve(key: LyricsTrackKey) async -> LyricsOutcome {
        let outcome = await client.lookup(key: key)
        guard outcome.status == .notFound,
              currentBundleIdentifier?.contains("com.apple.Music") == true,
              let native = await appleMusicLyrics()
        else { return outcome }

        let asLines = native.components(separatedBy: .newlines).enumerated().map {
            LyricLine(id: $0.offset, time: 0, text: $0.element.trimmingCharacters(in: .whitespaces))
        }
        return LyricsOutcome(lines: asLines, plainText: native, status: .plain)
    }

    private func appleMusicLyrics() async -> String? {
        guard !NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
        else { return nil }

        let script = """
        tell application "Music"
            if it is running then
                if player state is playing or player state is paused then
                    try
                        set l to lyrics of current track
                        if l is missing value then
                            return ""
                        else
                            return l
                        end if
                    on error
                        return ""
                    end try
                else
                    return ""
                end if
            else
                return ""
            end if
        end tell
        """

        guard let result = try? await AppleScriptHelper.execute(script),
              let text = result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        return text
    }

    func clear() {
        fetchTask?.cancel()
        fetchTask = nil

        // `load` runs on every playback update, so with lyrics switched off
        // this fired constantly. @Published publishes on assignment even when
        // the value is unchanged, which redrew the notch for nothing.
        guard currentKey != nil || status != .idle || !lines.isEmpty || !plainText.isEmpty
        else { return }

        currentKey = nil
        lines = []
        plainText = ""
        status = .idle
    }

    /// Forces a refetch of the current track, bypassing both caches. Wired to
    /// the retry button so a bad match isn't permanent.
    func refresh() {
        guard let key = currentKey else { return }
        memoryCache[key] = nil
        fetchTask?.cancel()
        lines = []
        plainText = ""
        status = .loading

        fetchTask = Task { [weak self] in
            guard let self else { return }
            await self.cache.remove(key: key)
            let outcome = await self.resolve(key: key)
            guard !Task.isCancelled, self.currentKey == key else { return }
            self.memoryCache[key] = (outcome.lines, outcome.plainText, outcome.status)
            self.apply(lines: outcome.lines, plain: outcome.plainText, status: outcome.status)
            if outcome.status != .failed {
                await self.cache.write(key: key, lines: outcome.lines,
                                       plainText: outcome.plainText, status: outcome.status)
            }
        }
    }

    private func apply(lines: [LyricLine], plain: String, status: LyricsStatus) {
        self.lines = lines
        self.plainText = plain
        self.status = status
    }

    // MARK: Position lookup

    /// Index of the line that should be highlighted at `elapsed`, or nil when
    /// playback sits before the first line or inside an instrumental gap.
    func activeIndex(at elapsed: TimeInterval) -> Int? {
        guard status == .synced, !lines.isEmpty else { return nil }

        let t = elapsed + Defaults[.lyricsOffset]
        guard t >= lines[0].time else { return nil }

        // Last line whose timestamp is at or before `t`.
        var low = 0
        var high = lines.count - 1
        var found = 0
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].time <= t {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return lines[found].isGap ? nil : found
    }

    /// Single-line text for the compact display under the artist name.
    func activeLine(at elapsed: TimeInterval) -> String? {
        guard let index = activeIndex(at: elapsed) else { return nil }
        return lines[index].text
    }
}

// MARK: - LRCLIB client

/// Networking + record selection. Isolated to its own actor so lookups never
/// touch the main thread.
private actor LRCLIBClient {
    private struct Record: Decodable {
        let id: Int
        let trackName: String?
        let artistName: String?
        let albumName: String?
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    private let base = "https://lrclib.net/api"
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    /// Set by `request` whenever a call fails for a reason other than a clean
    /// 404, so an offline machine reports `.failed` instead of poisoning the
    /// cache with a false "no lyrics exist".
    private var sawTransportError = false

    func lookup(key: LyricsTrackKey) async -> LyricsOutcome {
        sawTransportError = false
        let cleanTitle = LyricsText.cleanTitle(key.title)
        let cleanArtist = LyricsText.cleanArtist(key.artist)

        // 1. Exact lookup. When duration is known this is by far the most
        //    reliable path — LRCLIB matches within a couple of seconds.
        if key.duration > 0 {
            if let record = try? await get(track: cleanTitle, artist: cleanArtist,
                                           album: key.album, duration: key.duration) {
                return outcome(from: record)
            }
            // Album names disagree constantly across services (deluxe editions,
            // regional releases); retry without it before giving up on /get.
            if let record = try? await get(track: cleanTitle, artist: cleanArtist,
                                           album: nil, duration: key.duration) {
                return outcome(from: record)
            }
        }

        // 2. Fuzzy search, scored against what we actually know about the track.
        var candidates = (try? await search(track: cleanTitle, artist: cleanArtist)) ?? []
        if candidates.isEmpty {
            candidates = (try? await searchFreeform("\(cleanTitle) \(cleanArtist)")) ?? []
        }
        // The original (uncleaned) title can be the right one when a track
        // genuinely has "(Live)" in its name on both sides.
        if candidates.isEmpty, cleanTitle != key.title {
            candidates = (try? await search(track: key.title, artist: cleanArtist)) ?? []
        }

        guard !candidates.isEmpty else { return emptyOutcome }

        let judged = candidates
            .map { (record: $0, verdict: score($0, key: key, cleanTitle: cleanTitle, cleanArtist: cleanArtist)) }
            .filter { $0.verdict.score > 0 }

        // Candidates whose length agrees with the track we're playing.
        let consistent = judged.filter(\.verdict.durationTrusted)
        if let best = rank(consistent, against: key).first {
            return outcome(from: best.record)
        }

        // Nothing matched on length. Rather than give up, fall back to entries
        // whose title *and* artist match exactly — players do occasionally
        // report a duration that no lyric database agrees with.
        let exact = judged.filter(\.verdict.exactTextMatch)
        if let best = rank(exact, against: key).first {
            return outcome(from: best.record)
        }

        return emptyOutcome
    }

    /// A miss we can trust is `.notFound`; a miss caused by the network is
    /// `.failed`, which the manager deliberately never caches.
    private var emptyOutcome: LyricsOutcome {
        LyricsOutcome(status: sawTransportError ? .failed : .notFound)
    }

    private typealias Judged = (record: Record, verdict: Verdict)

    /// Best first: score, then closest duration, then longest lyric sheet.
    /// The last tiebreak matters because LRCLIB holds truncated stub entries
    /// that would otherwise win on score alone.
    private func rank(_ items: [Judged], against key: LyricsTrackKey) -> [Judged] {
        items.sorted { lhs, rhs in
            if lhs.verdict.score != rhs.verdict.score {
                return lhs.verdict.score > rhs.verdict.score
            }
            if key.duration > 0 {
                let lhsDelta = abs((lhs.record.duration ?? 0) - Double(key.duration))
                let rhsDelta = abs((rhs.record.duration ?? 0) - Double(key.duration))
                if lhsDelta != rhsDelta { return lhsDelta < rhsDelta }
            }
            return lineCount(lhs.record) > lineCount(rhs.record)
        }
    }

    private func lineCount(_ record: Record) -> Int {
        (record.syncedLyrics ?? record.plainLyrics ?? "")
            .components(separatedBy: .newlines)
            .count
    }

    // MARK: Requests

    /// Distinguishes "the database has nothing" from "we never reached the
    /// database" — only the former is worth remembering.
    private enum LookupError: Error {
        case notFound
        case transport
    }

    private func request(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        // LRCLIB's docs ask clients to identify themselves.
        req.setValue("Gradia/\(Bundle.main.releaseVersionNumber ?? "1.0") (macOS lyrics client)",
                     forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            sawTransportError = true
            throw LookupError.transport
        }

        guard let http = response as? HTTPURLResponse else {
            sawTransportError = true
            throw LookupError.transport
        }
        switch http.statusCode {
        case 200:
            return data
        case 404:
            throw LookupError.notFound
        default:
            sawTransportError = true
            throw LookupError.transport
        }
    }

    private func get(track: String, artist: String, album: String?, duration: Int) async throws -> Record {
        var components = URLComponents(string: "\(base)/get")!
        var items = [
            URLQueryItem(name: "track_name", value: track),
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "duration", value: String(duration)),
        ]
        if let album, !album.isEmpty, album != "Unknown" {
            items.append(URLQueryItem(name: "album_name", value: album))
        }
        components.queryItems = items
        let data = try await request(components.url!)
        return try JSONDecoder().decode(Record.self, from: data)
    }

    private func search(track: String, artist: String) async throws -> [Record] {
        var components = URLComponents(string: "\(base)/search")!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: track),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        let data = try await request(components.url!)
        return try JSONDecoder().decode([Record].self, from: data)
    }

    private func searchFreeform(_ query: String) async throws -> [Record] {
        var components = URLComponents(string: "\(base)/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        let data = try await request(components.url!)
        return try JSONDecoder().decode([Record].self, from: data)
    }

    // MARK: Ranking

    struct Verdict {
        /// Higher is better; 0 means "reject outright".
        var score: Double = 0
        /// The candidate's length agrees with the track we're playing.
        var durationTrusted = false
        /// Title *and* artist match after normalization.
        var exactTextMatch = false
    }

    /// Real songs shorter than this are rare; LRCLIB, being community-edited,
    /// carries stub records of a few seconds paired with a full lyric sheet.
    private static let minimumPlausibleDuration: Double = 30

    private func score(_ record: Record, key: LyricsTrackKey,
                       cleanTitle: String, cleanArtist: String) -> Verdict {
        var verdict = Verdict(score: 1)

        let candidateDuration = record.duration ?? 0
        if candidateDuration > 0, candidateDuration < Self.minimumPlausibleDuration,
           !(key.duration > 0 && Double(key.duration) < Self.minimumPlausibleDuration) {
            return Verdict()
        }

        // Duration is the strongest signal available. A wrong-length match is
        // the single most common way lyrics end up drifting out of sync.
        if key.duration > 0, candidateDuration > 0 {
            switch abs(candidateDuration - Double(key.duration)) {
            case ..<2: verdict.score += 10; verdict.durationTrusted = true
            case ..<5: verdict.score += 6; verdict.durationTrusted = true
            case ..<10: verdict.score += 1; verdict.durationTrusted = true
            default: break // a different recording — or a bad duration on our side
            }
        } else {
            // Nothing to contradict, so don't hold the missing value against it.
            verdict.durationTrusted = true
        }

        let title = LyricsText.normalize(record.trackName ?? "")
        let artist = LyricsText.normalize(record.artistName ?? "")
        let wantTitle = LyricsText.normalize(cleanTitle)
        let wantArtist = LyricsText.normalize(cleanArtist)

        let titleMatches = title == wantTitle
        let artistMatches = artist == wantArtist
        verdict.exactTextMatch = titleMatches && artistMatches

        if titleMatches { verdict.score += 4 }
        else if title.contains(wantTitle) { verdict.score += 1 }

        if artistMatches { verdict.score += 4 }
        else if artist.contains(wantArtist) { verdict.score += 1 }

        if let album = record.albumName, !key.album.isEmpty,
           LyricsText.normalize(album) == LyricsText.normalize(key.album) { verdict.score += 2 }

        // Prefer records that can actually drive the karaoke view.
        if let synced = record.syncedLyrics, !synced.isEmpty { verdict.score += 3 }
        else if let plain = record.plainLyrics, !plain.isEmpty { verdict.score += 0.5 }
        else if record.instrumental != true { return Verdict() } // nothing usable

        return verdict
    }

    private func outcome(from record: Record) -> LyricsOutcome {
        if record.instrumental == true {
            return LyricsOutcome(status: .instrumental)
        }
        if let synced = record.syncedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines),
           !synced.isEmpty {
            let parsed = LyricsText.parseLRC(synced)
            if !parsed.isEmpty {
                let plain = record.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? parsed.filter { !$0.isGap }.map(\.text).joined(separator: "\n")
                return LyricsOutcome(lines: parsed, plainText: plain, status: .synced)
            }
        }
        if let plain = record.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines),
           !plain.isEmpty {
            let asLines = plain.components(separatedBy: .newlines).enumerated().map {
                LyricLine(id: $0.offset, time: 0, text: $0.element.trimmingCharacters(in: .whitespaces))
            }
            return LyricsOutcome(lines: asLines, plainText: plain, status: .plain)
        }
        return LyricsOutcome(status: .notFound)
    }
}

// MARK: - Text handling

enum LyricsText {
    /// Matches every timestamp in an LRC line. A single line may carry several
    /// (`[00:12.00][01:20.00]same words`), which is how repeated choruses are
    /// encoded.
    private static let timestampRegex = try? NSRegularExpression(
        pattern: #"\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]"#
    )

    /// Parses LRC into sorted lines, *preserving* timestamped blank lines as
    /// gaps so the UI can clear itself during instrumental breaks.
    static func parseLRC(_ lrc: String) -> [LyricLine] {
        guard let regex = timestampRegex else { return [] }

        var parsed: [(time: TimeInterval, text: String)] = []

        for rawLine in lrc.components(separatedBy: .newlines) {
            let ns = rawLine as NSString
            let matches = regex.matches(in: rawLine, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }

            // Text is whatever follows the final timestamp on the line.
            let textStart = matches[matches.count - 1].range.upperBound
            let text = ns.substring(from: textStart).trimmingCharacters(in: .whitespaces)

            for match in matches {
                let minutes = Double(ns.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: match.range(at: 2))) ?? 0

                var fraction: Double = 0
                let fractionRange = match.range(at: 3)
                if fractionRange.location != NSNotFound {
                    let digits = ns.substring(with: fractionRange)
                    // "5" means .5s, "50" means .50s, "500" means .500s.
                    fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
                }
                parsed.append((minutes * 60 + seconds + fraction, text))
            }
        }

        return parsed
            .sorted { $0.time < $1.time }
            .enumerated()
            .map { LyricLine(id: $0.offset, time: $0.element.time, text: $0.element.text) }
    }

    /// Strips the decorations streaming services bolt onto titles, which
    /// otherwise sink an exact-match lookup.
    static func cleanTitle(_ title: String) -> String {
        var result = title

        let patterns = [
            #"\s*[-–—]\s*(\d{4}\s+)?(Remaster(ed)?|Re-?master(ed)?)(\s+\d{4})?$"#,
            #"\s*[-–—]\s*(Live|Radio Edit|Single Version|Album Version|Mono|Stereo|Deluxe)(\s+.*)?$"#,
            #"\s*\((\d{4}\s+)?(Remaster(ed)?|Re-?master(ed)?)(\s+\d{4})?\)"#,
            #"\s*[\(\[](feat\.?|ft\.?|featuring)[^\)\]]*[\)\]]"#,
            #"\s*[\(\[](Bonus Track|Deluxe|Explicit|Clean|Official (Music )?Video|Audio|Lyrics?)[^\)\]]*[\)\]]"#,
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(
                of: pattern, with: "", options: [.regularExpression, .caseInsensitive]
            )
        }

        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? title : result
    }

    /// Spotify reports collaborations as "A, B" or "A & B"; LRCLIB indexes the
    /// primary artist, so search on that.
    static func cleanArtist(_ artist: String) -> String {
        var result = artist
        for separator in [", ", " & ", " feat. ", " ft. ", " featuring ", " x ", " X "] {
            if let range = result.range(of: separator) {
                result = String(result[result.startIndex..<range.lowerBound])
            }
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? artist : result
    }

    /// Case/accent/punctuation-insensitive form used only for comparisons.
    static func normalize(_ string: String) -> String {
        string
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

// MARK: - Disk cache

/// Survives relaunches so a repeat listen costs nothing. Negative results are
/// cached too, but expire — LRCLIB is community-sourced and gains tracks daily.
private actor LyricsCache {
    private struct Entry: Codable {
        let lines: [LyricLine]
        let plainText: String
        let status: LyricsStatus
        let savedAt: Date
    }

    struct Result {
        let lines: [LyricLine]
        let plainText: String
        let status: LyricsStatus
    }

    private let negativeTTL: TimeInterval = 7 * 24 * 60 * 60

    private lazy var directory: URL? = {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = support
            .appendingPathComponent("Gradia", isDirectory: true)
            .appendingPathComponent("Lyrics", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func read(key: LyricsTrackKey) -> Result? {
        guard let url = directory?.appendingPathComponent(key.cacheFilename),
              let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data)
        else { return nil }

        if !entry.status.isResolved,
           Date().timeIntervalSince(entry.savedAt) > negativeTTL {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return Result(lines: entry.lines, plainText: entry.plainText, status: entry.status)
    }

    func write(key: LyricsTrackKey, lines: [LyricLine], plainText: String, status: LyricsStatus) {
        guard let url = directory?.appendingPathComponent(key.cacheFilename) else { return }
        let entry = Entry(lines: lines, plainText: plainText, status: status, savedAt: Date())
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func remove(key: LyricsTrackKey) {
        guard let url = directory?.appendingPathComponent(key.cacheFilename) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
