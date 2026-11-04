#if SKIP || os(iOS)
import SwiftUI
import BahaCore

struct AnimeDetailScreen: View {
    @Bindable var store: AppStore
    let anime: Anime
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ZStack(alignment: .bottomLeading) {
                    GeometryReader { geometry in
                        RemoteArtwork(url: anime.coverURL)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                    Color.black.opacity(0.35)
                    LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 16) {
                        Text(anime.title).font(.title.bold()).foregroundStyle(.white)
                        Text([anime.year, anime.episodeLabel].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.white.opacity(0.8))
                        PlaybackActions(store: store, anime: anime)
                    }.padding(24)
                }
                .frame(height: 350)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                if store.detailLoading {
                    ProgressView().frame(maxWidth: .infinity).padding(20)
                } else if store.detailFailed {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(store.text("detailUnavailable")).font(.subheadline).foregroundStyle(.secondary)
                        Button(store.text("retry")) { store.openDetail(anime) }
                    }
                }
                if let detail = store.detail {
                    if !detail.episodes.isEmpty {
                        Text(store.text("episodes")).font(.title2.bold())
                        VStack(spacing: 12) {
                            ForEach(0..<((detail.episodes.count + 4) / 5), id: \.self) { row in
                                HStack(spacing: 10) {
                                    ForEach(0..<5, id: \.self) { column in
                                        let index = row * 5 + column
                                        if index < detail.episodes.count {
                                            let episode = detail.episodes[index]
                                            Button { store.play(anime, episode: episode) } label: {
                                                Text(episode.label).font(.subheadline.weight(.medium))
                                                    .frame(maxWidth: .infinity, minHeight: 46)
                                            }.buttonStyle(.bordered)
                                        } else {
                                            Color.clear.frame(maxWidth: .infinity, minHeight: 46)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if !detail.description.isEmpty {
                        Text(store.text("synopsis")).font(.title2.bold())
                        Text(detail.description).font(.subheadline).foregroundStyle(.secondary).lineSpacing(6)
                    }
                    if !detail.metadata.isEmpty {
                        Text(store.text("metadata")).font(.title2.bold())
                        ForEach(Array(detail.metadata.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: 20) {
                                Text(item.label).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                                Text(item.value).frame(maxWidth: .infinity, alignment: .leading)
                            }.font(.subheadline)
                        }
                    }
                }
                Button(store.text("officialDetails"), systemImage: "arrow.up.right") { store.play(anime) }
                    .buttonStyle(.bordered)
            }.padding(20)
        }
        .navigationTitle(store.text("details"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
