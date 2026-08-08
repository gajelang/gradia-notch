//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import Defaults
import SwiftUI

struct TabModel: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    let view: NotchViews
}

/// Tabs whose feature is currently switched on. Home is always present, so a
/// single entry here means there is nothing to switch between.
@MainActor var availableTabs: [TabModel] {
    var result = [TabModel(label: "Home", icon: "house.fill", view: .home)]
    if Defaults[.boringShelf] {
        result.append(TabModel(label: "Shelf", icon: "tray.fill", view: .shelf))
    }
    if Defaults[.enableLyrics] {
        result.append(TabModel(label: "Lyrics", icon: "quote.bubble.fill", view: .lyrics))
    }
    if Defaults[.enableSpotifySearch] {
        result.append(TabModel(label: "Search", icon: "magnifyingglass", view: .search))
    }
    return result
}

struct TabSelectionView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Default(.enableLyrics) private var enableLyrics
    @Default(.boringShelf) private var boringShelf
    @Default(.enableSpotifySearch) private var enableSpotifySearch
    @Namespace var animation
    var body: some View {
        HStack(spacing: 0) {
            ForEach(availableTabs) { tab in
                    TabButton(label: tab.label, icon: tab.icon, selected: coordinator.currentView == tab.view) {
                        withAnimation(.smooth) {
                            coordinator.currentView = tab.view
                        }
                        // Search needs a taller notch than the other tabs.
                        vm.refreshOpenSize()
                    }
                    .frame(height: 26)
                    .foregroundStyle(tab.view == coordinator.currentView ? .white : .gray)
                    .background {
                        if tab.view == coordinator.currentView {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                        } else {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                                .hidden()
                        }
                    }
            }
        }
        .clipShape(Capsule())
        // Turning a feature off while its tab is open would otherwise leave the
        // notch showing a view you can no longer navigate away from.
        .onChange(of: enableLyrics) { _, _ in fallBackIfCurrentTabVanished() }
        .onChange(of: boringShelf) { _, _ in fallBackIfCurrentTabVanished() }
        .onChange(of: enableSpotifySearch) { _, _ in fallBackIfCurrentTabVanished() }
    }

    private func fallBackIfCurrentTabVanished() {
        guard !availableTabs.contains(where: { $0.view == coordinator.currentView }) else { return }
        withAnimation(.smooth) {
            coordinator.currentView = .home
        }
        vm.refreshOpenSize()
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
