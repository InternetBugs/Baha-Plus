#if SKIP || os(iOS)
import SwiftUI
import BahaCore

struct HomeScreen: View {
    @Bindable var store: AppStore
    @State private var featured = 0
    private var heroes: [Anime] { Array(store.seasonal.prefix(3)) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if !heroes.isEmpty {
                    hero(heroes[min(featured, heroes.count - 1)])
                }
                if !store.history.isEmpty {
                    sectionHeading(store.text("history")) { store.tab = 3 }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(Array(store.history.prefix(8))) { entry in
                                ContinueCard(store: store, entry: entry)
                            }
                        }
                    }
                } else if !store.accountSynced {
                    Button { store.connectAccount() } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.badge.checkmark").font(.title2)
                            Text(store.text("connectAccount")).font(.subheadline.weight(.medium))
                            Spacer()
                            Image(systemName: "chevron.forward").font(.caption.weight(.semibold))
                        }
                        .padding(18).frame(maxWidth: .infinity)
                        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 22))
                    }.buttonStyle(.plain)
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
            Button(action: action) { Image(systemName: "arrow.right").font(.subheadline) }
                .accessibilityLabel(store.text("viewAll"))
        }
    }
    private func hero(_ anime: Anime) -> some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { geometry in
                RemoteArtwork(url: anime.coverURL)
                    .frame(width: geometry.size.width, height: 420)
            }
            // Clear glass sits on rich media. This dimming layer preserves
            // contrast, including with bright artwork, per Apple's Materials HIG.
            Color.black.opacity(0.35)
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 16) {
                Spacer()
                Text(store.text("featured"))
                    .font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
                Button { store.openDetail(anime) } label: {
                    Text(anime.title.replacingOccurrences(of: "，", with: "，\n"))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.leading).foregroundStyle(.white)
                }.buttonStyle(.plain)
                Text([anime.episodeLabel, anime.updateTime].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.white.opacity(0.8))
                PlaybackActions(store: store, anime: anime)
                HStack(spacing: 8) {
                    ForEach(Array(heroes.enumerated()), id: \.offset) { index, value in
                        Button { featured = index } label: {
                            Capsule().fill(Color.white.opacity(index == featured ? 1 : 0.35))
                                .frame(width: index == featured ? 22 : 5, height: 5)
                                .padding(.vertical, 12)
                        }.buttonStyle(.plain).accessibilityLabel(value.title)
                    }
                }
            }.padding(24)
        }
        .frame(height: 420)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
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
