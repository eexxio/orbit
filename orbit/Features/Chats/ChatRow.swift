import SwiftUI

struct ChatRow: View {
    let chat: HermesSession
    let isReplying: Bool
    let now: Date
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var restingLeading: CGFloat?
    @State private var swipeInset: CGFloat = 0

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chat.title).lineLimit(3)
                    HStack { if isReplying { ReplyingDot() }; metadata }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if isReplying {
                        ReplyingDot().alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.5).combined(with: .opacity))
                    }
                    Text(chat.title).lineLimit(1).truncationMode(.tail).layoutPriority(1)
                    Spacer(minLength: 8)
                    if swipeInset == 0 { metadata }
                }
            }
        }
        .padding(.leading, swipeInset)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .named("chatList")).minX
        } action: { leading in
            if let restingLeading { swipeInset = max(0, restingLeading - leading) }
            else { restingLeading = leading }
        }
        .font(.body).foregroundStyle(.primary)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: isReplying)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(chat.title)
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier("chats.row.\(chat.id)")
    }

    @ViewBuilder private var metadata: some View {
        Group {
            if isReplying { Text("Replying").accessibilityIdentifier("chats.row.\(chat.id).replying") }
            else if let date = activityDate {
                Text(RelativeChatTime.short(date, now: now))
            }
        }.font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
    }

    private var activityDate: Date? {
        chat.lastActive.map { min(Date(timeIntervalSince1970: $0), now) }
    }

    private var accessibilityValue: String {
        var value = ""
        if isReplying { value = "Replying" }
        else if let date = activityDate {
            if now.timeIntervalSince(date) < 60 { value = String(localized: "now") }
            else if now.timeIntervalSince(date) < 7 * 86400 {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .full
                value = formatter.localizedString(for: date, relativeTo: now)
            } else { value = date.formatted(date: .long, time: .omitted) }
        }
        if chat.pinned { value += value.isEmpty ? "pinned" : ", pinned" }
        return value
    }
}

enum RelativeChatTime {
    static func short(_ date: Date, now: Date) -> String {
        let age = now.timeIntervalSince(date)
        if age < 60 { return String(localized: "now") }
        if age < 3600 {
            return Duration.seconds(Double(Int(age / 60) * 60)).formatted(.units(allowed: [.minutes], width: .narrow))
        }
        if age < 86400 {
            return Duration.seconds(Double(Int(age / 3600) * 3600)).formatted(.units(allowed: [.hours], width: .narrow))
        }
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: calendar.date(byAdding: .day, value: -1, to: now)!) {
            return String(localized: "Yesterday")
        }
        if age < 7 * 86400 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.day().month(.twoDigits).year())
    }
}

struct ReplyingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var size = 8.0
    @State private var dim = false
    var body: some View {
        Circle().fill(Color.accentColor).frame(width: size, height: size)
            .opacity(reduceMotion ? 1 : (dim ? 0.35 : 1))
            .onAppear { dim = true }
            .animation(reduceMotion ? nil : .easeInOut(duration: 1).repeatForever(autoreverses: true), value: dim)
            .accessibilityHidden(true)
    }
}
