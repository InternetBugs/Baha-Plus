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
            if !store.isPreviewMode {
                OfficialBrowser(store: store)
                    .opacity(store.browserVisible ? 1 : 0)
                    .allowsHitTesting(store.browserVisible)
                    .accessibilityHidden(!store.browserVisible)
                    .zIndex(store.browserVisible ? 1 : -1)
            }
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
        .sheet(isPresented: $store.accountPresented) {
            NavigationStack {
                AccountScreen(store: store)
                    .navigationTitle(store.text("officialAccount"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) { AccountCloseButton(store: store) }
                    }
            }
            .accountSheetAppearance()
        }
    }
    @ViewBuilder private var tabs: some View {
        #if !SKIP
        if #available(iOS 26.0, *) {
            modernTabs
        } else {
            classicTabs
        }
        #else
        classicTabs
        #endif
    }
    #if !SKIP
    @available(iOS 26.0, *)
    private var modernTabs: some View {
        TabView(selection: $store.tab) {
            Tab(store.text("explore"), systemImage: "rectangle.stack.fill", value: 0) { home }
            Tab(store.text("schedule"), systemImage: "calendar", value: 1) { schedule }
            Tab(store.text("library"), systemImage: "square.stack.fill", value: 2) { library }
            Tab(value: 3, role: .search) { search }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }
    #endif
    private var classicTabs: some View {
        TabView(selection: $store.tab) {
            home.tabItem { Label(store.text("explore"), systemImage: "rectangle.stack.fill") }.tag(0)
            schedule.tabItem { Label(store.text("schedule"), systemImage: "calendar") }.tag(1)
            library.tabItem { Label(store.text("library"), systemImage: "square.stack.fill") }.tag(2)
            search.tabItem { Label(store.text("search"), systemImage: "magnifyingglass") }.tag(3)
        }
    }
    private var home: some View {
        NavigationStack {
            HomeScreen(store: store)
                .navigationTitle(store.text("explore"))
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { AccountAvatarButton(store: store) }
                }
        }
    }
    private var schedule: some View {
        NavigationStack {
            ScheduleScreen(store: store)
                .navigationTitle(store.text("schedule"))
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { AccountAvatarButton(store: store) }
                }
        }
    }
    private var library: some View {
        NavigationStack {
            LibraryScreen(store: store)
                .navigationTitle(store.text("library"))
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { AccountAvatarButton(store: store) }
                }
        }
    }
    private var search: some View {
        NavigationStack {
            SearchScreen(store: store)
                .navigationTitle(store.text("search"))
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { AccountAvatarButton(store: store) }
                }
        }
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
