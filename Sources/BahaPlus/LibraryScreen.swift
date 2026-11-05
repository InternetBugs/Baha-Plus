#if SKIP || os(iOS)
import SwiftUI
import BahaCore

struct LibraryScreen: View {
    @Bindable var store: AppStore
    private let columns = [GridItem(.adaptive(minimum: 146), spacing: 16)]
    var body: some View {
        VStack(spacing: 18) {
                Picker(store.text("library"), selection: $store.libraryFilter) {
                    Text(store.text("all")).tag("all")
                    Text(store.text("seasonFilter")).tag("season")
                    Text(store.text("hotFilter")).tag("hot")
                    Text(store.text("favorites")).tag("favorites")
                }.pickerStyle(.segmented).padding(.horizontal, 20)
                if store.libraryItems.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: platformSymbol(store.libraryFilter == "favorites" ? "bookmark" : "square.stack"))
                            .font(.system(size: 42, weight: .light)).foregroundStyle(.secondary)
                        Text(store.text(store.libraryFilter == "favorites" ? "noFavorites" : "noResults"))
                            .font(.headline)
                        Button(store.text(store.libraryFilter == "favorites" ? "connectAccount" : "officialSearch")) {
                            if store.libraryFilter == "favorites" { store.connectAccount() }
                            else { store.tab = 3 }
                        }.buttonStyle(.borderedProminent)
                    }.frame(maxWidth: .infinity).padding(.vertical, 70)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 24) {
                            ForEach(store.libraryItems) { anime in
                                AnimeTile(store: store, anime: anime,
                                          poster: store.libraryFilter == "hot" || store.libraryFilter == "favorites")
                            }
                        }
                        .padding(.horizontal, 20).padding(.bottom, 20)
                    }
                }
                CatalogFooter(store: store).padding(.horizontal, 20)
        }
        .padding(.top, 12)
    }
}
#endif
