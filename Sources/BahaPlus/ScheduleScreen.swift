#if SKIP || os(iOS)
import Foundation
import SwiftUI
import BahaCore

struct ScheduleScreen: View {
    @Bindable var store: AppStore
    @State private var day = ScheduleScreen.currentTaipeiDay()
    private var days: [String] {
        store.language == "zh-Hans" ? ["周日", "周一", "周二", "周三", "周四", "周五", "周六"] :
            ["週日", "週一", "週二", "週三", "週四", "週五", "週六"]
    }
    private var items: [Anime] {
        store.seasonal.filter { $0.updateDay == day }
            .sorted { ($0.updateTime ?? "") < ($1.updateTime ?? "") }
    }
    static func currentTaipeiDay() -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return calendar.component(.weekday, from: Date()) - 1
    }
    var body: some View {
        VStack(spacing: 0) {
            Picker(store.text("schedule"), selection: $day) {
                ForEach([1, 2, 3, 4, 5, 6, 0], id: \.self) { index in
                    Text(days[index]).tag(index)
                }
            }.pickerStyle(.segmented).padding(.horizontal, 20).padding(.vertical, 14)
            List {
                if items.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: platformSymbol("cup.and.saucer")).font(.largeTitle).foregroundStyle(.secondary)
                        Text(store.text("noUpdates")).font(.headline)
                    }.frame(maxWidth: .infinity).padding(.vertical, 50).listRowSeparator(.hidden)
                } else {
                    ForEach(items) { anime in
                        Button { store.openDetail(anime) } label: {
                            HStack(spacing: 14) {
                                timeLabel(anime.updateTime ?? "")
                                    .foregroundStyle(.secondary).frame(width: 42)
                                RemoteArtwork(url: anime.coverURL).frame(width: 88, height: 58)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(anime.title).font(.subheadline.weight(.medium)).lineLimit(2)
                                    Text(anime.episodeLabel ?? "").font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }.padding(.vertical, 8)
                        }.buttonStyle(.plain)
                    }
                }
                Text(store.text("scheduleNote")).font(.caption2).foregroundStyle(.secondary)
                CatalogFooter(store: store)
            }.listStyle(.plain).floatingTabContentMargins()
        }
    }
    @ViewBuilder private func timeLabel(_ value: String) -> some View {
        #if SKIP
        Text(value).font(.caption)
        #else
        Text(value).font(.caption.monospacedDigit())
        #endif
    }
}
#endif
