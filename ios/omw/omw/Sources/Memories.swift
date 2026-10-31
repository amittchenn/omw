// Memories as a calendar: one month at a time (swipe or the arrows to move, Today to come back). Days show the group
// photo from that day, a dot for a plan you went to (blue) or one coming up (yellow). Tap any day to see what happened
// there underneath (its memories and plans, each one tappable), or to plan something on that day.
import SwiftUI

struct MemoriesCalendar: View {
    @Environment(Session.self) private var session
    @State private var month = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
    @State private var selected = Calendar.current.startOfDay(for: .now)
    @State private var planningDay: Date?
    @State private var direction = 1  // which way the month slides

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

    var body: some View {
        let all = days
        VStack(alignment: .leading, spacing: 10) {
            header
            HStack(spacing: 0) {
                ForEach(Array(Calendar.current.veryShortStandaloneWeekdaySymbols.rotated(by: Calendar.current.firstWeekday - 1).enumerated()), id: \.offset) { _, s in
                    Text(s).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 3) {
                ForEach(Array(Self.cells(for: month).enumerated()), id: \.offset) { _, date in
                    if let date { cell(date, all[date]) } else { Color.clear.aspectRatio(3 / 4, contentMode: .fit) }
                }
            }
            .id(month)
            .transition(.asymmetric(insertion: .move(edge: direction > 0 ? .trailing : .leading).combined(with: .opacity),
                                    removal: .move(edge: direction > 0 ? .leading : .trailing).combined(with: .opacity)))
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 20).onEnded { v in
                guard abs(v.translation.width) > 50, abs(v.translation.width) > abs(v.translation.height) else { return }
                move(v.translation.width < 0 ? 1 : -1)
            })
            dayDetail(all[selected] ?? Day())
                .padding(.top, 6)
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .clipped()
        .sensoryFeedback(.selection, trigger: selected)
        .sheet(item: Binding(get: { planningDay.map(PlanDay.init) }, set: { if $0 == nil { planningDay = nil } })) { d in
            PlanSheet(day: d.date).withOmw().presentationDetents([.large]).presentationDragIndicator(.visible)
        }
    }

    // ---------- the month ----------
    private var header: some View {
        HStack(spacing: 6) {
            Text(month.formatted(.dateTime.month(.wide).year())).font(.headline)
            Spacer()
            if !Calendar.current.isDate(month, equalTo: .now, toGranularity: .month) || !Calendar.current.isDateInToday(selected) {
                Button("Today") {
                    let now = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
                    direction = now > month ? 1 : -1
                    withAnimation(.snappy) { month = now; selected = Calendar.current.startOfDay(for: .now) }
                }
                .font(.subheadline.weight(.semibold))
            }
            arrow("chevron.left") { move(-1) }
            arrow("chevron.right") { move(1) }
        }
    }

    private func arrow(_ symbol: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol).font(.subheadline.weight(.bold))
                .frame(width: 32, height: 32)
                .background(Color.omwCard2, in: Circle())
        }
        .buttonStyle(Pressable())
        .foregroundStyle(.primary)
    }

    private func move(_ by: Int) {
        guard let next = Calendar.current.date(byAdding: .month, value: by, to: month) else { return }
        direction = by
        withAnimation(.snappy(duration: 0.3)) {
            month = next
            // keep a day picked in the month you're looking at: today if it's there, else the 1st
            selected = Calendar.current.isDate(next, equalTo: .now, toGranularity: .month) ? Calendar.current.startOfDay(for: .now) : next
        }
    }

    private func cell(_ date: Date, _ day: Day?) -> some View {
        let cal = Calendar.current
        let n = cal.component(.day, from: date)
        let today = cal.isDateInToday(date)
        let isSelected = cal.isDate(date, inSameDayAs: selected)
        let photo = day?.photo ?? ""
        let ahead = day?.plans.contains { !$0.isOver } == true
        return Button {
            withAnimation(.snappy(duration: 0.2)) { selected = date }
        } label: {
            Color.omwCard2
                .aspectRatio(3 / 4, contentMode: .fit)
                .overlay { if !photo.isEmpty { RemoteImage(source: photo) } }
                .overlay(alignment: .topLeading) {
                    Text("\(n)").font(.caption2.weight(.bold))
                        .foregroundStyle(!photo.isEmpty ? Color.white : today ? Color.red : Color.primary)
                        .shadow(color: !photo.isEmpty ? .black.opacity(0.5) : .clear, radius: 2)
                        .padding(4)
                }
                .overlay(alignment: .bottom) {
                    if day?.plans.isEmpty == false, photo.isEmpty {
                        Circle().fill(ahead ? Color.sun : Color.omwBlue).frame(width: 6, height: 6).padding(5)
                    }
                }
                .clipShape(.rect(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isSelected ? Color.coral : .clear, lineWidth: 2.5))
                .opacity(day == nil && !isSelected ? 0.6 : 1)
        }
        .buttonStyle(Pressable())
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
    }

    // ---------- the day you tapped ----------
    @ViewBuilder private func dayDetail(_ day: Day) -> some View {
        let cal = Calendar.current
        VStack(alignment: .leading, spacing: 10) {
            Text(cal.isDateInToday(selected) ? "Today" : selected.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(.system(size: 17, weight: .heavy, design: .rounded))
            if !day.posts.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(day.posts) { p in
                            NavigationLink(value: PostRoute(id: p.id)) {
                                Color.omwCard2
                                    .frame(width: 110, height: 146)
                                    .overlay { RemoteImage(source: p.allPhotos.first ?? "") }
                                    .clipShape(.rect(cornerRadius: 12))
                                    .overlay(alignment: .bottomLeading) {
                                        Text(p.venueName.isEmpty ? p.title : p.venueName).font(.caption2.weight(.bold)).lineLimit(1)
                                            .foregroundStyle(.white).shadow(color: .black.opacity(0.6), radius: 2).padding(6)
                                    }
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
                Text(selected < cal.startOfDay(for: .now) ? "Nothing that day." : "Nothing planned yet.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if selected >= cal.startOfDay(for: .now) {
                Button { planningDay = selected } label: {
                    Label("Plan something \(cal.isDateInToday(selected) ? "today" : "on \(selected.formatted(.dateTime.weekday(.wide)))")",
                          systemImage: "plus")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.sun, in: .rect(cornerRadius: 12))
                        .foregroundStyle(.black)
                }
                .buttonStyle(Pressable())
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.omwCard, in: .rect(cornerRadius: 16))
    }

    private struct PlanDay: Identifiable {
        let date: Date
        var id: Date { date }
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
