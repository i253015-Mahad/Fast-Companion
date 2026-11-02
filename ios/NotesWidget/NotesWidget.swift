//
//  NotesWidget.swift
//  Fast Companion — the iOS home-screen widget (WidgetKit).
//
//  Reads the same pinned-note payload the Flutter app writes through
//  home_widget (HomeWidgetService in Dart), straight out of the shared
//  App Group UserDefaults. No channels, no Flutter engine: WidgetKit asks
//  for a timeline, we parse what's there, SwiftUI draws it.
//
//  Must stay in sync with lib/services/home_widget_service.dart:
//    appGroupId   = "group.com.example.notesm"   (also the entitlements)
//    iosWidgetId  = -1  →  payload key "payload_-1"
//    _iosWidgetName = "NotesWidget"             (StaticConfiguration kind)
//  A tap carries uid/noteId back to the app as a `notesm://opennote?...`
//  URL tagged with `homeWidget` — home_widget's HomeWidgetPlugin only
//  recognises widget URLs by that query item (isWidgetUrl).
//

import SwiftUI
import WidgetKit

private let widgetGroupId = "group.com.example.notesm"
private let payloadKey = "payload_-1"
private let widgetKind = "NotesWidget"

// MARK: - Payload (mirrors HomeWidgetService._buildPayload)

private struct TodoRow {
  let text: String
  let isDone: Bool
  let dueMs: Double?
  let remainingMs: Double?
}

private struct CounterRow {
  let label: String
  let count: Int
}

private struct PinnedNote {
  let uid: String
  let noteId: String
  let type: String
  let title: String
  let body: String
  let todoList: [TodoRow]
  let counterList: [CounterRow]

  /// Built loosely on purpose: the Dart side owns the schema, and an extra
  /// key added over there must never keep a note from rendering.
  init?(json: [String: Any]) {
    guard
      let uid = json["uid"] as? String, !uid.isEmpty,
      let noteId = json["noteId"] as? String, !noteId.isEmpty
    else { return nil }
    self.uid = uid
    self.noteId = noteId
    self.type = json["type"] as? String ?? "text"
    self.title = json["title"] as? String ?? "Untitled"
    self.body = json["body"] as? String ?? ""

    self.todoList = ((json["todoList"] as? [[String: Any]]) ?? []).map { row in
      TodoRow(
        text: row["text"] as? String ?? "",
        isDone: row["isDone"] as? Bool ?? false,
        dueMs: row["dueMs"] as? Double,
        remainingMs: row["remainingMs"] as? Double
      )
    }
    self.counterList = ((json["counterList"] as? [[String: Any]]) ?? []).map { row in
      CounterRow(
        label: row["label"] as? String ?? "",
        count: row["count"] as? Int ?? 0
      )
    }
  }
}

private func loadNote() -> PinnedNote? {
  guard
    let defaults = UserDefaults(suiteName: widgetGroupId),
    let raw = defaults.string(forKey: payloadKey),
    !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
    let data = raw.data(using: .utf8),
    let object = try? JSONSerialization.jsonObject(with: data),
    let json = object as? [String: Any]
  else { return nil }
  return PinnedNote(json: json)
}

// MARK: - Countdown formatting (same idea as NotesWidgetProvider.kt)

private func formatRemaining(row: TodoRow, now: Date) -> String? {
  var ms: Double?
  if let remaining = row.remainingMs {
    ms = remaining
  } else if let due = row.dueMs {
    ms = due - now.timeIntervalSince1970 * 1000
  }
  guard let ms else { return nil }
  let minutes = ms / 60000
  if minutes <= 0 { return "overdue" }
  if minutes < 60 { return "\(Int(minutes))m" }
  let hours = minutes / 60
  if hours < 24 { return "\(Int(hours))h" }
  return "\(Int(hours / 24))d"
}

// MARK: - Timeline

private struct NoteEntry: TimelineEntry {
  let date: Date
  let note: PinnedNote?
}

private struct Provider: TimelineProvider {
  func placeholder(in context: Context) -> NoteEntry {
    NoteEntry(date: Date(), note: PinnedNote(json: samplePayload))
  }

  func getSnapshot(in context: Context, completion: @escaping (NoteEntry) -> Void) {
    let note = loadNote() ?? (context.isPreview ? PinnedNote(json: samplePayload) : nil)
    completion(NoteEntry(date: Date(), note: note))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<NoteEntry>) -> Void) {
    let entry = NoteEntry(date: Date(), note: loadNote())
    // The app pushes a fresh timeline on every edit (HomeWidgetService
    // → updateWidget). The 15-minute refresh is only so a countdown shown
    // from dueMs doesn't sit frozen between edits.
    let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date()
    completion(Timeline(entries: [entry], policy: .after(next)))
  }
}

private let samplePayload: [String: Any] = [
  "uid": "sample",
  "noteId": "sample",
  "type": "todo",
  "title": "Example note",
  "body": "Long-press a note in the app to pin it here.",
  "todoList": [
    ["text": "Pinned from the app", "isDone": false],
    ["text": "Tap to open the note", "isDone": true],
  ],
  "counterList": [],
]

// MARK: - Rendering

private enum Palette {
  static let background = Color(red: 0x08 / 255, green: 0x34 / 255, blue: 0x3D / 255) // AppColors.navBar
  static let orange = Color(red: 0xFF / 255, green: 0x9F / 255, blue: 0x68 / 255) // AppColors.cardOrange
  static let green = Color(red: 0x2A / 255, green: 0xB7 / 255, blue: 0xA9 / 255) // AppColors.cardGreen
  static let yellow = Color(red: 0xF2 / 255, green: 0xC9 / 255, blue: 0x4C / 255) // AppColors.cardYellow
}

private struct NotesWidgetEntryView: View {
  @Environment(\.widgetFamily) private var family
  let entry: NoteEntry

  private var rowLimit: Int {
    switch family {
    case .systemSmall: return 3
    case .systemMedium: return 5
    default: return 12
    }
  }

  private var bodyLineLimit: Int {
    switch family {
    case .systemSmall: return 4
    case .systemMedium: return 7
    default: return 16
    }
  }

  /// `homeWidget` is the marker home_widget requires to treat the URL as its
  /// own (HomeWidgetPlugin.isWidgetUrl); without it the tap never reaches Dart.
  private var link: URL? {
    guard let note = entry.note else { return nil }
    var components = URLComponents()
    components.scheme = "notesm"
    components.host = "opennote"
    components.queryItems = [
      URLQueryItem(name: "uid", value: note.uid),
      URLQueryItem(name: "noteId", value: note.noteId),
      URLQueryItem(name: "homeWidget", value: nil),
    ]
    return components.url
  }

  var body: some View {
    content
      .widgetURL(link)
      .modifier(Background())
  }

  @ViewBuilder
  private var content: some View {
    if let note = entry.note {
      noteView(note)
    } else {
      emptyView
    }
  }

  private func noteView(_ note: PinnedNote) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 4) {
        Image(systemName: "note.text")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(Palette.orange)
        Text("NOTES M")
          .font(.system(size: 9, weight: .bold))
          .tracking(0.5)
          .foregroundStyle(Palette.orange)
      }

      Text(note.title)
        .font(.system(size: family == .systemSmall ? 13 : 15, weight: .bold))
        .foregroundStyle(.white)
        .lineLimit(2)

      rows(for: note)

      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .padding(12)
  }

  @ViewBuilder
  private func rows(for note: PinnedNote) -> some View {
    switch note.type {
    case "todo", "timed":
      todoRows(note)
    case "counter":
      counterRows(note)
    default:
      Text(note.body.isEmpty ? "No content" : note.body)
        .font(.system(size: 12))
        .foregroundStyle(.white.opacity(0.85))
        .lineLimit(bodyLineLimit)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }
  }

  private func todoRows(_ note: PinnedNote) -> some View {
    let visible = Array(note.todoList.prefix(rowLimit))
    return VStack(alignment: .leading, spacing: 5) {
      if visible.isEmpty {
        Text(note.body.isEmpty ? "No tasks" : note.body)
          .font(.system(size: 12))
          .foregroundStyle(.white.opacity(0.85))
          .lineLimit(bodyLineLimit)
      }
      ForEach(Array(visible.enumerated()), id: \.offset) { _, item in
        HStack(spacing: 6) {
          ZStack {
            Circle()
              .strokeBorder(
                item.isDone ? Palette.green : Color.white.opacity(0.45),
                lineWidth: 1.4
              )
            if item.isDone {
              Image(systemName: "checkmark")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(Palette.green)
            }
          }
          .frame(width: 12, height: 12)

          Text(item.text)
            .font(.system(size: 12))
            .foregroundStyle(
              item.isDone ? Color.white.opacity(0.55) : Color.white
            )
            .strikethrough(item.isDone, color: .white.opacity(0.4))
            .lineLimit(1)

          Spacer(minLength: 4)

          if let due = formatRemaining(row: item, now: entry.date) {
            Text(due)
              .font(.system(size: 10, weight: .semibold, design: .rounded))
              .foregroundStyle(item.isDone ? Palette.yellow : Palette.orange)
          }
        }
      }
      if note.todoList.count > visible.count {
        Text("+\(note.todoList.count - visible.count) more")
          .font(.system(size: 10))
          .foregroundStyle(.white.opacity(0.55))
      }
    }
  }

  private func counterRows(_ note: PinnedNote) -> some View {
    let visible = Array(note.counterList.prefix(rowLimit))
    return VStack(alignment: .leading, spacing: 5) {
      if visible.isEmpty {
        Text(note.body.isEmpty ? "No counters" : note.body)
          .font(.system(size: 12))
          .foregroundStyle(.white.opacity(0.85))
          .lineLimit(bodyLineLimit)
      }
      ForEach(Array(visible.enumerated()), id: \.offset) { _, item in
        HStack {
          Text(item.label)
            .font(.system(size: 12))
            .foregroundStyle(.white)
            .lineLimit(1)
          Spacer(minLength: 4)
          Text("\(item.count)")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(Palette.green))
        }
      }
      if note.counterList.count > visible.count {
        Text("+\(note.counterList.count - visible.count) more")
          .font(.system(size: 10))
          .foregroundStyle(.white.opacity(0.55))
      }
    }
  }

  private var emptyView: some View {
    VStack(spacing: 6) {
      Image(systemName: "pin.circle.fill")
        .font(.system(size: 24))
        .foregroundStyle(Palette.orange)
      Text("No note pinned")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white)
      Text("Long-press a note in the app and choose “Show on widget”.")
        .font(.system(size: 10))
        .foregroundStyle(.white.opacity(0.7))
        .multilineTextAlignment(.center)
        .lineLimit(3)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(12)
  }
}

/// iOS 17 wants containerBackground, older versions want a plain background.
private struct Background: ViewModifier {
  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(iOSApplicationExtension 17.0, *) {
      content.containerBackground(Palette.background, for: .widget)
    } else {
      content.background(Palette.background)
    }
  }
}

// MARK: - Widget declaration

@main
struct NotesWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: widgetKind, provider: Provider()) { entry in
      NotesWidgetEntryView(entry: entry)
    }
    .configurationDisplayName("Notes M")
    .description("Shows a note you pin from the Fast Companion app.")
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
  }
}

struct NotesWidget_Previews: PreviewProvider {
  static var previews: some View {
    NotesWidgetEntryView(entry: NoteEntry(date: Date(), note: PinnedNote(json: samplePayload)))
      .previewContext(WidgetPreviewContext(family: .systemMedium))
  }
}
