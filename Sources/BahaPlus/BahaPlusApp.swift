import Foundation
import SwiftUI

@MainActor public struct BahaPlusRootView: View {
    #if SKIP || os(iOS)
    @State private var store = AppStore()
    #endif
    public init() {}
    public var body: some View {
        #if SKIP || os(iOS)
        AppRoot(store: store)
            .tint(Brand.accent)
            .preferredColorScheme(store.colorScheme)
            .environment(\.locale, Locale(identifier: store.language))
        #else
        Text("Baha Plus — iOS / Android")
        #endif
    }
}

public final class BahaPlusAppDelegate: Sendable {
    public static let shared = BahaPlusAppDelegate()
    private init() {}
    public func onInit() {}
    public func onLaunch() {}
    public func onResume() {}
    public func onPause() {}
    public func onStop() {}
    public func onDestroy() {}
    public func onLowMemory() {}
}
