import AppIntents

struct SwitchBreastIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Switch breast"
    static var openAppWhenRun = false
    @Parameter(title: "Feed ID") var activityId: String
    init() {}
    init(activityId: String) { self.activityId = activityId }
    func perform() async throws -> some IntentResult {
        #if !APP_EXTENSION
        await PipStore.shared.controlFeed(id: activityId, action: .switchSide)
        #endif
        return .result()
    }
}
struct PauseFeedIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Pause or resume feed"
    static var openAppWhenRun = false
    @Parameter(title: "Feed ID") var activityId: String
    init() {}
    init(activityId: String) { self.activityId = activityId }
    func perform() async throws -> some IntentResult {
        #if !APP_EXTENSION
        await PipStore.shared.controlFeed(id: activityId, action: .pause)
        #endif
        return .result()
    }
}
