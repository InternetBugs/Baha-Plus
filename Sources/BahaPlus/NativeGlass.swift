#if SKIP || os(iOS)
import SwiftUI
import BahaCore

enum Brand {
    static let accent = Color.blue
    static let green = Color(red: 0.29, green: 0.47, blue: 0.38)
}

/// Keep native SF Symbols on Apple platforms and use supported equivalents in
/// SkipUI's Android icon set instead of rendering missing-symbol warnings.
func platformSymbol(_ name: String) -> String {
    #if SKIP
    switch name {
    case "rectangle.stack.fill": return "safari"
    case "square.stack", "square.stack.fill": return "list.bullet"
    case "film", "play.circle", "play.circle.fill": return "play"
    case "arrow.clockwise", "arrow.triangle.2.circlepath", "clock": return "arrow.clockwise.circle"
    case "chevron.backward": return "chevron.left"
    case "arrow.up.right": return "arrow.forward"
    case "icloud.and.arrow.down": return "square.and.arrow.down"
    case "wifi.exclamationmark": return "exclamationmark.triangle"
    case "cup.and.saucer": return "info.circle"
    case "bookmark.slash": return "bookmark"
    default: return name
    }
    #else
    return name
    #endif
}

struct AccountAvatarButton: View {
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: platformSymbol("person.crop.circle.fill"))
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Color.secondary)
                .frame(width: 42, height: 42)
                .background(Color.secondary.opacity(0.06), in: Circle())
                .overlay(Circle().strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier("account-button")
    }
}

struct AccountCloseButton: View {
    @Bindable var store: AppStore
    var body: some View {
        #if !SKIP
        if #available(iOS 26.0, *) {
            button.glassEffect(.regular.interactive(), in: .circle)
        } else {
            button.background(.thinMaterial, in: Circle())
        }
        #else
        button.background(
            LinearGradient(colors: [Color.white.opacity(0.5), Color.secondary.opacity(0.12)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: Circle()
        )
        #endif
    }
    private var button: some View {
        Button { store.accountPresented = false } label: {
            Image(systemName: platformSymbol("xmark")).font(.system(size: 20, weight: .regular))
                .foregroundStyle(Color.primary).frame(width: 44, height: 44)
        }.buttonStyle(.plain).accessibilityLabel(store.text("close"))
    }
}

struct StoreActionPill: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.accent)
                .padding(.horizontal, 20).frame(minHeight: 36)
                .background(Color.secondary.opacity(0.10), in: Capsule())
        }.buttonStyle(.plain)
    }
}

extension View {
    @ViewBuilder internal func appStoreHeader(_ title: String, accountLabel: String,
                                             onAccount: @escaping () -> Void) -> some View {
        #if !SKIP
        if #available(iOS 26.0, *) {
            self.navigationTitle(title)
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                ToolbarItem(placement: .largeTitle) {
                    HStack(alignment: .center) {
                        Text(title).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                        Spacer()
                        AccountAvatarButton(label: accountLabel, action: onAccount)
                    }.frame(maxWidth: .infinity)
                }
            }
        } else {
            self.navigationTitle(title)
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    AccountAvatarButton(label: accountLabel, action: onAccount)
                }
            }
        }
        #else
        self.navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Text(title).font(.largeTitle.bold())
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityAddTraits(.isHeader)
            }
            ToolbarItem(placement: .topBarTrailing) {
                AccountAvatarButton(label: accountLabel, action: onAccount)
            }
        }
        #endif
    }

    @ViewBuilder internal func accountSheetAppearance() -> some View {
        #if !SKIP
        self.presentationDetents([.large])
            .presentationDragIndicator(.hidden)
            .presentationCornerRadius(36)
        #else
        self
        #endif
    }
}

/// Apple materials are applied only to the navigation/control layer.
/// The iOS 26 path uses real SwiftUI glass optics without custom white fills.
struct PlaybackActions: View {
    @Bindable var store: AppStore
    let anime: Anime
    #if !SKIP
    @Namespace private var controls
    #endif

    var body: some View {
        #if !SKIP
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 14) {
                HStack(spacing: 14) {
                    Button { store.play(anime) } label: {
                        Label(store.text(anime.latestVideoId == nil ? "play" : "playLatest"), systemImage: platformSymbol("play.fill"))
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 22).frame(height: 50)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .glassEffect(.clear.interactive(), in: .capsule)
                    .glassEffectID("play", in: controls)

                    Button { store.toggleFavorite(anime) } label: {
                        Image(systemName: store.isFavorite(anime) ? "bookmark.fill" : "bookmark")
                            .font(.title3).frame(width: 50, height: 50)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .glassEffect(.clear.interactive(), in: .circle)
                    .glassEffectID("favorite", in: controls)
                    .accessibilityLabel(store.text(store.isFavorite(anime) ? "unsave" : "save"))
                }
            }
        } else {
            fallback
        }
        #else
        fallback
        #endif
    }
    private var fallback: some View {
        HStack(spacing: 14) {
            Button { store.play(anime) } label: {
                Label(store.text(anime.latestVideoId == nil ? "play" : "playLatest"), systemImage: platformSymbol("play.fill"))
                    .font(.subheadline.weight(.semibold)).padding(.horizontal, 20).frame(height: 50)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(controlBackground, in: Capsule())
            Button { store.toggleFavorite(anime) } label: {
                Image(systemName: store.isFavorite(anime) ? "bookmark.fill" : "bookmark")
                    .frame(width: 50, height: 50)
            }
            .buttonStyle(.plain).foregroundStyle(.white)
            .background(controlBackground, in: Circle())
            .accessibilityLabel(store.text(store.isFavorite(anime) ? "unsave" : "save"))
        }
    }
    private var controlBackground: some ShapeStyle {
        #if SKIP
        LinearGradient(colors: [Color.white.opacity(0.35), Color.white.opacity(0.15)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
        #else
        Material.ultraThin
        #endif
    }
}

extension View {
    @ViewBuilder func nativeTabBehavior() -> some View {
        #if !SKIP
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

struct RemoteArtwork: View {
    let url: URL?
    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                Rectangle().fill(Color.secondary.opacity(0.10))
                Image(systemName: platformSymbol("film")).font(.largeTitle).foregroundStyle(Color.secondary.opacity(0.6))
            }
        }
        .clipped()
    }
}

struct CatalogFooter: View {
    @Bindable var store: AppStore
    var body: some View {
        if !store.catalog.items.isEmpty {
            HStack {
                Text(store.text(store.catalogSource == "live" ? "dataLive" :
                                store.catalogSource == "snapshot" ? "dataSnapshot" : "dataCached"))
                Text(String(store.catalog.fetchedAt.prefix(10)))
                Spacer()
                if store.busy { ProgressView() }
                else {
                    Button { store.refreshCatalog() } label: { Image(systemName: platformSymbol("arrow.clockwise")) }
                        .accessibilityLabel(store.text("refresh"))
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
            .padding(.vertical, 20)
        }
    }
}
#endif
