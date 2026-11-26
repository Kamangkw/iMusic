import SwiftUI

/// 我的收藏 — albums and artists collected in iMusic on any provider, followed
/// by the NetEase account's liked albums and artists when signed in.
struct CollectionsView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case albums = "专辑"
        case artists = "歌手"

        var id: String { rawValue }
    }

    @State private var tab: Tab = .albums
    @State private var isLoading = true

    @EnvironmentObject private var account: AccountStore
    @StateObject private var collections = CollectionStore.shared

    /// NetEase albums the local collection does not already hold. Local
    /// entries win so each album appears once with its provider intact.
    private var remoteAlbums: [AlbumSummary] {
        guard account.isLoggedIn else { return [] }
        let collectedIDs = Set(collections.albums.map(\.id))
        return account.likedAlbums.filter { !collectedIDs.contains("wy|\($0.id)") }
    }

    private var remoteArtists: [ArtistSummary] {
        guard account.isLoggedIn else { return [] }
        let collectedIDs = Set(collections.artists.map(\.id))
        return account.likedArtists.filter { !collectedIDs.contains("wy|\($0.id)") }
    }

    private var showsLoadingPlaceholder: Bool {
        isLoading
            && collections.albums.isEmpty
            && collections.artists.isEmpty
            && account.likedAlbums.isEmpty
            && account.likedArtists.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { tab in
                        Text(LocalizedStringKey(tab.rawValue)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                .padding(.horizontal, Theme.Layout.contentInset)
                .padding(.top, 12)

                if showsLoadingPlaceholder {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    switch tab {
                    case .albums:
                        albumsTab
                    case .artists:
                        artistsTab
                    }
                }
                PlayerClearanceSpacer()
            }
        }
        .navigationTitle("我的收藏")
        .task {
            await account.refreshSublists()
            isLoading = false
        }
    }

    // MARK: - Albums

    @ViewBuilder
    private var albumsTab: some View {
        if collections.albums.isEmpty, remoteAlbums.isEmpty {
            EmptyStateView(icon: "square.stack", title: "还没有收藏专辑")
                .frame(minHeight: 300)
        } else {
            CardGrid {
                ForEach(collections.albums) { album in
                    NavigationLink(value: albumDestination(album)) {
                        CoverCardBody(
                            coverURL: album.coverURL?.resizedImageURL(384),
                            title: album.name,
                            subtitle: album.artistName
                        )
                    }
                    .buttonStyle(.interactiveCard)
                    .contextMenu {
                        Button(role: .destructive) {
                            collections.removeAlbum(album)
                        } label: {
                            Label("从收藏中移除", systemImage: "trash")
                        }
                    }
                }
                ForEach(remoteAlbums) { album in
                    NavigationLink(value: Destination.album(album.id)) {
                        CoverCardBody(
                            coverURL: album.picUrl?.resizedImageURL(384),
                            title: album.name,
                            subtitle: album.artistName
                        )
                    }
                    .buttonStyle(.interactiveCard)
                }
            }
            .padding(.horizontal, Theme.Layout.contentInset)
        }
    }

    private func albumDestination(_ album: CollectedAlbum) -> Destination {
        if album.source == "wy", let id = Int(album.albumID) {
            return .album(id)
        }
        return .lxAlbum(source: LXCatalogPlatform(rawValue: album.source) ?? .kw,
                        id: album.albumID.isEmpty ? nil : album.albumID,
                        name: album.name,
                        artistName: album.artistName,
                        coverURL: album.coverURL)
    }

    // MARK: - Artists

    @ViewBuilder
    private var artistsTab: some View {
        if collections.artists.isEmpty, remoteArtists.isEmpty {
            EmptyStateView(icon: "music.microphone", title: "还没有关注歌手")
                .frame(minHeight: 300)
        } else {
            CardGrid(minWidth: 140) {
                ForEach(collections.artists) { artist in
                    NavigationLink(value: artistDestination(artist)) {
                        artistCard(name: artist.name, avatarURL: artist.avatarURL)
                    }
                    .buttonStyle(.interactiveCard)
                    .contextMenu {
                        Button(role: .destructive) {
                            collections.removeArtist(artist)
                        } label: {
                            Label("从收藏中移除", systemImage: "trash")
                        }
                    }
                }
                ForEach(remoteArtists) { artist in
                    NavigationLink(value: Destination.artist(artist.id)) {
                        artistCard(name: artist.name, avatarURL: artist.picUrl)
                    }
                    .buttonStyle(.interactiveCard)
                }
            }
            .padding(.horizontal, Theme.Layout.contentInset)
        }
    }

    private func artistDestination(_ artist: CollectedArtist) -> Destination {
        if artist.source == "wy", let id = Int(artist.artistID) {
            return .artist(id)
        }
        return .lxArtist(source: LXCatalogPlatform(rawValue: artist.source) ?? .kw,
                         name: artist.name,
                         avatarURL: artist.avatarURL)
    }

    private func artistCard(name: String, avatarURL: String?) -> some View {
        VStack(spacing: 10) {
            CachedAsyncImage(url: avatarURL?.resizedImageURL(256))
                .frame(width: 128, height: 128)
                .clipShape(Circle())
            Text(name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(width: 140)
        .contentShape(Rectangle())
    }
}
