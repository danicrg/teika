import SwiftUI
import WidgetKit

/// Teika on the watch face (and in the Smart Stack): one tap opens the watch app and
/// starts recording, the wrist's equivalent of the phone's Lock Screen widget.
///
/// The tap travels as `teika://record` through `widgetURL`, which watchOS hands to the
/// app's `onOpenURL`; the app then makes the same `RecordingLauncher` request the
/// Control Center control does. The content never changes, so there is one entry and
/// no refresh.
struct WatchRecordComplication: Widget {
    static let kind = "com.danicrg.teika.watchkitapp.complication.record"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: Provider()) { _ in
            WatchRecordComplicationView()
        }
        .configurationDisplayName("Start Recording")
        .description("Opens Teika on your watch and starts recording.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

private struct Provider: TimelineProvider {
    func placeholder(in _: Context) -> Entry {
        Entry(date: .now)
    }

    func getSnapshot(in _: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: .now)], policy: .never))
    }
}

private struct Entry: TimelineEntry {
    let date: Date
}

private struct WatchRecordComplicationView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryCorner:
                Image(systemName: "mic.fill")
                    .font(.title2)
                    .widgetLabel("Teika")
            case .accessoryRectangular:
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill")
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Teika")
                            .font(.headline)
                            .widgetAccentable()
                        Text("Start recording")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .accessoryInline:
                Label("Record", systemImage: "mic.fill")
            default:
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "mic.fill")
                        .font(.title2)
                        .widgetAccentable()
                }
            }
        }
        .widgetURL(TeikaURL.record)
        .containerBackground(for: .widget) { Color.clear }
    }
}
