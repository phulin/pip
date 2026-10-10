import SwiftUI

struct ActivityEditor: View {
    @Environment(PipStore.self) var store
    @Environment(\.dismiss) var dismiss
    var kind: ActivityKind
    var existing: CareActivity?
    var initialSide: BreastSide = .left
    var initialMilk = "breastMilk"
    @State private var side: BreastSide = .left
    @State private var start = Date()
    @State private var duration = 15.0
    @State private var left = 10.0
    @State private var right = 10.0
    @State private var volume = ""
    @State private var ounces = false
    @State private var milk = "breastMilk"
    @State private var notes = ""
    @State private var confirmDelete = false
    var volumeML: Double { (Double(volume.replacingOccurrences(of: ",", with: ".")) ?? 0) * (ounces ? 29.5735 : 1) }
    var valid: Bool { kind == .breast ? left + right > 0 : volumeML > 0 && volumeML <= 5000 }
    var body: some View {
        NavigationStack {
            Form {
                if let existing, existing.isRunning {
                    Section { FeedCard(activity: store.activities.first { $0.id == existing.id } ?? existing).listRowInsets(EdgeInsets()) }
                    Section { Text("Finish this activity before editing its times or notes.").foregroundStyle(.secondary) }
                } else {
                    Section("When") {
                        DatePicker("Started", selection: $start, in: ...Date())
                        if kind != .breast { Stepper("\(Int(duration)) minutes", value: $duration, in: 1...480, step: 1) }
                    }
                    if kind == .breast {
                        Section("Nursing time") {
                            Stepper("Left · \(Int(left)) min", value: $left, in: 0...240)
                            Stepper("Right · \(Int(right)) min", value: $right, in: 0...240)
                        }.onChange(of: left) { _, _ in duration = left + right }.onChange(of: right) { _, _ in duration = left + right }
                    } else {
                        Section(kind == .pump ? "Milk expressed" : "Bottle details") {
                            VStack(alignment: .leading, spacing: 12) {
                                TextField("Amount", text: $volume).keyboardType(.decimalPad).font(.largeTitle.weight(.medium)).frame(minHeight: 56).accessibilityLabel("Milk amount")
                                HStack(spacing: 12) {
                                    ForEach([false, true], id: \.self) { useOunces in
                                        Button { ounces = useOunces } label: {
                                            Text(useOunces ? "oz" : "mL").font(.title3.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                                        }.buttonStyle(.bordered).tint(ounces == useOunces ? PipTheme.green : .secondary)
                                            .accessibilityLabel(useOunces ? "Fluid ounces" : "Milliliters")
                                            .accessibilityAddTraits(ounces == useOunces ? .isSelected : [])
                                    }
                                }
                            }
                                .onChange(of: ounces) { old, new in
                                    if let value = Double(volume), value > 0 { volume = String(format: new ? "%.1f" : "%.0f", new ? value / 29.5735 : value * 29.5735) }
                                }
                            if kind == .bottle { Picker("Milk", selection: $milk) { Text("Breast milk").tag("breastMilk"); Text("Formula").tag("formula") } }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 12)], spacing: 12) {
                                ForEach(ounces ? [2, 3, 4, 5] : [30, 60, 90, 120], id: \.self) { amount in Button { volume = String(amount) } label: { Text("\(amount)").font(.title3.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 48) }.buttonStyle(.bordered) }
                            }
                        }
                    }
                    Section("Notes (optional)") { TextField("Add a note", text: $notes, axis: .vertical).lineLimit(3...6).onChange(of: notes) { _, value in if value.count > 2000 { notes = String(value.prefix(2000)) } } }
                    if existing != nil { Section { Button("Delete activity", role: .destructive) { confirmDelete = true } } }
                }
            }.navigationTitle(existing == nil ? "Log \(kind == .pump ? "pumping" : kind == .bottle ? "a bottle" : "a feed")" : "Activity details").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    if existing?.isRunning != true { ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.fontWeight(.semibold).disabled(!valid) } }
                }
                .onChange(of: store.activities.first(where: { $0.id == existing?.id })?.isRunning) { old, new in
                    if old == true && new == false { dismiss() }
                }
                .onAppear {
                    if let a = existing {
                        start = a.startDate; volume = String(format: "%.0f", a.volumeML); notes = a.notes; milk = a.milk; side = a.side
                        left = a.leftSeconds / 60; right = a.rightSeconds / 60
                        duration = a.kind == .breast ? left + right : max(1, a.total() > 0 ? a.total() / 60 : ((a.endedAt ?? a.startedAt) - a.startedAt) / 60000)
                    } else {
                        side = initialSide; milk = initialMilk
                    }
                }
                .confirmationDialog("Delete this activity for everyone in the family?", isPresented: $confirmDelete, titleVisibility: .visible) { Button("Delete activity", role: .destructive) { if let existing { store.delete(existing) }; dismiss() } }
        }
    }
    func save() {
        guard let baby = store.baby else { return }
        var a = existing ?? CareActivity(babyId: baby.id, kind: kind)
        a.startedAt = start.timeIntervalSince1970 * 1000
        a.endedAt = min(Date().timeIntervalSince1970 * 1000, a.startedAt + duration * 60000)
        a.leftSeconds = kind == .breast ? left * 60 : duration * 60; a.rightSeconds = kind == .breast ? right * 60 : 0; a.segmentStartedAt = nil; a.paused = true
        a.volumeML = volumeML; a.milk = milk; a.notes = notes; a.side = side
        store.save(a); UIImpactFeedbackGenerator(style: .light).impactOccurred(); dismiss()
    }
}
struct HistoryView: View {
    @Environment(PipStore.self) var store
    @State private var kind: ActivityKind?
    @State private var editing: CareActivity?
    @State private var logging = false
    @State private var search = ""
    var filtered: [CareActivity] { store.visibleActivities.filter { (kind == nil || $0.kind == kind) && (search.isEmpty || $0.notes.localizedCaseInsensitiveContains(search) || $0.kind.title.localizedCaseInsensitiveContains(search)) } }
    var days: [Date] { Set(filtered.map { Calendar.current.startOfDay(for: $0.startDate) }).sorted(by: >) }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Activity", selection: $kind) { Text("All").tag(nil as ActivityKind?); ForEach(ActivityKind.allCases) { Text($0.title).tag(Optional($0)) } }.pickerStyle(.segmented)
                    SyncStatusView()
                }.listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
                if filtered.isEmpty { ContentUnavailableView("No activities found", systemImage: "clock", description: Text("Log an activity or adjust your filters.")) }
                ForEach(days, id: \.self) { day in
                    Section(day.formatted(date: .abbreviated, time: .omitted)) {
                        ForEach(filtered.filter { Calendar.current.isDate($0.startDate, inSameDayAs: day) }) { activity in
                            Button { editing = activity } label: { ActivityRow(activity: activity) }.buttonStyle(.plain)
                        }
                    }
                }
            }.navigationTitle("History").searchable(text: $search, prompt: "Search notes and activities")
                .toolbar { Button { logging = true } label: { Image(systemName: "plus") }.accessibilityLabel("Log past activity") }
                .confirmationDialog("Log a past activity", isPresented: $logging, titleVisibility: .visible) { ForEach(ActivityKind.allCases) { kind in Button(kind.title) { editing = CareActivity(babyId: store.baby?.id ?? "", kind: kind, endedAt: Date().timeIntervalSince1970 * 1000, paused: true) } } }
                .sheet(item: $editing) { activity in ActivityEditor(kind: activity.kind, existing: store.activities.contains(where: { $0.id == activity.id }) ? activity : nil) }
                .refreshable { await store.sync() }
        }
    }
}
struct ConflictView: View {
    @Environment(PipStore.self) var store
    var body: some View {
        List {
            Section { Text("Another caregiver changed an activity while this iPhone was offline. Your version is saved here until you choose what to keep.") }
            ForEach(Array(store.conflicts.keys).sorted(), id: \.self) { id in
                Section {
                    if let a = store.activities.first(where: { $0.id == id }) { ActivityRow(activity: a) }
                    Text(store.conflicts[id] ?? "").font(.body).foregroundStyle(.secondary)
                    Button("Use the family’s version") { Task { await store.discardConflict(id) } }
                    Button("Retry with my version") { Task { do { try await store.keepConflict(id) } catch { store.error = error.localizedDescription } } }
                }
            }
        }.navigationTitle("Review changes")
    }
}
