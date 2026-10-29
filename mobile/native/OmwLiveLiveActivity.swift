import ActivityKit
import SwiftUI
import WidgetKit

// What the Live Activity looks like: on the lock screen, and in the Dynamic Island (compact, minimal and long-press expanded).
// Before your leave time it counts down to it ("Leave in 12:04"), then to the start, then shows who's there.

private extension Color {
    static let sun = Color(red: 1, green: 0.9, blue: 0)
}

@available(iOS 16.2, *)
private struct Phase {
    let label: String
    let until: Date?
    init(_ s: OmwActivityAttributes.ContentState) {
        let now = Date(), leave = Date(timeIntervalSince1970: s.leaveAt), start = Date(timeIntervalSince1970: s.startAt)
        if s.arrived { label = "You're there"; until = nil }
        else if leave > now { label = "Leave in"; until = leave }
        else if start > now { label = "Starts in"; until = start }
        else { label = "Started"; until = nil }
    }
}

@available(iOS 16.2, *)
private struct Countdown: View {
    let state: OmwActivityAttributes.ContentState
    var body: some View {
        let p = Phase(state)
        if let until = p.until {
            Text(timerInterval: Date()...until, countsDown: true).monospacedDigit()
        } else {
            Text("\(state.here)/\(state.total)")
        }
    }
}

@available(iOS 16.2, *)
private struct Dots: View {  // one dot per person: yellow = there
    let state: OmwActivityAttributes.ContentState
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<max(state.total, 1), id: \.self) { i in
                Circle().fill(i < state.here ? Color.sun : Color.white.opacity(0.25)).frame(width: 8, height: 8)
            }
        }
    }
}

@available(iOS 16.2, *)
private struct Badge: View {
    var body: some View {
        Text("omw!")
            .font(.system(size: 13, weight: .black, design: .rounded))
            .foregroundColor(.black)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.sun, in: RoundedRectangle(cornerRadius: 9))
    }
}

@available(iOS 16.2, *)
private struct LockScreen: View {
    let context: ActivityViewContext<OmwActivityAttributes>
    var body: some View {
        let s = context.state, p = Phase(s)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Badge()
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.title).font(.headline).foregroundColor(.white).lineLimit(1)
                    Text(context.attributes.venue).font(.subheadline).foregroundColor(.white.opacity(0.7)).lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(p.label).font(.caption.weight(.semibold)).foregroundColor(.white.opacity(0.7))
                    Countdown(state: s).font(.title2.weight(.heavy)).foregroundColor(.sun).multilineTextAlignment(.trailing)
                }
            }
            HStack {
                Dots(state: s)
                Text("\(s.here) of \(s.total) there").font(.caption.weight(.semibold)).foregroundColor(.white.opacity(0.8))
                Spacer()
                Text(s.note).font(.caption.weight(.bold)).foregroundColor(.sun).lineLimit(1)
            }
        }
        .padding(16)
    }
}

@available(iOS 16.2, *)
struct OmwLiveLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OmwActivityAttributes.self) { context in
            LockScreen(context: context)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "omw://hangout/\(context.attributes.hangoutId)"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Badge().padding(.leading, 6).padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(Phase(context.state).label).font(.caption2.weight(.semibold)).foregroundColor(.white.opacity(0.7))
                        Countdown(state: context.state).font(.title3.weight(.heavy)).foregroundColor(.sun).multilineTextAlignment(.trailing)
                    }
                    .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 1) {
                        Text(context.attributes.title).font(.headline).lineLimit(1)
                        Text(context.attributes.venue).font(.caption).foregroundColor(.white.opacity(0.7)).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Dots(state: context.state)
                        Text("\(context.state.here) of \(context.state.total) there").font(.caption.weight(.semibold))
                        Spacer()
                        Text(context.state.note).font(.caption.weight(.bold)).foregroundColor(.sun).lineLimit(1)
                    }
                    .padding(.horizontal, 6)
                }
            } compactLeading: {
                Image(systemName: context.state.arrived ? "checkmark.circle.fill" : "figure.walk").foregroundColor(.sun)
            } compactTrailing: {
                Countdown(state: context.state).font(.caption.weight(.bold)).foregroundColor(.sun).frame(maxWidth: 50)
            } minimal: {
                Image(systemName: context.state.arrived ? "checkmark.circle.fill" : "figure.walk").foregroundColor(.sun)
            }
            .keylineTint(.sun)
            .widgetURL(URL(string: "omw://hangout/\(context.attributes.hangoutId)"))
        }
    }
}
