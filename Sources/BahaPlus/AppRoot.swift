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
                    // A transparent, full-screen AndroidView still occludes
                    // Compose accessibility nodes underneath it. Keep this
                    // same persistent session mounted in a tiny clipped host
                    // while native pages are visible.
                    #if SKIP
                    .frame(width: store.browserVisible ? nil : 1.0,
                           height: store.browserVisible ? nil : 1.0)
                    .clipped()
                    #endif
                    .opacity(store.browserVisible ? 1.0 : 0.0)
                    .allowsHitTesting(store.browserVisible)
                    .accessibilityHidden(!store.browserVisible)
                    .zIndex(store.browserVisible ? 1.0 : -1.0)
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
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        #if !SKIP
                        if #available(iOS 26.0, *) {
                            ToolbarItem(placement: .topBarLeading) {
                                Text(store.text("officialAccount")).font(.headline)
                                    .fixedSize(horizontal: true, vertical: false)
                            }.sharedBackgroundVisibility(.hidden)
                            ToolbarItem(placement: .topBarTrailing) {
                                AccountCloseButton(store: store)
                            }.sharedBackgroundVisibility(.hidden)
                        } else {
                            ToolbarItem(placement: .topBarLeading) {
                                Text(store.text("officialAccount")).font(.headline)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            ToolbarItem(placement: .topBarTrailing) { AccountCloseButton(store: store) }
                        }
                        #else
                        ToolbarItem(placement: .topBarLeading) {
                            Text(store.text("officialAccount")).font(.headline)
                        }
                        ToolbarItem(placement: .topBarTrailing) { AccountCloseButton(store: store) }
                        #endif
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
        AndroidGlassTabs(store: store, content: AnyView(classicTabs))
        #endif
    }
    #if !SKIP
    @available(iOS 26.0, *)
    private var modernTabs: some View {
        TabView(selection: $store.tab) {
            Tab(store.text("explore"), systemImage: platformSymbol("rectangle.stack.fill"), value: 0) { home }
            Tab(store.text("schedule"), systemImage: platformSymbol("calendar"), value: 1) { schedule }
            Tab(store.text("library"), systemImage: platformSymbol("square.stack.fill"), value: 2) { library }
            Tab(store.text("search"), systemImage: platformSymbol("magnifyingglass"), value: 3) { search }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }
    #endif
    private var classicTabs: some View {
        TabView(selection: $store.tab) {
            home.hideAndroidSystemTabBar()
                .tabItem { Label(store.text("explore"), systemImage: platformSymbol("rectangle.stack.fill")) }.tag(0)
            schedule.hideAndroidSystemTabBar()
                .tabItem { Label(store.text("schedule"), systemImage: platformSymbol("calendar")) }.tag(1)
            library.hideAndroidSystemTabBar()
                .tabItem { Label(store.text("library"), systemImage: platformSymbol("square.stack.fill")) }.tag(2)
            search.hideAndroidSystemTabBar()
                .tabItem { Label(store.text("search"), systemImage: platformSymbol("magnifyingglass")) }.tag(3)
        }
    }
    private var home: some View {
        NavigationStack {
            HomeScreen(store: store)
                .appStoreHeader(store.text("explore"), accountLabel: store.text("me")) {
                    store.accountPresented = true
                }
        }
    }
    private var schedule: some View {
        NavigationStack {
            ScheduleScreen(store: store)
                .appStoreHeader(store.text("schedule"), accountLabel: store.text("me")) {
                    store.accountPresented = true
                }
        }
    }
    private var library: some View {
        NavigationStack {
            LibraryScreen(store: store)
                .appStoreHeader(store.text("library"), accountLabel: store.text("me")) {
                    store.accountPresented = true
                }
        }
    }
    private var search: some View {
        NavigationStack {
            SearchScreen(store: store)
                .appStoreHeader(store.text("search"), accountLabel: store.text("me")) {
                    store.accountPresented = true
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
                    ProgressView(value: store.browserState.estimatedProgress ?? 0.0)
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
                        onNavigationFailed: {
                            #if !SKIP
                            store.navigationFailed()
                            #endif
                            // SkipWeb's Android callback also reports subresource
                            // failures. Keep the official document visible; main
                            // document failures retain WebView's own error page.
                            // Data adapters have their own failure/deadline path.
                        },
                        shouldOverrideUrlLoading: { url, isMainFrame in
                            isMainFrame && url.absoluteString != "about:blank" && !OfficialSite.allowedNavigation(url)
                        },
                        persistentWebViewID: "baha.official.session"
                    )
                    if store.browserError {
                        VStack(spacing: 20) {
                            Image(systemName: platformSymbol("wifi.exclamationmark")).font(.largeTitle)
                            Text(store.text("playerError"))
                            Button(store.text("retry")) { store.reloadBrowser() }
                                .buttonStyle(.borderedProminent)
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
                    Button { store.closeBrowser() } label: { Image(systemName: platformSymbol("xmark")) }
                        .accessibilityLabel(store.text("close"))
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { store.navigator.goBack() } label: { Image(systemName: platformSymbol("chevron.backward")) }
                        .disabled(!store.browserState.canGoBack).accessibilityLabel(store.text("back"))
                    if store.canRetryFavorite {
                        Button { store.retryFavorite() } label: { Image(systemName: platformSymbol("bookmark")) }
                            .accessibilityLabel(store.text("retryFavorite"))
                    }
                    Button { store.reloadBrowser() } label: {
                        Image(systemName: platformSymbol("arrow.clockwise"))
                    }.accessibilityLabel(store.text("refresh"))
                    if !store.browserIsPlayer {
                        Button { store.syncAccount() } label: {
                            Image(systemName: platformSymbol("arrow.triangle.2.circlepath"))
                        }.disabled(store.busy).accessibilityLabel(store.text("syncAccount"))
                    }
                }
            }
        }
    }
}
#endif
