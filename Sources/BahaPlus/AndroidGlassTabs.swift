#if SKIP
import SwiftUI
import dev.chrisbanes.haze.HazeState
import dev.chrisbanes.haze.HazeStyle
import dev.chrisbanes.haze.HazeTint
import dev.chrisbanes.haze.hazeSource
import dev.chrisbanes.haze.hazeEffect
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp

/// The shared SwiftUI tabs retain their navigation state; Android draws a
/// floating control layer over a separate live backdrop capture.
struct AndroidGlassTabs: View {
    @Bindable var store: AppStore
    let content: AnyView
    @State private var backdrop: HazeState = HazeState()
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .bottom) {
            content
                .toolbar(.hidden, for: .tabBar)
                .composeModifier { modifier in modifier.hazeSource(state: backdrop) }
            HStack(spacing: 0) {
                tab("explore", symbol: "safari", index: 0)
                tab("schedule", symbol: "calendar", index: 1)
                tab("library", symbol: "list.bullet", index: 2)
                tab("search", symbol: "magnifyingglass", index: 3)
            }
            .padding(6)
            .composeModifier { modifier in
                let surface = colorScheme == .dark ?
                    androidx.compose.ui.graphics.Color.Black : androidx.compose.ui.graphics.Color.White
                let style = HazeStyle(
                    backgroundColor: surface,
                    tint: HazeTint(color: surface.copy(alpha: Float(colorScheme == .dark ? 0.62 : 0.58))),
                    blurRadius: Float(22.0).dp,
                    noiseFactor: Float(0.02)
                )
                return modifier.clip(RoundedCornerShape(Float(40.0).dp))
                    .hazeEffect(state: backdrop, style: style)
            }
            .overlay(
                Capsule().strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(0.65), Color.white.opacity(0.12)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1.0
                )
            )
            .shadow(color: Color.black.opacity(0.16), radius: 14, x: 0, y: 5)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private func tab(_ key: String, symbol: String, index: Int) -> some View {
        Button { store.tab = index } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 22, weight: .medium))
                Text(store.text(key)).font(.caption2.weight(.semibold)).lineLimit(1)
            }
            .foregroundStyle(store.tab == index ? Brand.accent : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(store.tab == index ? Brand.accent.opacity(0.14) : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(store.text(key))
        .accessibilityAddTraits(store.tab == index ?
                               AccessibilityTraits.isSelected : AccessibilityTraits(rawValue: 0))
        .accessibilityIdentifier("native-tab-\(index)")
    }
}
#endif

#if SKIP || os(iOS)
import SwiftUI

extension View {
    @ViewBuilder func floatingTabContentMargins() -> some View {
        #if SKIP
        self.contentMargins(.bottom, 94.0, for: .scrollContent)
        #else
        self
        #endif
    }
}
#endif
