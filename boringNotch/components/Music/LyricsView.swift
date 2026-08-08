//
//  LyricsView.swift
//  Gradia
//
//  Karaoke panel shown in the opened notch. Highlights the line matching the
//  current playback position and lets you click any line to jump there.
//

import Defaults
import SwiftUI

struct LyricsView: View {
    @ObservedObject private var lyrics = LyricsManager.shared
    @ObservedObject private var musicManager = MusicManager.shared
    @EnvironmentObject var vm: BoringViewModel

    @Default(.playerColorTinting) private var colorTinting

    /// Auto-scroll is paused until this moment, so paging by hand isn't yanked
    /// back to the current line on the next tick.
    @State private var manualScrollUntil: Date = .distantPast
    /// Where the manual scroller currently sits, in line indices.
    @State private var browseIndex: Int = 0

    /// Recomputed on a timer rather than bound to `elapsedTime`, because media
    /// controllers only report position on state changes — between those, the
    /// position has to be extrapolated.
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { timeline in
            let elapsed = musicManager.estimatedPlaybackPosition(at: timeline.date)
            let activeIndex = lyrics.activeIndex(at: elapsed)

            HStack(alignment: .top, spacing: 14) {
                artwork
                VStack(alignment: .leading, spacing: 6) {
                    header
                    body(activeIndex: activeIndex)
                }
            }
            .padding(.top, 8)
            .padding(.horizontal, 6)
            .padding(.bottom, 4)
        }
    }

    private var accent: Color {
        colorTinting
            ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.75)
            : .white
    }

    // MARK: - Chrome

    private var artwork: some View {
        Image(nsImage: musicManager.albumArt)
            .resizable()
            .aspectRatio(1, contentMode: .fit)
            .frame(width: 68, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
    }

    private var header: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text(musicManager.songTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(musicManager.artistName)
                    .font(.system(size: 11))
                    .foregroundStyle(accent.opacity(0.85))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if lyrics.status == .synced {
                offsetControls
            }

            if lyrics.status == .notFound || lyrics.status == .failed {
                Button {
                    lyrics.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.gray)
                }
                .buttonStyle(.plain)
                .help("Search again")
            }
        }
    }

    /// Nudges timing when a community LRC file sits slightly ahead or behind.
    private var offsetControls: some View {
        HStack(spacing: 3) {
            Button {
                Defaults[.lyricsOffset] -= 0.25
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("Show lyrics later")

            Text(offsetLabel)
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .frame(width: 34)

            Button {
                Defaults[.lyricsOffset] += 0.25
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("Show lyrics earlier")
        }
        .foregroundStyle(.gray)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { Defaults[.lyricsOffset] = 0 }
        .help("Double-click to reset")
    }

    private var offsetLabel: String {
        let offset = Defaults[.lyricsOffset]
        if abs(offset) < 0.01 { return "sync" }
        return String(format: "%+.2fs", offset)
    }

    // MARK: - Content

    @ViewBuilder
    private func body(activeIndex: Int?) -> some View {
        switch lyrics.status {
        case .idle:
            placeholder(icon: "music.note", message: "Nothing playing")
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Searching lyrics…")
                    .font(.system(size: 12))
                    .foregroundStyle(.gray)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        case .instrumental:
            placeholder(icon: "music.quarternote.3", message: "Instrumental — no lyrics")
        case .notFound:
            placeholder(icon: "text.magnifyingglass", message: "No lyrics found for this track")
        case .failed:
            placeholder(icon: "wifi.exclamationmark", message: "Couldn't reach the lyrics service")
        case .plain:
            // Same scroller as synced, minus the highlight — unsynced sheets
            // have no auto-scroll at all, so paging is the only way through.
            lyricsScroll(activeIndex: nil)
        case .synced:
            lyricsScroll(activeIndex: activeIndex)
        }
    }

    private func placeholder(icon: String, message: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12))
            Text(message)
                .font(.system(size: 12))
        }
        .foregroundStyle(.gray)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// True while a manual page is still holding auto-scroll off.
    private var isBrowsing: Bool { Date() < manualScrollUntil }

    private func lyricsScroll(activeIndex: Int?) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 5) {
                    // Leading pad so the first line can sit mid-panel rather
                    // than pinned to the top edge.
                    Color.clear.frame(height: 26)

                    ForEach(lyrics.lines) { line in
                        if line.isGap {
                            // Timestamped blank line: an instrumental break.
                            // Rendering it keeps the previous verse from
                            // lingering on screen through the whole interlude.
                            Circle()
                                .fill(.gray.opacity(0.35))
                                .frame(width: 4, height: 4)
                                // Asymmetric on purpose: the row above already provides the
                // breathing room at the top, so only the bottom edge needed
                // easing off the notch's lower curve.
                .padding(.top, 3)
                .padding(.bottom, 8)
                                .id(line.id)
                        } else {
                            lineView(line, isActive: line.id == activeIndex)
                                .id(line.id)
                        }
                    }

                    Color.clear.frame(height: 40)
                }
                .padding(.trailing, 4)
            }
            .mask(fadeMask)
            .overlay(alignment: .bottomTrailing) {
                scrollControls(proxy: proxy, activeIndex: activeIndex)
            }
            .onChange(of: activeIndex) { _, newIndex in
                guard let newIndex, Date() >= manualScrollUntil else { return }
                browseIndex = newIndex
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
            // Auto-scroll used to resume only on the *next* line change, so
            // after paging by hand the view sat on the wrong verse until the
            // singer moved on. This re-snaps the moment the pause expires.
            // `isBrowsing` is recomputed every timeline tick, so the flip to
            // false is observable.
            .onChange(of: isBrowsing) { _, browsing in
                guard !browsing, let activeIndex else { return }
                browseIndex = activeIndex
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(activeIndex, anchor: .center)
                }
            }
            .onChange(of: lyrics.currentKey) { _, _ in
                // New track: drop any manual browsing state.
                manualScrollUntil = .distantPast
                browseIndex = 0
            }
        }
    }

    /// Paging buttons. Unsynced lyrics never scroll themselves, and even on a
    /// synced sheet it's useful to read ahead without seeking the track.
    private func scrollControls(proxy: ScrollViewProxy, activeIndex: Int?) -> some View {
        HStack(spacing: 3) {
            if isBrowsing, let activeIndex {
                Button {
                    manualScrollUntil = .distantPast
                    browseIndex = activeIndex
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(activeIndex, anchor: .center)
                    }
                } label: {
                    Image(systemName: "location.fill")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Back to the current line")
            }

            pageButton("chevron.up", proxy: proxy, delta: -3)
            pageButton("chevron.down", proxy: proxy, delta: 3)
        }
        .foregroundStyle(.gray)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(Capsule().fill(.black.opacity(0.45)))
        .padding(.trailing, 2)
        .padding(.bottom, 2)
        .opacity(lyrics.lines.count > 4 ? 1 : 0)
    }

    private func pageButton(_ icon: String, proxy: ScrollViewProxy, delta: Int) -> some View {
        Button {
            let maxIndex = max(0, lyrics.lines.count - 1)
            browseIndex = min(max(0, browseIndex + delta), maxIndex)
            // Hold auto-scroll off long enough to actually read.
            manualScrollUntil = Date().addingTimeInterval(8)
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(browseIndex, anchor: .center)
            }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .bold))
                .frame(width: 14, height: 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func lineView(_ line: LyricLine, isActive: Bool) -> some View {
        Text(line.text)
            .font(.system(size: isActive ? 14 : 12.5,
                          weight: isActive ? .bold : .medium))
            .foregroundStyle(isActive ? AnyShapeStyle(accent) : AnyShapeStyle(Color.gray.opacity(0.55)))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                MusicManager.shared.seek(to: max(0, line.time - Defaults[.lyricsOffset]))
            }
            .animation(.easeInOut(duration: 0.2), value: isActive)
    }

    /// Softens the clipped edges so lines dissolve instead of being chopped.
    private var fadeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.16),
                .init(color: .black, location: 0.84),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        )
    }
}

// MARK: - Compact inline line

/// One-line view rendered under the artist name on the home tab.
struct InlineLyricLineView: View {
    @ObservedObject private var lyrics = LyricsManager.shared
    @ObservedObject private var musicManager = MusicManager.shared
    let width: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
            let elapsed = musicManager.estimatedPlaybackPosition(at: timeline.date)
            MarqueeText(
                .constant(text(at: elapsed)),
                font: .subheadline,
                nsFont: .subheadline,
                textColor: lyrics.status == .loading ? .gray.opacity(0.6) : .gray,
                frameWidth: width
            )
            .lineLimit(1)
            .opacity(musicManager.isPlaying ? 1 : 0.5)
        }
    }

    private func text(at elapsed: TimeInterval) -> String {
        switch lyrics.status {
        case .loading: return "Searching lyrics…"
        case .instrumental: return "♪"
        case .notFound: return "No lyrics found"
        case .failed: return "Lyrics unavailable"
        case .idle: return ""
        case .plain:
            return lyrics.plainText
                .components(separatedBy: .newlines)
                .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        case .synced:
            // Empty during instrumental gaps — intentional, it mirrors the panel.
            return lyrics.activeLine(at: elapsed) ?? ""
        }
    }
}

// MARK: - Compact strip under the closed notch

/// A single lyric line shown beneath the closed notch while music plays.
///
/// Kept separate from the live activity: replacing the spectrum meant widening
/// the notch itself, which pushed the cutout out of line with the hardware one
/// and left a hollow bar whenever a line wasn't playing. A strip of its own can
/// simply not exist in those moments.
struct CompactLyricStrip: View {
    @ObservedObject private var lyrics = LyricsManager.shared
    @ObservedObject private var musicManager = MusicManager.shared
    @EnvironmentObject var vm: BoringViewModel

    /// Matches the live-activity row exactly. Deriving it separately is what
    /// let the two disagree and shifted the notch as lines changed length.
    let width: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { timeline in
            let elapsed = musicManager.estimatedPlaybackPosition(at: timeline.date)
            let line = lyrics.activeLine(at: elapsed) ?? ""

            Text(line)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(colour)
                .lineLimit(1)
                .truncationMode(.tail)
                .id(line)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                // Pinned to the live-activity row's own width so the line sits
                // centred under it. The parent is a leading-aligned VStack, so
                // without an explicit width the text hugs the left edge.
                .frame(width: width, alignment: .center)
                .minimumScaleFactor(0.75)
                // Asymmetric on purpose: the row above already provides the
                // breathing room at the top, so only the bottom edge needed
                // easing off the notch's lower curve.
                .padding(.top, 3)
                .padding(.bottom, 8)
                .animation(.spring(response: 0.32, dampingFraction: 0.82), value: line)
                // An instrumental gap collapses the strip rather than leaving a
                // blank bar sitting under the notch.
                .opacity(line.isEmpty ? 0 : 1)
                .frame(height: line.isEmpty ? 0 : nil)
        }
        .fixedSize(horizontal: true, vertical: true)
    }

    private var colour: Color {
        Defaults[.playerColorTinting] ? musicManager.palette.highlight : .gray
    }
}
