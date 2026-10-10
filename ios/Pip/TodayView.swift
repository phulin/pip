import SwiftUI

struct TodayView: View {
    @Environment(PipStore.self) var store
    @State private var logging: ActivityKind?
    @State private var editing: CareActivity?
    @State private var showStart = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(Date.now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()).uppercased()).font(.caption.weight(.semibold)).tracking(1.4).foregroundStyle(.secondary)
                            Text("\(store.baby?.name ?? "Baby")’s day").font(.system(size: 35, weight: .semibold, design: .serif))
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
                            HStack { Label("A moment to connect", systemImage: "heart").font(.subheadline.weight(.medium)); Spacer(); Image(systemName: "sparkle").foregroundStyle(PipTheme.peach) }
                            if let last = store.visibleActivities.first(where: { $0.kind != .pump && $0.endedAt != nil }) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Last feed").foregroundStyle(.secondary).font(.caption)
                                    Text(last.startDate, style: .relative).font(.title2.weight(.medium)) + Text(" ago").font(.title2.weight(.medium))
                                }
                            } else { Text("One feed at a time.\nYou’re doing beautifully.").font(.title2.weight(.medium)).lineSpacing(3) }
                            PrimaryButton(title: "Start breastfeeding") { showStart = true }
                        } }
                    }
                    HStack(spacing: 14) {
                        quickAction("Log bottle", subtitle: "Milk or formula", icon: "waterbottle.fill", color: PipTheme.peach) { logging = .bottle }
                        quickAction("Log pumping", subtitle: "Every drop counts", icon: "drop.fill", color: PipTheme.green) { logging = .pump }
                    }
                    HStack(spacing: 0) {
                        stat("FEEDS", value: "\(store.today.filter { $0.kind != .pump }.count)")
                        Divider().frame(height: 34)
                        stat("NURSING", value: "\(Int(store.today.filter { $0.kind == .breast }.reduce(0) { $0 + $1.total() } / 60)) min")
                        Divider().frame(height: 34)
                        stat("PUMPED", value: "\(Int(store.today.filter { $0.kind == .pump }.reduce(0) { $0 + $1.volumeML })) mL")
                    }.padding(.vertical, 8)
                    HStack { Text("Today’s little moments").font(.title3.weight(.semibold)); Spacer(); Text("\(store.today.count)").foregroundStyle(.secondary) }
                    if store.today.isEmpty {
                        Card { VStack(spacing: 12) { Image(systemName: "sun.horizon").font(.largeTitle).foregroundStyle(PipTheme.peach); Text("A fresh little page").font(.headline); Text("Your feeds and pumping sessions will appear here.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center) }.frame(maxWidth: .infinity).padding(.vertical, 14) }
                    } else {
                        VStack(spacing: 0) { ForEach(store.today) { activity in
                            Button { editing = activity } label: { ActivityRow(activity: activity) }.buttonStyle(.plain)
                            if activity.id != store.today.last?.id { Divider().padding(.leading, 70) }
                        } }.padding(.horizontal, 16).background(PipTheme.card, in: RoundedRectangle(cornerRadius: 24))
                    }
                    Text("A little care, beautifully shared.").font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.vertical, 8)
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
    func quickAction(_ title: String, subtitle: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) { VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 4) { Text(title).font(.subheadline.bold()).foregroundStyle(.primary); Text(subtitle).font(.caption2).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18).background(PipTheme.card, in: RoundedRectangle(cornerRadius: 24)) }.buttonStyle(.plain)
    }
    func stat(_ label: String, value: String) -> some View { VStack(spacing: 7) { Text(value).font(.title3.weight(.semibold).monospacedDigit()); Text(label).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.secondary) }.frame(maxWidth: .infinity) }
}
extension ActivityKind: Identifiable { var id: String { rawValue } }
struct SyncStatusView: View {
    @Environment(PipStore.self) var store
    var body: some View {
        if !store.conflicts.isEmpty {
            NavigationLink { ConflictView() } label: { Label("\(store.conflicts.count) changes need a look", systemImage: "exclamationmark.arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.orange) }
        } else if !store.online || !store.pending.isEmpty || store.syncMessage != nil {
            Button { Task { await store.sync() } } label: {
                Label(!store.online ? "Offline · saved on this iPhone" : store.syncMessage != nil ? "Sync needs attention · tap to retry" : "\(store.pending.count) changes waiting to sync", systemImage: "icloud.and.arrow.up").font(.caption).foregroundStyle(.secondary)
            }.accessibilityHint(store.syncMessage ?? "")
        }
    }
}
struct FeedCard: View {
    @Environment(PipStore.self) var store
    let activity: CareActivity
    @State private var finish = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 22) {
                HStack { Circle().fill(activity.paused ? .orange : PipTheme.green).frame(width: 7, height: 7); Text(activity.paused ? "TAKING A BREATHER" : "FEED IN PROGRESS").font(.caption.weight(.semibold)).tracking(1.2); Spacer(); Image(systemName: "heart.fill") }.foregroundStyle(PipTheme.green)
                VStack(spacing: 5) {
                    Text(CareActivity.clock(activity.total(at: context.date))).font(.system(size: 58, weight: .light, design: .rounded)).monospacedDigit().contentTransition(.numericText())
                    Text("\(activity.side.title) breast\(activity.paused ? " · paused" : "")").font(.subheadline).foregroundStyle(.secondary)
                }
                HStack { side(.left, at: context.date); Spacer(); side(.right, at: context.date) }.padding(.horizontal, 32)
                HStack(spacing: 12) {
                    Button { control(.switchSide) } label: { Label("Switch", systemImage: "arrow.left.arrow.right").frame(maxWidth: .infinity).padding(.vertical, 10) }
                    Button { control(.pause) } label: { Label(activity.paused ? "Resume" : "Pause", systemImage: activity.paused ? "play.fill" : "pause.fill").frame(maxWidth: .infinity).padding(.vertical, 10) }
                }.buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 16))
                Button("Finish feed") { finish = true }.font(.subheadline.weight(.semibold)).padding(.vertical, 4)
            }.padding(24).background(PipTheme.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 28))
        }.confirmationDialog("Finish this feed?", isPresented: $finish, titleVisibility: .visible) { Button("Finish and save") { control(.finish) } }
    }
    func side(_ side: BreastSide, at date: Date) -> some View { HStack(spacing: 7) { Text(side == .left ? "L" : "R").font(.caption.bold()).padding(7).background(activity.side == side ? PipTheme.green.opacity(0.15) : Color.secondary.opacity(0.08), in: Circle()); Text(CareActivity.clock(activity.seconds(side, at: date))).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary) } }
    func control(_ action: PipStore.FeedAction) { UIImpactFeedbackGenerator(style: .soft).impactOccurred(); Task { await store.controlFeed(id: activity.id, action: action) } }
}
struct ActivityRow: View {
    @Environment(PipStore.self) var store
    let activity: CareActivity
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: activity.kind.icon).font(.title3).foregroundStyle(activity.kind == .bottle ? PipTheme.peach : PipTheme.green).frame(width: 42, height: 46).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 15))
            VStack(alignment: .leading, spacing: 5) {
                HStack { Text(activity.kind.title).font(.subheadline.weight(.semibold)); if store.pending.contains(activity.id) { Image(systemName: "icloud.and.arrow.up").font(.caption2).foregroundStyle(.secondary) } }
                Text(activity.kind == .breast ? "\(Int(activity.total() / 60)) min · \(activity.isRunning ? "in progress" : "L \(Int(activity.leftSeconds / 60)) / R \(Int(activity.rightSeconds / 60))")" : "\(Int(activity.volumeML)) mL\(activity.kind == .bottle ? (activity.milk == "formula" ? " · Formula" : " · Breast milk") : "")").font(.caption).foregroundStyle(.secondary)
                if !activity.notes.isEmpty { Text(activity.notes).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            Text(activity.startDate, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 16).contentShape(Rectangle())
    }
}
