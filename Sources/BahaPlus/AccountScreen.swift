#if SKIP || os(iOS)
import SwiftUI
import BahaCore

struct AccountScreen: View {
    @Bindable var store: AppStore
    var body: some View {
        Form {
            Section {
                Button { store.connectAccount() } label: {
                    HStack(spacing: 16) {
                        Image(systemName: platformSymbol("person.crop.circle.fill"))
                            .font(.system(size: 48, weight: .light)).foregroundStyle(Color.secondary)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(store.text("localProfile")).font(.headline).foregroundStyle(Color.primary)
                            Text(store.text(store.accountSynced ? "accountConnected" : "connectAccount"))
                                .font(.subheadline).foregroundStyle(Color.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: platformSymbol("chevron.right")).font(.caption.weight(.semibold))
                            .foregroundStyle(Color.secondary.opacity(0.6))
                    }.padding(.vertical, 14)
                }.buttonStyle(.plain)
            }
            Section {
                Button { store.connectAccount() } label: {
                    menuRow(store.text("syncAccount"), symbol: "arrow.triangle.2.circlepath")
                }.buttonStyle(.plain)
                Button {
                    store.libraryFilter = "favorites"; store.tab = 2
                    store.accountPresented = false
                } label: {
                    menuRow(store.text("favorites"), symbol: "bookmark",
                            value: store.accountSynced ? "\(store.favorites.count)" : nil)
                }.buttonStyle(.plain)
                NavigationLink {
                    AccountHistoryScreen(store: store)
                } label: {
                    Label(store.text("history"), systemImage: platformSymbol("clock"))
                        .foregroundStyle(Color.primary).padding(.vertical, 7)
                }
                Button { store.connectAccount() } label: {
                    menuRow(store.text("manageAccount"), symbol: "person.crop.circle")
                }.buttonStyle(.plain)
            }
            Section {
                HStack(spacing: 12) {
                    quickAction(store.text("favorites"), symbol: "bookmark") {
                        store.libraryFilter = "favorites"; store.tab = 2; store.accountPresented = false
                    }
                    quickAction(store.text("syncAccount"), symbol: "arrow.triangle.2.circlepath") {
                        store.connectAccount()
                    }
                    quickAction(store.text("schedule"), symbol: "calendar") {
                        store.tab = 1; store.accountPresented = false
                    }
                }.padding(.vertical, 8)
            }
            Section(store.text("preferences")) {
                Picker(store.text("language"), selection: $store.language) {
                    Text("简体中文").tag("zh-Hans")
                    Text("繁體中文").tag("zh-Hant")
                }
                Picker(store.text("appearance"), selection: $store.appearance) {
                    Text(store.text("system")).tag("system")
                    Text(store.text("light")).tag("light")
                    Text(store.text("dark")).tag("dark")
                }
            }
            Section {
                HStack { Text("Baha Plus"); Spacer(); Text("0.1.0").foregroundStyle(.secondary) }
            } header: {
                Text(store.text("about"))
            } footer: {
                Text(store.text("aboutText"))
            }
        }
    }
    private func menuRow(_ title: String, symbol: String, value: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: platformSymbol(symbol)).foregroundStyle(Brand.accent).frame(width: 24)
            Text(title).foregroundStyle(Color.primary)
            Spacer()
            if let value { Text(value).foregroundStyle(Color.secondary) }
            Image(systemName: platformSymbol("chevron.right")).font(.caption.weight(.semibold))
                .foregroundStyle(Color.secondary.opacity(0.6))
        }.padding(.vertical, 7)
    }
    private func quickAction(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 9) {
                Image(systemName: platformSymbol(symbol)).font(.title3)
                Text(title).font(.caption).lineLimit(1)
            }
            .foregroundStyle(Brand.accent)
            .frame(maxWidth: .infinity, minHeight: 66)
        }.buttonStyle(.plain)
    }
}

struct AccountHistoryScreen: View {
    @Bindable var store: AppStore
    var body: some View {
        List {
            if store.history.isEmpty {
                Section {
                    Button(store.text("syncAccount"), systemImage: platformSymbol("icloud.and.arrow.down")) {
                        store.connectAccount()
                    }
                } footer: { Text(store.text("historyHint")) }
            } else {
                ForEach(store.history) { entry in
                    Button { store.continueWatching(entry) } label: {
                        HStack(spacing: 13) {
                            RemoteArtwork(url: entry.anime.posterURL).frame(width: 52, height: 70)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.anime.title).font(.subheadline.weight(.medium)).lineLimit(2)
                                Text("EP \(entry.episodeLabel)").font(.caption).foregroundStyle(.secondary)
                                if let progress = entry.progress { ProgressView(value: progress) }
                                if let label = entry.progressLabel {
                                    Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: platformSymbol("play.circle")).font(.title2).foregroundStyle(Brand.accent)
                        }.padding(.vertical, 5)
                    }.buttonStyle(.plain)
                }
            }
        }.navigationTitle(store.text("history"))
    }
}
#endif
