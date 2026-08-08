//
//  SpotifySearchView.swift
//  Gradia
//
//  Search the Spotify catalogue from inside the notch and play a result with
//  one click.
//

import Defaults
import SwiftUI

struct SpotifySearchView: View {
    @ObservedObject private var service = SpotifySearchService.shared
    @ObservedObject private var musicManager = MusicManager.shared
    @EnvironmentObject var vm: BoringViewModel

    @FocusState private var searchFocused: Bool
    @State private var selection: Int = 0

    private var accent: Color {
        Defaults[.playerColorTinting] ? musicManager.palette.highlight : .white
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            searchField
            content
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .onAppear {
            // Opening the gate is what makes the text field typable at all.
            NotchKeyboardFocus.shared.begin()
            service.refreshCredentialState()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                searchFocused = true
            }
        }
        .onDisappear {
            NotchKeyboardFocus.shared.end()
        }
    }

    // MARK: - Field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.gray)

            TextField("Search Spotify…", text: $service.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .focused($searchFocused)
                .onSubmit { playSelected() }

            if !service.query.isEmpty {
                Button {
                    service.query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.gray)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Capsule().fill(.white.opacity(0.10)))
        .overlay(Capsule().stroke(.white.opacity(0.08), lineWidth: 1))
        // Arrow keys move the highlight without leaving the field.
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        switch service.state {
        case .needsCredentials:
            credentialsPrompt
        case .idle:
            hint("Type to search Spotify's catalogue")
        case .searching:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Searching…").font(.system(size: 12)).foregroundStyle(.gray)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .empty:
            hint("Nothing found for “\(service.query)”")
        case .failed(let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(message).lineLimit(2)
            }
            .font(.system(size: 12))
            .foregroundStyle(.orange.opacity(0.9))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .results(let tracks):
            results(tracks)
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.gray)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func results(_ tracks: [SpotifyTrack]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        row(track, isSelected: index == selection)
                            .id(index)
                            .onTapGesture {
                                selection = index
                                service.play(track)
                            }
                    }
                }
            }
            .onChange(of: selection) { _, new in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(new, anchor: .center) }
            }
            .onChange(of: tracks) { _, _ in selection = 0 }
        }
    }

    private func row(_ track: SpotifyTrack, isSelected: Bool) -> some View {
        HStack(spacing: 9) {
            artwork(track)

            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.gray)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Text(track.durationText)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.gray)

            Image(systemName: "play.fill")
                .font(.system(size: 10))
                .foregroundStyle(isSelected ? accent : .clear)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Color.white.opacity(0.12) : .clear)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func artwork(_ track: SpotifyTrack) -> some View {
        if let url = track.artworkURL {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.white.opacity(0.08)
            }
            .frame(width: 30, height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        } else {
            RoundedRectangle(cornerRadius: 5)
                .fill(.white.opacity(0.08))
                .frame(width: 30, height: 30)
        }
    }

    // MARK: - Setup prompt

    private var credentialsPrompt: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Add a Spotify Client ID to search from here.")
                .font(.system(size: 12))
                .foregroundStyle(.gray)

            HStack(spacing: 8) {
                Button("Open Settings") {
                    SettingsWindowController.shared.showWindow()
                }
                // Still useful with no setup at all: hand the query to Spotify.
                Button("Search in Spotify app") {
                    service.searchInSpotifyApp()
                }
                .disabled(service.query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .font(.system(size: 11))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Keyboard

    private func move(_ delta: Int) {
        guard case .results(let tracks) = service.state, !tracks.isEmpty else { return }
        selection = min(max(0, selection + delta), tracks.count - 1)
    }

    private func playSelected() {
        guard case .results(let tracks) = service.state,
              tracks.indices.contains(selection) else {
            // No results yet — fall back to handing the query to Spotify.
            if !SpotifyCredentials.isConfigured { service.searchInSpotifyApp() }
            return
        }
        service.play(tracks[selection])
    }
}
