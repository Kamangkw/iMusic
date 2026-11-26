import Combine
import Foundation

/// An album the user collected inside iMusic. `source` is the LX catalogue
/// identifier (`wy`, `kw`, `kg`, `tx`) so albums from every provider share
/// one list without requiring a NetEase account.
struct CollectedAlbum: Codable, Identifiable, Hashable {
    let source: String
    let albumID: String
    let name: String
    let artistName: String
    let coverURL: String?

    /// Catalogue entries without a provider ID fall back to the album name.
    var id: String { "\(source)|\(albumID.isEmpty ? name : albumID)" }
}

struct CollectedArtist: Codable, Identifiable, Hashable {
    let source: String
    let artistID: String
    let name: String
    let avatarURL: String?

    /// Catalogue entries without a provider ID fall back to the artist name.
    var id: String { "\(source)|\(artistID.isEmpty ? name : artistID)" }
}

/// Local album and artist collection shared by every provider page. NetEase
/// account favourites stay in `AccountStore`; this store keeps what the user
/// collected in the app regardless of login state.
@MainActor
final class CollectionStore: ObservableObject {
    static let shared = CollectionStore()

    @Published private(set) var albums: [CollectedAlbum]
    @Published private(set) var artists: [CollectedArtist]

    /// Both lists live in one file so saving albums cannot drop artists.
    private struct StoredCollections: Codable {
        var albums: [CollectedAlbum]
        var artists: [CollectedArtist]
    }

    private static var storageURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Moumusic", isDirectory: true)
            .appendingPathComponent("collections.json")
    }

    init() {
        albums = []
        artists = []
        try? FileManager.default.createDirectory(at: Self.storageURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        load()
    }

    func isAlbumCollected(_ album: CollectedAlbum) -> Bool {
        albums.contains { $0.id == album.id }
    }

    func toggleAlbum(_ album: CollectedAlbum) {
        if isAlbumCollected(album) {
            removeAlbum(album)
        } else {
            albums.insert(album, at: 0)
            save()
        }
    }

    func isArtistCollected(_ artist: CollectedArtist) -> Bool {
        artists.contains { $0.id == artist.id }
    }

    func toggleArtist(_ artist: CollectedArtist) {
        if isArtistCollected(artist) {
            removeArtist(artist)
        } else {
            artists.insert(artist, at: 0)
            save()
        }
    }

    func removeAlbum(_ album: CollectedAlbum) {
        let previousCount = albums.count
        albums.removeAll { $0.id == album.id }
        if albums.count != previousCount { save() }
    }

    func removeArtist(_ artist: CollectedArtist) {
        let previousCount = artists.count
        artists.removeAll { $0.id == artist.id }
        if artists.count != previousCount { save() }
    }

    /// A missing or unreadable file leaves both lists empty instead of
    /// blocking app startup.
    private func load() {
        guard let data = try? Data(contentsOf: Self.storageURL),
              let stored = try? JSONDecoder().decode(StoredCollections.self, from: data) else {
            return
        }
        albums = stored.albums
        artists = stored.artists
    }

    private func save() {
        let stored = StoredCollections(albums: albums, artists: artists)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: Self.storageURL, options: .atomic)
    }
}

extension CollectionStore {
    /// Detail pages confirm the new state with the shared toast so every
    /// provider reports the same message.
    func toggleAlbumWithToast(_ album: CollectedAlbum) {
        let wasCollected = isAlbumCollected(album)
        toggleAlbum(album)
        ToastCenter.shared.show(wasCollected
                                ? String(localized: "已从收藏中移除")
                                : String(localized: "已加入我的收藏"))
    }

    func toggleArtistWithToast(_ artist: CollectedArtist) {
        let wasCollected = isArtistCollected(artist)
        toggleArtist(artist)
        ToastCenter.shared.show(wasCollected
                                ? String(localized: "已从收藏中移除")
                                : String(localized: "已加入我的收藏"))
    }
}
