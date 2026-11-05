#if SKIP || os(iOS)
import SwiftUI
import BahaCore

struct HomeScreen: View {
    @Bindable var store: AppStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if let anime = store.seasonal.first {
                    hero(anime)
                }
                if !store.history.isEmpty {
                    sectionHeading(store.text("history")) { store.accountPresented = true }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(Array(store.history.prefix(8))) { entry in
                                ContinueCard(store: store, entry: entry)
                            }
                        }
                    }
                }
                if let anime = store.popular.first {
                    compactFeature(anime)
                }
                sectionHeading(store.text("seasonal")) {
                    store.libraryFilter = "season"; store.tab = 2
                }
                // A small fixed two-column section avoids nesting an Android
                // Compose lazy grid inside the home page's vertical scroll.
                VStack(spacing: 24) {
                    ForEach(0..<((min(store.seasonal.count, 8) + 1) / 2), id: \.self) { row in
                        HStack(alignment: .top, spacing: 16) {
                            AnimeTile(store: store, anime: store.seasonal[row * 2], poster: false)
                                .frame(maxWidth: .infinity)
                            if row * 2 + 1 < min(store.seasonal.count, 8) {
                                AnimeTile(store: store, anime: store.seasonal[row * 2 + 1], poster: false)
                                    .frame(maxWidth: .infinity)
                            } else {
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
                sectionHeading(store.text("popular")) {
                    store.libraryFilter = "hot"; store.tab = 2
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(Array(store.popular.prefix(12))) { anime in
                            AnimeTile(store: store, anime: anime, poster: true).frame(width: 138)
                        }
                    }
                }
                CatalogFooter(store: store)
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24)
        }
        .refreshable { store.refreshCatalog() }
    }
    private func sectionHeading(_ title: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(.title2.bold())
            Spacer()
            Button(action: action) { Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)) }
                .accessibilityLabel(store.text("viewAll"))
        }
    }
    private func hero(_ anime: Anime) -> some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { geometry in
                RemoteArtwork(url: anime.coverURL)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
            // Clear glass sits on rich media. This dimming layer preserves
            // contrast, including with bright artwork, per Apple's Materials HIG.
            Color.black.opacity(0.20)
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 12) {
                Spacer(minLength: 240)
                Text(store.text("featured"))
                    .font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.75))
                Button { store.openDetail(anime) } label: {
                    Text(anime.title)
                        .font(.system(size: 28, weight: .bold))
                        .multilineTextAlignment(.leading).foregroundStyle(.white)
                }.buttonStyle(.plain)
                HStack(spacing: 12) {
                    RemoteArtwork(url: anime.posterURL)
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(anime.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text([anime.episodeLabel, anime.updateTime].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer(minLength: 0)
                    Button { store.play(anime) } label: {
                        Text(store.text("watch")).font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 20).frame(minHeight: 36)
                            .background(Color.white.opacity(0.20), in: Capsule())
                    }.buttonStyle(.plain)
                }
                .foregroundStyle(.white)
                .padding(.top, 8)
            }.padding(24)
        }
        .frame(minHeight: 440)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: Color.black.opacity(0.10), radius: 14, x: 0, y: 5)
    }
    private func compactFeature(_ anime: Anime) -> some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { geometry in
                RemoteArtwork(url: anime.coverURL)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
            HStack(spacing: 14) {
                Button { store.openDetail(anime) } label: {
                    Text(anime.title).font(.headline).foregroundStyle(.white)
                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
                Button { store.play(anime) } label: {
                    Text(store.text("watch")).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 20).frame(minHeight: 36)
                        .background(Color.white.opacity(0.25), in: Capsule())
                }.buttonStyle(.plain)
            }.padding(20)
        }
        .frame(height: 165)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct AnimeTile: View {
    @Bindable var store: AppStore
    let anime: Anime
    var poster = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { store.openDetail(anime) } label: {
                GeometryReader { geometry in
                    RemoteArtwork(url: poster ? anime.posterURL : anime.coverURL)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                .aspectRatio(poster ? 0.72 : 1.65, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }.buttonStyle(.plain)
            Button { store.openDetail(anime) } label: {
                Text(anime.title).font(.subheadline.weight(.medium)).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
            HStack(spacing: 5) {
                Text(anime.episodeLabel ?? anime.year ?? "").lineLimit(1)
                Spacer(minLength: 0)
                if store.isFavorite(anime) {
                    Image(systemName: "bookmark.fill").foregroundStyle(Brand.accent)
                }
            }.font(.caption2).foregroundStyle(.secondary)
        }
        .contextMenu {
            Button { store.toggleFavorite(anime) } label: {
                Label(store.text(store.isFavorite(anime) ? "unsave" : "save"),
                      systemImage: store.isFavorite(anime) ? "bookmark.slash" : "bookmark")
            }
            Button { store.play(anime) } label: { Label(store.text("play"), systemImage: "play") }
        }
    }
}

struct ContinueCard: View {
    @Bindable var store: AppStore
    let entry: WatchEntry
    var body: some View {
        Button { store.continueWatching(entry) } label: {
            HStack(spacing: 13) {
                RemoteArtwork(url: entry.anime.posterURL).frame(width: 66, height: 82)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.anime.title).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text("EP \(entry.episodeLabel)").font(.caption).foregroundStyle(.secondary)
                    if let progress = entry.progress { ProgressView(value: progress) }
                    if let label = entry.progressLabel { Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
                Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(Brand.accent)
            }
            .padding(14).frame(width: 315)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 22))
        }.buttonStyle(.plain)
    }
}
#endif
