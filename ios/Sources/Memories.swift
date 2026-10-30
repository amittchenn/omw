// Memories, like the web app's: each month as a calendar, with the photo you posted (or the plan you went to)
// on its day. Tap a day with a photo to open the post, or a plan to open it.
import SwiftUI

struct MemoriesCalendar: View {
    @Environment(Session.self) private var session

    private struct Day: Identifiable {
        let date: Date
        var photo: String = ""
        var post: String?
        var plan: String?
        var id: Date { date }
    }

    /// what happened on each day: your posts (and group photos with you in them), then plans you went to
    private var days: [Date: Day] {
        let cal = Calendar.current, uid = session.uid ?? ""
        var out: [Date: Day] = [:]
        for h in session.past {
            let d = cal.startOfDay(for: h.start)
            out[d] = out[d] ?? Day(date: d, plan: h.id)
        }
        for p in session.allPosts where p.by == uid || p.members.contains(uid) {
            let d = cal.startOfDay(for: p.at)
            if out[d]?.post == nil { out[d] = Day(date: d, photo: p.allPhotos.first ?? "", post: p.id, plan: out[d]?.plan) }
        }
        return out
    }

    /// months with something in them, newest first (always this month)
    private var months: [Date] {
        let cal = Calendar.current
        var set = Set(days.keys.compactMap { cal.dateInterval(of: .month, for: $0)?.start })
        if let now = cal.dateInterval(of: .month, for: .now)?.start { set.insert(now) }
        return set.sorted(by: >)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 22) {
            let all = days
            ForEach(months, id: \.self) { month in
                VStack(alignment: .leading, spacing: 8) {
                    Text(month.formatted(.dateTime.month(.wide).year())).font(.headline).padding(.horizontal, 16)
                    HStack(spacing: 0) {
                        ForEach(Array(Calendar.current.veryShortStandaloneWeekdaySymbols.rotated(by: Calendar.current.firstWeekday - 1).enumerated()), id: \.offset) { _, s in
                            Text(s).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, 12)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 3) {
                        ForEach(Array(Self.cells(for: month).enumerated()), id: \.offset) { _, date in
                            if let date { cell(date, all[date]) } else { Color.clear.frame(height: 1) }
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
        }
        .padding(.top, 14)
    }

    @ViewBuilder private func cell(_ date: Date, _ day: Day?) -> some View {
        let n = Calendar.current.component(.day, from: date)
        let today = Calendar.current.isDateInToday(date)
        let tile = Color(.secondarySystemFill)
            .aspectRatio(3 / 4, contentMode: .fit)
            .overlay { if let photo = day?.photo, !photo.isEmpty { RemoteImage(source: photo) } }
            .overlay(alignment: .topLeading) {
                Text("\(n)").font(.caption2.weight(.bold))
                    .foregroundStyle(day?.photo.isEmpty == false ? Color.white : today ? Color.red : Color.secondary)
                    .shadow(color: day?.photo.isEmpty == false ? .black.opacity(0.5) : .clear, radius: 2)
                    .padding(4)
            }
            .overlay(alignment: .bottom) {
                if day?.plan != nil, day?.photo.isEmpty != false { Circle().fill(Color.omwBlue).frame(width: 6, height: 6).padding(5) }
            }
            .clipShape(.rect(cornerRadius: 6))
        if let post = day?.post {
            NavigationLink(value: PostRoute(id: post)) { tile }.buttonStyle(.plain)
        } else if let plan = day?.plan {
            NavigationLink(value: PlanRoute(id: plan)) { tile }.buttonStyle(.plain)
        } else {
            tile.opacity(0.6)
        }
    }

    /// the month's days in a 7-wide grid (nil = the blanks before the 1st)
    private static func cells(for month: Date) -> [Date?] {
        let cal = Calendar.current
        guard let range = cal.range(of: .day, in: .month, for: month) else { return [] }
        let lead = (cal.component(.weekday, from: month) - cal.firstWeekday + 7) % 7
        let blanks: [Date?] = (0..<lead).map { _ in nil }
        return blanks + range.compactMap { cal.date(byAdding: .day, value: $0 - 1, to: month) }
    }
}

extension Array {
    func rotated(by n: Int) -> [Element] {
        guard !isEmpty else { return self }
        let k = ((n % count) + count) % count
        return Array(self[k...] + self[..<k])
    }
}
