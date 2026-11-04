#if SKIP || os(iOS)
import SwiftUI
import BahaCore

struct AccountScreen: View {
    @Bindable var store: AppStore
    var body: some View {
        Form {
            Section(store.text("officialAccount")) {
                HStack(spacing: 14) {
                    Image(systemName: "person.crop.circle").font(.system(size: 44, weight: .light))
                        .foregroundStyle(Brand.accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(store.text("localProfile")).font(.headline)
                        Text(store.text(store.accountSynced ? "accountConnected" : "localOnly"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 9)
                Button(store.text(store.accountSynced ? "syncAccount" : "connectAccount"),
                       systemImage: "arrow.triangle.2.circlepath") { store.connectAccount() }
                Button {
                    store.libraryFilter = "favorites"; store.tab = 2
                } label: {
                    HStack {
                        Label(store.text("favorites"), systemImage: "bookmark")
                        Spacer()
                        Text(store.accountSynced ? "\(store.favorites.count)" : "—").foregroundStyle(.secondary)
                    }
                }
                Button(store.text("manageAccount"), systemImage: "person.crop.circle.badge.gearshape") {
                    store.connectAccount()
                }
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
            Section(store.text("history")) {
                if store.history.isEmpty {
                    Button(store.text("syncAccount"), systemImage: "icloud.and.arrow.down") {
                        store.connectAccount()
                    }
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
                                Image(systemName: "play.circle").font(.title2).foregroundStyle(Brand.accent)
                            }.padding(.vertical, 5)
                        }.buttonStyle(.plain)
                    }
                }
            }
            Section(store.text("about")) {
                HStack { Text("Baha Plus"); Spacer(); Text("0.1.0").foregroundStyle(.secondary) }
                Text(store.text("aboutText")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
#endif
