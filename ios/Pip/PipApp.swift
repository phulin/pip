import SwiftUI

@main struct PipApp: App {
    @State private var store = PipStore.shared
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            RootView().environment(store).tint(PipTheme.green).font(.title3).controlSize(.large)
                .task { await store.start() }
                .task(id: scenePhase) {
                    store.setForeground(scenePhase == .active)
                    guard scenePhase == .active else { store.persist(); return }
                    await store.refreshProfile()
                    while !Task.isCancelled {
                        store.persist()
                        await store.sync()
                        try? await Task.sleep(for: .seconds(8))
                        if Task.isCancelled { break }
                    }
                }
                .onOpenURL { url in
                    guard url.scheme == "pipbaby" else { return }
                    let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value ?? ""
                    if url.host == "join" { store.inviteCode = code }
                    if url.host == "reset" { NotificationCenter.default.post(name: .init("pip.reset"), object: code) }
                }
        }
    }
}
enum PipTheme {
    static let green = Color("AccentColor")
    static let background = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .systemGroupedBackground : UIColor(red: 0.965, green: 0.960, blue: 0.940, alpha: 1)
    })
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let peach = Color(red: 0.90, green: 0.66, blue: 0.48)
}
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { content.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(PipTheme.card, in: RoundedRectangle(cornerRadius: 26)) }
}
struct PrimaryButton: View {
    var title: String; var busy = false; var action: () -> Void
    var body: some View {
        Button(action: action) { HStack { Spacer(); if busy { ProgressView().tint(.white) } else { Text(title).font(.title3.weight(.semibold)) }; Spacer() }.frame(minHeight: 40).padding(.vertical, 8) }
            .buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 18)).disabled(busy)
    }
}
struct RootView: View {
    @Environment(PipStore.self) var store
    var body: some View {
        @Bindable var store = store
        Group {
            if store.user == nil || store.sessionExpired { AuthView() }
            else if store.family == nil { FamilySetupView() }
            else {
                TabView {
                    TodayView().tabItem { Label("Today", systemImage: "sun.max") }
                    HistoryView().tabItem { Label("History", systemImage: "clock") }
                    FamilyView().tabItem { Label("Family", systemImage: "person.2") }
                }
            }
        }
        .alert("Unable to complete action", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
    }
}
