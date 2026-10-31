// Memories as a calendar, week by week: scroll down through the weeks (next week and this one first, then back in
// time). Each day shows the group photo from that day, or a dot for a plan you went to (blue) or one coming up
// (yellow). Tap a day and what happened opens right under its week: its memories and plans, each one tappable.
import SwiftUI

struct MemoriesCalendar: View {
    @Environment(Session.self) private var session
    @State private var selected: Date?

    private struct Day {
        var posts: [Post] = []
        var plans: [Hangout] = []
        var photo: String { posts.first?.allPhotos.first ?? "" }
    }

    /// everything by day: your memories (group photos with you in them, and older posts), and your plans, past and ahead
    private var days: [Date: Day] {
        let cal = Calendar.current, uid = session.uid ?? ""
        var out: [Date: Day] = [:]
        for h in session.hangouts where h.attendees.contains(uid) {
            out[cal.startOfDay(for: h.start), default: Day()].plans.append(h)
        }
        for p in session.allPosts where p.by == uid || p.members.contains(uid) {
            out[cal.startOfDay(for: p.at), default: Day()].posts.append(p)
        }
        return out
    }

    /// the weeks to show, newest first: next week, this week, then back to your first memory (at least 8 weeks)
    private func weeks(_ all: [Date: Day]) -> [Date] {
        let cal = Calendar.current
        guard let thisWeek = cal.dateInterval(of: .weekOfYear, for: .now)?.start else { return [] }
        let oldest = all.keys.min().flatMap { cal.dateInterval(of: .weekOfYear, for: $0)?.start } ?? thisWeek
        let back = max(8, (cal.dateComponents([.weekOfYear], from: oldest, to: thisWeek).weekOfYear ?? 0) + 1)
        return (-1..<back).compactMap { cal.date(byAdding: .weekOfYear, value: -$0, to: thisWeek) }
    }

    var body: some View {
        let all = days
        LazyVStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 0) {
                ForEach(Array(Calendar.current.veryShortStandaloneWeekdaySymbols.rotated(by: Calendar.current.firstWeekday - 1).enumerated()), id: \.offset) { _, s in
                    Text(s).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            ForEach(weeks(all), id: \.self) { week in
                VStack(alignment: .leading, spacing: 8) {
                    Text(Self.title(week)).font(.system(size: 15, weight: .heavy, design: .rounded))
                    HStack(spacing: 4) {
                        ForEach(0..<7, id: \.self) { i in
                            if let date = Calendar.current.date(byAdding: .day, value: i, to: week) {
                                cell(date, all[date])
                            }
                        }
                    }
                    // the day you tapped, opened right under its week
                    if let selected, Calendar.current.isDate(selected, equalTo: week, toGranularity: .weekOfYear) {
                        dayDetail(selected, all[selected] ?? Day())
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .sensoryFeedback(.selection, trigger: selected)
    }

    /// "This week", "Next week", "Last week", or "Oct 12 – 18"
    private static func title(_ week: Date) -> String {
        let cal = Calendar.current
        guard let now = cal.dateInterval(of: .weekOfYear, for: .now)?.start else { return "" }
        let n = cal.dateComponents([.weekOfYear], from: now, to: week).weekOfYear ?? 0
        switch n {
        case 0: return "This week"
        case 1: return "Next week"
        case -1: return "Last week"
        default:
            let end = cal.date(byAdding: .day, value: 6, to: week) ?? week
            let sameMonth = cal.isDate(week, equalTo: end, toGranularity: .month)
            return "\(week.formatted(.dateTime.month(.abbreviated).day())) – \(sameMonth ? end.formatted(.dateTime.day()) : end.formatted(.dateTime.month(.abbreviated).day()))"
        }
    }

    private func cell(_ date: Date, _ day: Day?) -> some View {
        let cal = Calendar.current
        let today = cal.isDateInToday(date)
        let isSelected = selected.map { cal.isDate(date, inSameDayAs: $0) } ?? false
        let photo = day?.photo ?? ""
        let ahead = day?.plans.contains { !$0.isOver } == true
        return Button {
            withAnimation(.snappy(duration: 0.25)) { selected = isSelected ? nil : date }  // tap again to close
        } label: {
            Color.omwCard
                .aspectRatio(3 / 4, contentMode: .fit)
                .overlay { if !photo.isEmpty { RemoteImage(source: photo) } }
                .overlay(alignment: .topLeading) {
                    Text("\(cal.component(.day, from: date))").font(.caption2.weight(.bold))
                        .foregroundStyle(!photo.isEmpty ? Color.white : today ? Color.coral : Color.secondary)
                        .shadow(color: !photo.isEmpty ? .black.opacity(0.5) : .clear, radius: 2)
                        .padding(4)
                }
                .overlay(alignment: .bottom) {
                    if day?.plans.isEmpty == false, photo.isEmpty {
                        Circle().fill(ahead ? Color.sun : Color.omwBlue).frame(width: 6, height: 6).padding(5)
                    }
                }
                .clipShape(.rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Color.coral : today ? Color.coral.opacity(0.5) : .clear,
                                                                       lineWidth: isSelected ? 2.5 : 1.5))
        }
        .buttonStyle(Pressable())
        .frame(maxWidth: .infinity)
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
    }

    // ---------- the day you tapped ----------
    private func dayDetail(_ date: Date, _ day: Day) -> some View {
        let cal = Calendar.current
        return VStack(alignment: .leading, spacing: 10) {
            Text(cal.isDateInToday(date) ? "Today" : date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(.subheadline.weight(.heavy))
            if !day.posts.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(day.posts) { p in
                            NavigationLink(value: PostRoute(id: p.id)) {
                                Color.omwCard2
                                    .frame(width: 96, height: 128)
                                    .overlay { RemoteImage(source: p.allPhotos.first ?? "") }
                                    .clipShape(.rect(cornerRadius: 12))
                            }
                            .buttonStyle(Pressable())
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            ForEach(day.plans) { h in
                NavigationLink(value: PlanRoute(id: h.id)) { PlanRow(hangout: h) }.buttonStyle(.plain)
            }
            if day.posts.isEmpty && day.plans.isEmpty {
                Text(date < cal.startOfDay(for: .now) ? "Nothing that day." : "Nothing planned yet.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.omwCard, in: .rect(cornerRadius: 14))
    }
}

extension Array {
    func rotated(by n: Int) -> [Element] {
        guard !isEmpty else { return self }
        let k = ((n % count) + count) % count
        return Array(self[k...] + self[..<k])
    }
}
