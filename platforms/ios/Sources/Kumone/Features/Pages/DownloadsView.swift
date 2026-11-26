import SwiftUI

#if os(iOS)

/// The library's 已下载 page: the tracks whose audio the download engine keeps
/// on disk, newest first. Playback already prefers those files, so this page is
/// the offline copy of the library.
struct DownloadsView: View {
    @StateObject private var downloads = DownloadManager.shared
    @EnvironmentObject private var player: PlayerService
    @State private var showDeleteAll = false

    private var records: [DownloadManager.Record] { downloads.records }
    private var tracks: [Track] { records.map(\.track) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                CollectionHeader(
                    title: String(localized: "已下载"),
                    detail: String(localized: "\(records.count) 首歌曲"),
                    playDisabled: tracks.isEmpty,
                    onPlay: { player.play(tracks: tracks, source: .none) },
                    onShuffle: { player.playShuffled(tracks: tracks, source: .none) }
                ) {
                    LinearGradient(
                        colors: [Theme.accent, Theme.accentDeep],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .overlay {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 88, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .accessibilityHidden(true)
                }

                if records.isEmpty {
                    EmptyStateView(
                        icon: "arrow.down.circle",
                        title: "还没有下载的歌曲",
                        subtitle: "在歌曲菜单中选“下载”，离线也能播放"
                    )
                    .frame(minHeight: 260)
                } else {
                    TrackListView(
                        tracks: tracks,
                        source: .none,
                        rowTrailingText: downloadQuality
                    )
                    .padding(.horizontal, Theme.Layout.contentInset - 10)
                }

                PlayerClearanceSpacer()
            }
            .padding(.top, 14)
        }
        .navigationTitle("已下载")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !records.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) {
                        showDeleteAll = true
                    } label: {
                        Label("全部删除", systemImage: "trash")
                    }
                }
            }
        }
        .confirmationDialog(
            "删除全部下载？",
            isPresented: $showDeleteAll,
            titleVisibility: .visible
        ) {
            Button("删除全部下载", role: .destructive) {
                for record in records { downloads.delete(record) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("已下载的歌曲文件会从这台设备中移除。")
        }
    }

    /// The tier the file was saved at, shown beside its duration.
    private func downloadQuality(_ track: Track) -> String? {
        guard let record = downloads.record(for: track) else { return nil }
        return AudioQuality(lxType: record.quality)?.badgeName ?? record.quality.uppercased()
    }
}

#else

/// Downloads are an iOS-only feature; the macOS build keeps the route valid so
/// `Destination` stays exhaustive.
struct DownloadsView: View {
    var body: some View {
        ContentUnavailableView("下载功能仅在 iPhone 和 iPad 上可用",
                               systemImage: "arrow.down.circle")
    }
}

#endif
