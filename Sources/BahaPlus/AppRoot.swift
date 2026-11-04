#if SKIP || os(iOS)
import SwiftUI
import BahaCore
import SkipWeb

struct AppRoot: View {
    @Bindable var store: AppStore
    var body: some View {
        ZStack {
            tabs
                .allowsHitTesting(!store.browserVisible)
                .accessibilityHidden(store.browserVisible)
            OfficialBrowser(store: store)
                .opacity(store.browserVisible ? 1 : 0)
                .allowsHitTesting(store.browserVisible)
                .accessibilityHidden(!store.browserVisible)
                .zIndex(store.browserVisible ? 1 : -1)
        }
        .sheet(item: $store.selectedAnime) { anime in
            NavigationStack {
                AnimeDetailScreen(store: store, anime: anime)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(store.text("close")) { store.selectedAnime = nil }
                        }
                    }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }
    private var tabs: some View {
        TabView(selection: $store.tab) {
            NavigationStack {
                HomeScreen(store: store)
                    .navigationTitle(store.text("explore"))
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                store.libraryFilter = "all"; store.tab = 2
                            } label: {
                                Image(systemName: "magnifyingglass")
                            }.accessibilityLabel(store.text("search"))
                        }
                    }
            }
            .tabItem { Label(store.text("explore"), systemImage: "play.rectangle.on.rectangle") }.tag(0)

            NavigationStack {
                ScheduleScreen(store: store)
                    .navigationTitle(store.text("schedule"))
            }
            .tabItem { Label(store.text("schedule"), systemImage: "calendar") }.tag(1)

            NavigationStack {
                LibraryScreen(store: store)
                    .navigationTitle(store.text("library"))
            }
            .tabItem { Label(store.text("library"), systemImage: "rectangle.stack") }.tag(2)

            NavigationStack {
                AccountScreen(store: store)
                    .navigationTitle(store.text("me"))
            }
            .tabItem { Label(store.text("me"), systemImage: "person.crop.circle") }.tag(3)
        }
        .nativeTabBehavior()
        // Deliberately no toolbar/tab-bar background overrides. UIKit and
        // SwiftUI provide iOS 26 glass, adaptive contrast and scroll-edge effects.
    }
}

struct OfficialBrowser: View {
    @Bindable var store: AppStore
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if store.browserState.isLoading {
                    ProgressView(value: store.browserState.estimatedProgress ?? 0)
                        .progressViewStyle(.linear)
                }
                if let notice = store.notice, store.browserVisible {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal).padding(.vertical, 8)
                }
                ZStack {
                    WebView(
                        configuration: store.configuration,
                        navigator: store.navigator,
                        state: .constant(store.browserState),
                        onNavigationFinished: { store.navigationFinished() },
                        onNavigationFailed: { store.navigationFailed() },
                        shouldOverrideUrlLoading: { url, isMainFrame in
                            isMainFrame && url.absoluteString != "about:blank" && !OfficialSite.allowedNavigation(url)
                        },
                        persistentWebViewID: "baha.official.session"
                    )
                    if store.browserError {
                        VStack(spacing: 20) {
                            Image(systemName: "wifi.exclamationmark").font(.largeTitle)
                            Text(store.text("playerError"))
                            Button(store.text("retry")) {
                                store.browserError = false; store.navigator.reload()
                            }.buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.background)
                    }
                }
            }
            .navigationTitle(store.browserTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { store.closeBrowser() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(store.text("close"))
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { store.navigator.goBack() } label: { Image(systemName: "chevron.backward") }
                        .disabled(!store.browserState.canGoBack).accessibilityLabel(store.text("back"))
                    if store.canRetryFavorite {
                        Button { store.retryFavorite() } label: { Image(systemName: "bookmark") }
                            .accessibilityLabel(store.text("retryFavorite"))
                    }
                    Button { store.syncAccount() } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                        .disabled(store.busy).accessibilityLabel(store.text("syncAccount"))
                }
            }
        }
    }
}
#endif
