#if SKIP || os(iOS)
import SwiftUI
import BahaCore

struct SearchScreen: View {
    @Bindable var store: AppStore
    var body: some View {
        #if SKIP
        content.searchable(text: $store.query, prompt: store.text("searchPlaceholder"))
            .onSubmit(of: .search) { store.search() }
        #else
        content.searchable(text: $store.query,
                           placement: .navigationBarDrawer(displayMode: .always),
                           prompt: store.text("searchPlaceholder"))
            .onSubmit(of: .search) { store.search() }
        #endif
    }
    @ViewBuilder private var content: some View {
        if store.query.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    sectionTitle(store.text("recommended"))
                    VStack(spacing: 0) {
                        ForEach(Array(store.popular.prefix(3))) { anime in
                            resultRow(anime)
                            Divider().padding(.leading, 76)
                        }
                    }
                    sectionTitle(store.text("browse"))
                    VStack(spacing: 12) {
                        HStack(spacing: 12) {
                            category(store.text("seasonal"), filter: "season",
                                     anime: store.seasonal.first, color: Color.blue)
                            category(store.text("popular"), filter: "hot",
                                     anime: store.popular.first, color: Color.orange)
                        }
                        HStack(spacing: 12) {
                            category(store.text("allAnime"), filter: "all",
                                     anime: store.catalog.items.last, color: Color.purple)
                            category(store.text("favorites"), filter: "favorites",
                                     anime: store.favorites.first, color: Color.green)
                        }
                    }
                    CatalogFooter(store: store)
                }.padding(.horizontal, 20).padding(.top, 18)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if store.searchMatches.isEmpty {
                        Text(store.text("noResults")).font(.headline)
                            .frame(maxWidth: .infinity).padding(.vertical, 50)
                    } else {
                        ForEach(store.searchMatches) { anime in
                            resultRow(anime)
                            Divider().padding(.leading, 76)
                        }
                    }
                    Button(store.text("officialSearch"), systemImage: platformSymbol("arrow.up.right")) {
                        store.openOfficialSearch()
                    }.buttonStyle(.bordered).padding(.vertical, 24)
                    CatalogFooter(store: store)
                }.padding(.horizontal, 20)
            }
        }
    }
    private func sectionTitle(_ title: String) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.title3.weight(.semibold))
            Image(systemName: platformSymbol("chevron.right")).font(.caption.weight(.semibold))
                .foregroundStyle(Color.secondary)
        }
    }
    private func resultRow(_ anime: Anime) -> some View {
        HStack(spacing: 14) {
            Button { store.openDetail(anime) } label: {
                HStack(spacing: 14) {
                    RemoteArtwork(url: anime.posterURL).frame(width: 62, height: 62)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(anime.title).font(.body).foregroundStyle(Color.primary).lineLimit(2)
                        Text(anime.episodeLabel ?? anime.year ?? "").font(.subheadline)
                            .foregroundStyle(Color.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.buttonStyle(.plain)
            StoreActionPill(title: store.text("watch")) { store.play(anime) }
        }.padding(.vertical, 13)
    }
    private func category(_ title: String, filter: String, anime: Anime?, color: Color) -> some View {
        Button {
            store.libraryFilter = filter; store.tab = 2
        } label: {
            ZStack(alignment: .bottomLeading) {
                color.opacity(0.85)
                if let anime {
                    GeometryReader { geometry in
                        RemoteArtwork(url: anime.coverURL)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                } else {
                    Image(systemName: platformSymbol("bookmark.fill")).font(.system(size: 42))
                        .foregroundStyle(Color.white.opacity(0.4))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(18)
                }
                LinearGradient(colors: [.clear, color.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                Text(title).font(.headline).foregroundStyle(Color.white).padding(16)
            }
            .frame(maxWidth: .infinity).frame(height: 116)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }.buttonStyle(.plain)
    }
}
#endif
