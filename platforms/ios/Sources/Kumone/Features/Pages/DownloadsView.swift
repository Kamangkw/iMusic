import SwiftUI

#if os(iOS)

/// The library's 已下载 page: the tracks whose audio the download engine keeps
/// on disk, newest first. Playback already prefers those files, so this page is
/// the offline copy of the library.
struct DownloadsView: View {
    @StateObject private var downloads = DownloadManager.shared
    @EnvironmentObject private var player: PlayerService
    @State private var showDeleteAll = false
    /// File sizes keyed by record id. Read once per record list change so the
    /// row text never has to touch the disk while the view redraws.
    @State private var sizes: [String: Int64] = [:]

    private var records: [DownloadManager.Record] { downloads.records }
    private var tracks: [Track] { records.map(\.track) }
    private var recordIDs: [String] { records.map(\.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                CollectionHeader(
                    title: String(localized: "已下载"),
                    detail: headerDetail,
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
                        rowTrailingText: rowTrailingText,
                        showsFavoriteBadge: true
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
        .task(id: recordIDs) {
            loadSizes()
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

    /// "12 首歌曲 · 256 MB"; the size is left out until the files are measured.
    private var headerDetail: String {
        let countText = String(localized: "\(records.count) 首歌曲")
        let total = sizes.values.reduce(Int64(0), +)
        guard total > 0 else { return countText }
        let sizeText = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        return "\(countText) · \(sizeText)"
    }

    /// The tier the file was saved at and its size, shown beside the duration.
    private func rowTrailingText(_ track: Track) -> String? {
        guard let record = downloads.record(for: track) else { return nil }
        let quality = AudioQuality(lxType: record.quality)?.badgeName ?? record.quality.uppercased()
        guard let bytes = sizes[record.id] else { return quality }
        return "\(quality) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
    }

    /// A saved file can disappear between the manifest load and this read, so
    /// a missing entry simply keeps the row without a size.
    private func loadSizes() {
        var measured: [String: Int64] = [:]
        for record in records {
            guard let attributes = try? FileManager.default.attributesOfItem(
                      atPath: record.fileURL.path),
                  let size = (attributes[.size] as? NSNumber)?.int64Value else { continue }
            measured[record.id] = size
        }
        sizes = measured
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
