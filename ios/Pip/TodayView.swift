import SwiftUI

struct TodayView: View {
    @Environment(PipStore.self) var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var editing: CareActivity?
    @ScaledMetric(relativeTo: .title3) private var actionWidth = 170.0
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                TimelineView(.periodic(from: .now, by: 60)) { context in
                                    Text(dateAndAge(at: context.date))
                                        .font(.body.weight(.medium)).foregroundStyle(.secondary)
                                }
                                Text("\(store.baby?.name ?? "Baby")’s day").font(.largeTitle.bold())
                            }
                            Spacer()
                            Menu {
                                ForEach(store.babies) { baby in Button(baby.name) { store.selectedBabyId = baby.id; store.persist() } }
                            } label: { Image(systemName: "leaf.fill").font(.title2).padding(14).background(PipTheme.green.opacity(0.10), in: Circle()) }.accessibilityLabel("Choose baby")
                        }
                        if !store.visibleActivities.contains(where: { $0.isRunning }) {
                            Group {
                                if let last = store.visibleActivities.first(where: { $0.kind != .pump && $0.endedAt != nil }) {
                                    TimelineView(.periodic(from: .now, by: 60)) { context in
                                        Text("Last feed · \(elapsedSince(last.startDate, at: context.date))")
                                            .font(.title3.weight(.medium))
                                            .lineLimit(1).minimumScaleFactor(0.8)
                                    }
                                } else { Text("No feeds logged yet").font(.title3) }
                            }.foregroundStyle(.secondary)
                        }
                    }
                    ForEach(store.visibleActivities.filter { $0.isRunning }) { activity in
                        FeedCard(activity: activity)
                    }
                    VStack(spacing: 12) {
                        if store.active == nil {
                            LazyVGrid(columns: actionColumns, spacing: 12) {
                                quickAction("Feed Left", icon: "heart.fill", color: PipTheme.green) { store.startFeed(side: .left) }
                                quickAction("Feed Right", icon: "heart.fill", color: PipTheme.green) { store.startFeed(side: .right) }
                            }
                        }
                        if !store.visibleActivities.contains(where: { $0.kind == .pump && $0.isRunning }) {
                            quickAction("Pump", icon: "drop.fill", color: PipTheme.green) { store.startTracking(kind: .pump) }
                        }
                        if !store.visibleActivities.contains(where: { $0.kind == .bottle && $0.isRunning }) {
                            LazyVGrid(columns: actionColumns, spacing: 12) {
                                quickAction("Breastmilk", icon: "waterbottle.fill", color: PipTheme.peach) { store.startTracking(kind: .bottle) }
                                quickAction("Formula", icon: "waterbottle.fill", color: PipTheme.peach) { store.startTracking(kind: .bottle, milk: "formula") }
                            }
                        }
                    }
                    (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 16)) : AnyLayout(HStackLayout(spacing: 12))) {
                        stat("Feeds", value: "\(store.today.filter { $0.kind != .pump }.count)")
                        stat("Nursing", value: "\(Int(store.today.filter { $0.kind == .breast }.reduce(0) { $0 + $1.total() } / 60)) min")
                        stat("Pumped", value: "\(Int(store.today.filter { $0.kind == .pump }.reduce(0) { $0 + $1.volumeML })) mL")
                    }.padding(.vertical, 8)
                    HStack { Text("Today’s activities").font(.title3.weight(.semibold)); Spacer(); Text("\(store.today.count)").foregroundStyle(.secondary) }
                    if store.today.isEmpty {
                        Card { VStack(spacing: 12) { Image(systemName: "sun.horizon").font(.largeTitle).foregroundStyle(PipTheme.peach); Text("No activities today").font(.title3.weight(.semibold)); Text("Your feeds and pumping sessions will appear here.").font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center) }.frame(maxWidth: .infinity).padding(.vertical, 14) }
                    } else {
                        VStack(spacing: 0) { ForEach(store.today) { activity in
                            Button { editing = activity } label: { ActivityTimelineRow(activity: activity) }.buttonStyle(.plain)
                        } }
                    }
                    SyncStatusView()
                }.padding(22)
            }.background(PipTheme.background).toolbar(.hidden, for: .navigationBar)
                .refreshable { await store.refreshProfile(); await store.sync() }
                .sheet(item: $editing) { activity in ActivityEditor(kind: activity.kind, existing: activity) }
        }
    }
    private func elapsedSince(_ start: Date, at date: Date) -> String {
        let minutes = max(0, Int(date.timeIntervalSince(start) / 60))
        if minutes == 0 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 {
            let remainder = minutes % 60
            return "\(hours) hr" + (remainder > 0 ? " \(remainder) min" : "") + " ago"
        }
        let days = hours / 24
        return "\(days) \(days == 1 ? "day" : "days") ago"
    }
    private var actionColumns: [GridItem] {
        [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 300 : actionWidth), spacing: 12)]
    }
    private func dateAndAge(at date: Date) -> String {
        let heading = date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        guard let birthday = store.baby?.birthday else { return heading }
        let calendar = Calendar(identifier: .gregorian)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        guard let birthDate = formatter.date(from: birthday),
              let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: birthDate), to: calendar.startOfDay(for: date)).day,
              days >= 0 else { return heading }
        return "\(heading) • \(days / 7)w \(days % 7)d"
    }
    func quickAction(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.title2).foregroundStyle(color)
                Text(title).font(.title3.weight(.semibold)).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16).frame(minHeight: 76)
                .background(PipTheme.card, in: RoundedRectangle(cornerRadius: 20))
                .contentShape(RoundedRectangle(cornerRadius: 20))
        }.buttonStyle(.plain)
    }
    func stat(_ label: String, value: String) -> some View {
        VStack(spacing: 6) {
            Text(value).font(.title2.weight(.semibold).monospacedDigit())
            Text(label).font(.body)
        }.frame(maxWidth: .infinity)
    }
}
extension ActivityKind: Identifiable { var id: String { rawValue } }
struct SyncStatusView: View {
    @Environment(PipStore.self) var store
    var body: some View {
        if !store.conflicts.isEmpty {
            NavigationLink { ConflictView() } label: { Label("\(store.conflicts.count) changes need review", systemImage: "exclamationmark.arrow.triangle.2.circlepath").font(.body).foregroundStyle(.orange) }
        } else if !store.online || !store.pending.isEmpty || store.syncMessage != nil {
            Button { Task { await store.sync() } } label: {
                Label(!store.online ? "Offline · saved on this iPhone" : store.syncMessage != nil ? "Sync needs attention · tap to retry" : "\(store.pending.count) changes waiting to sync", systemImage: "icloud.and.arrow.up").font(.body).foregroundStyle(.secondary)
            }.accessibilityHint(store.syncMessage ?? "")
        }
    }
}
struct FeedCard: View {
    @Environment(PipStore.self) var store
    let activity: CareActivity
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var timerSize = 64.0
    @State private var ounces = false
    private var unit: Double { ounces ? 29.5735 : 1 }
    private var title: String {
        activity.kind == .breast ? "Feeding" : activity.kind == .pump ? "Pumping" : activity.milk == "formula" ? "Formula" : "Breastmilk"
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 16) {
                HStack { Text(title + (activity.paused ? " · Paused" : "")).font(.title3.weight(.semibold)); Spacer() }.foregroundStyle(PipTheme.green)
                VStack(spacing: 5) {
                    Text(CareActivity.clock(activity.total(at: context.date))).font(.system(size: timerSize, weight: .medium, design: .rounded)).minimumScaleFactor(0.65).lineLimit(1).monospacedDigit().contentTransition(.numericText())
                    if activity.kind == .breast { Text("\(activity.side.title) breast").font(.title2.weight(.semibold)) }
                }
                if activity.kind == .breast {
                    (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 20))) {
                        side(.left, at: context.date); side(.right, at: context.date)
                    }
                } else {
                    VStack(spacing: 12) {
                        Text(activity.kind == .pump ? "Milk expressed" : "Milk consumed").font(.title3)
                        HStack(spacing: 8) {
                            Button { store.setVolume(id: activity.id, volume: activity.volumeML - (ounces ? unit : 10)) } label: {
                                Image(systemName: "minus").frame(width: 32, height: 44)
                            }.accessibilityLabel(ounces ? "Decrease amount by one ounce" : "Decrease amount by 10 milliliters")
                            TextField("Amount", value: Binding(get: { activity.volumeML / unit }, set: { store.setVolume(id: activity.id, volume: $0 * unit) }), format: .number.precision(.fractionLength(0...1)))
                                .keyboardType(.decimalPad).multilineTextAlignment(.center).font(.title.bold())
                                .accessibilityLabel(ounces ? "Milk amount in ounces" : "Milk amount in milliliters")
                            Text(ounces ? "oz" : "mL").font(.title3)
                            Button { store.setVolume(id: activity.id, volume: activity.volumeML + (ounces ? unit : 10)) } label: {
                                Image(systemName: "plus").frame(width: 32, height: 44)
                            }.accessibilityLabel(ounces ? "Increase amount by one ounce" : "Increase amount by 10 milliliters")
                        }.buttonStyle(.bordered)
                        Picker("Amount unit", selection: $ounces) {
                            Text("mL").tag(false)
                            Text("oz").tag(true)
                        }.pickerStyle(.segmented)
                    }
                }
                (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))) {
                    if activity.kind == .breast {
                        Button { control(.switchSide) } label: {
                            Text(activity.side == .left ? "L → R" : "R → L")
                                .monospaced().lineLimit(1)
                                .frame(maxWidth: .infinity, minHeight: 56)
                        }.accessibilityLabel("Switch to \(activity.side.other.rawValue) breast")
                    }
                    Button { control(.pause) } label: { Label(activity.paused ? "Resume" : "Pause", systemImage: activity.paused ? "play.fill" : "pause.fill").frame(maxWidth: .infinity, minHeight: 56) }
                }.font(.title2.weight(.semibold)).buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 16))
                Button { control(.finish) } label: { Text(activity.kind == .pump ? "Finish pumping" : activity.kind == .bottle ? "Finish bottle" : "Finish feed").font(.title3.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 52) }.buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 16))
            }.padding(24).background(PipTheme.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 28))
        }
    }
    func side(_ side: BreastSide, at date: Date) -> some View {
        VStack(spacing: 4) {
            Text(side.title).font(.body.weight(.medium))
            Text(CareActivity.clock(activity.seconds(side, at: date))).font(.title3.weight(.medium).monospacedDigit())
        }.frame(maxWidth: .infinity)
    }
    func control(_ action: PipStore.FeedAction) { UIImpactFeedbackGenerator(style: .soft).impactOccurred(); Task { await store.controlFeed(id: activity.id, action: action) } }
}
struct ActivityTimelineRow: View {
    let activity: CareActivity
    @ScaledMetric(relativeTo: .title3) private var timeWidth = 100.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(activity.startDate, format: .dateTime.hour().minute())
                    .monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: timeWidth, alignment: .leading)
                Text(description(at: context.date))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .font(.title3)
            .padding(.vertical, 12)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
        }
    }

    private func description(at date: Date) -> String {
        switch activity.kind {
        case .breast: return "Breastfeed \(Int(activity.total(at: date) / 60)) min"
        case .pump: return "Pump \(Int(activity.volumeML)) mL"
        case .bottle: return "Bottle \(Int(activity.volumeML)) mL"
        }
    }
}

struct ActivityRow: View {
    @Environment(PipStore.self) var store
    let activity: CareActivity
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: activity.kind.icon).font(.title3).foregroundStyle(activity.kind == .bottle ? PipTheme.peach : PipTheme.green).frame(width: 42, height: 46).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 15))
            VStack(alignment: .leading, spacing: 5) {
                HStack { Text(activity.kind.title).font(.title3.weight(.semibold)); if store.pending.contains(activity.id) { Image(systemName: "icloud.and.arrow.up").font(.body).foregroundStyle(.secondary) } }
                Text(activity.kind == .breast ? "\(Int(activity.total() / 60)) min · \(activity.isRunning ? "in progress" : "L \(Int(activity.leftSeconds / 60)) / R \(Int(activity.rightSeconds / 60))")" : "\(Int(activity.volumeML)) mL\(activity.kind == .bottle ? (activity.milk == "formula" ? " · Formula" : " · Breast milk") : "")").font(.body).foregroundStyle(.secondary)
                if activity.kind != .breast {
                    Text("\(Int(activity.total() / 60)) min" + (activity.isRunning ? " · in progress" : "")).font(.body).foregroundStyle(.secondary)
                }
                Text(activity.startDate, format: .dateTime.hour().minute()).font(.body).foregroundStyle(.secondary)
                if !activity.notes.isEmpty { Text(activity.notes).font(.body).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
        }.padding(.vertical, 16).contentShape(Rectangle())
    }
}
