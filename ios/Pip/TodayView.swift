import SwiftUI

struct TodayView: View {
    @Environment(PipStore.self) var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var logging: ActivityKind?
    @State private var editing: CareActivity?
    @State private var showStart = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(Date.now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())).font(.body.weight(.medium)).foregroundStyle(.secondary)
                            Text("\(store.baby?.name ?? "Baby")’s day").font(.largeTitle.bold())
                        }
                        Spacer()
                        Menu {
                            ForEach(store.babies) { baby in Button(baby.name) { store.selectedBabyId = baby.id; store.persist() } }
                        } label: { Image(systemName: "leaf.fill").font(.title2).padding(14).background(PipTheme.green.opacity(0.10), in: Circle()) }.accessibilityLabel("Choose baby")
                    }
                    SyncStatusView()
                    if let active = store.active { FeedCard(activity: active) }
                    else {
                        Card { VStack(alignment: .leading, spacing: 20) {
                            if let last = store.visibleActivities.first(where: { $0.kind != .pump && $0.endedAt != nil }) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Last feed").font(.title3.weight(.medium))
                                    Text(last.startDate, style: .relative).font(.title2.weight(.medium)) + Text(" ago").font(.title2.weight(.medium))
                                }
                            } else { Text("No feeds logged yet").font(.title3) }
                            PrimaryButton(title: "Start breastfeeding") { showStart = true }
                        } }
                    }
                    VStack(spacing: 12) {
                        quickAction("Log bottle", icon: "waterbottle.fill", color: PipTheme.peach) { logging = .bottle }
                        quickAction("Log pumping", icon: "drop.fill", color: PipTheme.green) { logging = .pump }
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
                            Button { editing = activity } label: { ActivityRow(activity: activity) }.buttonStyle(.plain)
                            if activity.id != store.today.last?.id { Divider().padding(.leading, 70) }
                        } }.padding(.horizontal, 16).background(PipTheme.card, in: RoundedRectangle(cornerRadius: 24))
                    }
                }.padding(22)
            }.background(PipTheme.background).toolbar(.hidden, for: .navigationBar)
                .refreshable { await store.refreshProfile(); await store.sync() }
                .confirmationDialog("Start on which side?", isPresented: $showStart, titleVisibility: .visible) {
                    Button("Left breast") { store.startFeed(side: .left) }; Button("Right breast") { store.startFeed(side: .right) }
                }
                .sheet(item: $logging) { kind in ActivityEditor(kind: kind) }
                .sheet(item: $editing) { activity in ActivityEditor(kind: activity.kind, existing: activity) }
        }
    }
    func quickAction(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon).font(.title2).foregroundStyle(color).frame(width: 28)
                Text(title).font(.title3.weight(.semibold)).foregroundStyle(.primary)
                Spacer(minLength: 0)
                Image(systemName: "plus").font(.title3.weight(.semibold)).foregroundStyle(PipTheme.green)
            }.padding(.horizontal, 20).padding(.vertical, 16).frame(minHeight: 64)
                .background(PipTheme.card, in: RoundedRectangle(cornerRadius: 20))
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
    @State private var finish = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 16) {
                HStack { Text(activity.paused ? "Feed paused" : "Feeding").font(.title3.weight(.semibold)); Spacer() }.foregroundStyle(PipTheme.green)
                VStack(spacing: 5) {
                    Text(CareActivity.clock(activity.total(at: context.date))).font(.system(size: timerSize, weight: .medium, design: .rounded)).minimumScaleFactor(0.65).lineLimit(1).monospacedDigit().contentTransition(.numericText())
                    Text("\(activity.side.title) breast").font(.title2.weight(.semibold))
                }
                (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 20))) {
                    side(.left, at: context.date); side(.right, at: context.date)
                }
                (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))) {
                    Button { control(.switchSide) } label: { Text("Switch to \(activity.side.other.rawValue)").frame(maxWidth: .infinity, minHeight: 56) }
                    Button { control(.pause) } label: { Label(activity.paused ? "Resume" : "Pause", systemImage: activity.paused ? "play.fill" : "pause.fill").frame(maxWidth: .infinity, minHeight: 56) }
                }.font(.title3.weight(.semibold)).buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 16))
                Button { finish = true } label: { Text("Finish feed").font(.title3.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 52) }.buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 16))
            }.padding(24).background(PipTheme.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 28))
        }.confirmationDialog("Finish this feed?", isPresented: $finish, titleVisibility: .visible) { Button("Finish and save") { control(.finish) } }
    }
    func side(_ side: BreastSide, at date: Date) -> some View {
        VStack(spacing: 4) {
            Text(side.title).font(.body.weight(.medium))
            Text(CareActivity.clock(activity.seconds(side, at: date))).font(.title3.weight(.medium).monospacedDigit())
        }.frame(maxWidth: .infinity)
    }
    func control(_ action: PipStore.FeedAction) { UIImpactFeedbackGenerator(style: .soft).impactOccurred(); Task { await store.controlFeed(id: activity.id, action: action) } }
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
                Text(activity.startDate, format: .dateTime.hour().minute()).font(.body).foregroundStyle(.secondary)
                if !activity.notes.isEmpty { Text(activity.notes).font(.body).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
        }.padding(.vertical, 16).contentShape(Rectangle())
    }
}
