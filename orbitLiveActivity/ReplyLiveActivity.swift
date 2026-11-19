import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// A long agent reply on the Lock Screen and in the Dynamic Island.
struct ReplyLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ReplyActivityAttributes.self) { context in
            ReplyCard(context: context)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .widgetURL(context.attributes.url)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text("Orbit").font(.caption.weight(.semibold)).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ElapsedText(context: context).font(.caption).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 12) {
                        StatusLabel(state: context.state)
                        Spacer(minLength: 0)
                        ReplyAction(context: context)
                    }
                }
            } compactLeading: {
                PhaseGlyph(state: context.state)
            } compactTrailing: {
                if context.state.showsTimer && !context.isStale {
                    Text(timerInterval: context.attributes.startedAt...Date.distantFuture, countsDown: false)
                        .monospacedDigit()
                        .frame(maxWidth: 40)
                } else {
                    Text("—").accessibilityHidden(true)
                }
            } minimal: {
                PhaseGlyph(state: context.state)
            }
            .widgetURL(context.attributes.url)
        }
    }
}

private struct ReplyCard: View {
    let context: ActivityViewContext<ReplyActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Orbit")
                Spacer()
                ElapsedText(context: context)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Orbit, agent reply")

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    StatusLabel(state: context.state)
                    Spacer(minLength: 0)
                    ReplyAction(context: context)
                }
                VStack(alignment: .leading, spacing: 8) {
                    StatusLabel(state: context.state, showsDetail: false)
                    ReplyAction(context: context)
                }
            }
        }
    }
}

private struct StatusLabel: View {
    let state: ReplyActivityAttributes.ContentState
    var showsDetail = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(state.status).font(.subheadline.weight(.semibold))
            } icon: {
                PhaseGlyph(state: state)
            }
            if showsDetail, let detail = state.detail {
                Text(detail)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(state.accessibleDetail ?? detail)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("replyActivity.status")
    }
}

private struct PhaseGlyph: View {
    let state: ReplyActivityAttributes.ContentState

    var body: some View {
        Image(systemName: state.symbol)
            .foregroundStyle(state.phase == .unconfirmed ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
            .accessibilityLabel(state.status)
    }
}

private struct ElapsedText: View {
    let context: ActivityViewContext<ReplyActivityAttributes>

    var body: some View {
        if context.state.showsTimer && !context.isStale {
            Text(timerInterval: context.attributes.startedAt...Date.distantFuture, countsDown: false)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 60, alignment: .trailing)
        }
    }
}

/// Stop while this turn's live socket can interrupt it; Open chat otherwise.
private struct ReplyAction: View {
    let context: ActivityViewContext<ReplyActivityAttributes>

    var body: some View {
        let state = context.state
        if state.phase == .stopping {
            EmptyView()
        } else if state.canStop && !state.phase.isTerminal && !context.isStale {
            Button(intent: StopReplyIntent(route: context.attributes.route)) {
                Label {
                    Text("Stop")
                } icon: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 15))
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(.primary)
            .accessibilityIdentifier("replyActivity.stop")
        } else {
            Link(destination: context.attributes.url) {
                Label {
                    Text("Open chat")
                } icon: {
                    Image(systemName: "arrow.up.right").font(.system(size: 14))
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(.fill.tertiary, in: .capsule)
            }
            .accessibilityIdentifier("replyActivity.open")
        }
    }
}
