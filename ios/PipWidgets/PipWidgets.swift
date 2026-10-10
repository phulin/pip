import ActivityKit
import WidgetKit
import SwiftUI

@main struct PipWidgetBundle: WidgetBundle { var body: some Widget { FeedLiveActivity() } }
struct FeedLiveActivity: Widget {
    private let green = Color(red: 0.22, green: 0.40, blue: 0.32)
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FeedAttributes.self) { context in
            VStack(spacing: 14) {
                HStack {
                    Image(systemName: "leaf.fill").foregroundStyle(green)
                    VStack(alignment: .leading, spacing: 3) { Text("\(context.attributes.babyName)’s feed").font(.headline); Text("\(context.state.side) breast\(context.state.paused ? " · paused" : "")").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    timer(context.state).font(.system(size: 32, weight: .light, design: .rounded)).monospacedDigit().frame(maxWidth: 130, alignment: .trailing)
                }
                HStack(spacing: 12) {
                    Button(intent: SwitchBreastIntent(activityId: context.attributes.activityId)) { Label("Switch breast", systemImage: "arrow.left.arrow.right").frame(maxWidth: .infinity) }
                    Button(intent: PauseFeedIntent(activityId: context.attributes.activityId)) { Label(context.state.paused ? "Resume" : "Pause", systemImage: context.state.paused ? "play.fill" : "pause.fill").frame(maxWidth: .infinity) }
                }.buttonStyle(.bordered).tint(green)
            }.padding(18).activityBackgroundTint(Color(uiColor: .secondarySystemBackground)).activitySystemActionForegroundColor(green)
                .widgetURL(URL(string: "pipbaby://feed"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Label(context.attributes.babyName, systemImage: "heart.fill").font(.headline).foregroundStyle(.mint) }
                DynamicIslandExpandedRegion(.trailing) { timer(context.state).font(.title2.monospacedDigit()).frame(width: 95) }
                DynamicIslandExpandedRegion(.center) { Text("\(context.state.side) breast").font(.caption).foregroundStyle(.secondary) }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Button(intent: SwitchBreastIntent(activityId: context.attributes.activityId)) { Label("Switch", systemImage: "arrow.left.arrow.right").frame(maxWidth: .infinity) }
                        Button(intent: PauseFeedIntent(activityId: context.attributes.activityId)) { Label(context.state.paused ? "Resume" : "Pause", systemImage: context.state.paused ? "play.fill" : "pause.fill").frame(maxWidth: .infinity) }
                    }.buttonStyle(.bordered).tint(.mint)
                }
            } compactLeading: { Image(systemName: context.state.paused ? "pause.fill" : "heart.fill").foregroundStyle(.mint) }
            compactTrailing: { timer(context.state).monospacedDigit().frame(width: 55).font(.caption) }
            minimal: { Image(systemName: context.state.paused ? "pause.fill" : "heart.fill").foregroundStyle(.mint) }
            .widgetURL(URL(string: "pipbaby://feed"))
        }
    }
    @ViewBuilder private func timer(_ state: FeedAttributes.ContentState) -> some View {
        if state.paused { Text(CareActivity.clock(state.elapsed)) }
        else { Text(timerInterval: state.timerStart...Date.distantFuture, countsDown: false) }
    }
}
