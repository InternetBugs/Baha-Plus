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
                if store.filteredLibrary.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: store.libraryFilter == "favorites" ? "bookmark" : "magnifyingglass")
                            .font(.system(size: 42, weight: .light)).foregroundStyle(.secondary)
                        Text(store.text(store.libraryFilter == "favorites" ? "noFavorites" : "noResults"))
                            .font(.headline)
                        Button(store.text(store.libraryFilter == "favorites" ? "connectAccount" : "officialSearch")) {
                            if store.libraryFilter == "favorites" { store.connectAccount() }
                            else { store.openOfficialSearch() }
                        }.buttonStyle(.borderedProminent)
                    }.frame(maxWidth: .infinity).padding(.vertical, 70)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 24) {
                            ForEach(store.filteredLibrary) { anime in
                                AnimeTile(store: store, anime: anime,
                                          poster: store.libraryFilter == "hot" || store.libraryFilter == "favorites")
                            }
                        }
                        .padding(.horizontal, 20).padding(.bottom, 20)
                    }
                }
                if !store.query.isEmpty && store.libraryFilter != "favorites" {
                    Button(store.text("officialSearch"), systemImage: "arrow.up.right") {
                        store.openOfficialSearch()
                    }.buttonStyle(.bordered)
                }
                CatalogFooter(store: store).padding(.horizontal, 20)
        }
        .padding(.top, 12)
        .searchable(text: $store.query, prompt: store.text("searchPlaceholder"))
        .onSubmit(of: .search) { store.search() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if store.busy { ProgressView() }
                else {
                    Button { store.connectAccount() } label: { Image(systemName: "person.crop.circle") }
                        .accessibilityLabel(store.text("syncAccount"))
                }
            }
        }
    }
}
#endif
