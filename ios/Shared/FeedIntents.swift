import AppIntents

struct SwitchBreastIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Switch breast"
    static var openAppWhenRun = false
    @Parameter(title: "Feed ID") var activityId: String
    @Parameter(title: "Target right breast") var targetRight: Bool
    init() {}
    init(activityId: String, targetRight: Bool) { self.activityId = activityId; self.targetRight = targetRight }
    func perform() async throws -> some IntentResult {
        #if !APP_EXTENSION
        await PipStore.shared.controlFromLiveActivity(id: activityId, side: targetRight ? .right : .left)
        #endif
        return .result()
    }
}
struct PauseFeedIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Pause or resume feed"
    static var openAppWhenRun = false
    @Parameter(title: "Feed ID") var activityId: String
    @Parameter(title: "Pause") var targetPaused: Bool
    init() {}
    init(activityId: String, targetPaused: Bool) { self.activityId = activityId; self.targetPaused = targetPaused }
    func perform() async throws -> some IntentResult {
        #if !APP_EXTENSION
        await PipStore.shared.controlFromLiveActivity(id: activityId, paused: targetPaused)
        #endif
        return .result()
    }
}
