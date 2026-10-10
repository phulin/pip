import Foundation
import ActivityKit

struct CareUser: Codable, Identifiable { var id: String; var email: String; var name: String }
struct Family: Codable, Identifiable { var id: String; var name: String; var role: String }
struct Baby: Codable, Identifiable, Hashable { var id: String; var name: String; var birthday: String }
struct Member: Codable, Identifiable { var id: String; var name: String; var role: String }
enum ActivityKind: String, Codable, CaseIterable { case breast, bottle, pump
    var title: String { switch self { case .breast: return "Breastfeed"; case .bottle: return "Bottle"; case .pump: return "Pumping" } }
    var icon: String { switch self { case .breast: return "heart.fill"; case .bottle: return "waterbottle.fill"; case .pump: return "drop.fill" } }
}
enum BreastSide: String, Codable, CaseIterable { case left, right
    var other: Self { self == .left ? .right : .left }
    var title: String { rawValue.capitalized }
}
struct CareActivity: Codable, Identifiable, Equatable {
    var id = UUID().uuidString.lowercased()
    var babyId: String
    var kind: ActivityKind
    var startedAt: Double = Date().timeIntervalSince1970 * 1000
    var endedAt: Double?
    var side: BreastSide = .left
    var leftSeconds: Double = 0
    var rightSeconds: Double = 0
    var segmentStartedAt: Double?
    var paused = false
    var volumeML: Double = 0
    var milk = "breastMilk"
    var notes = ""
    var deleted = false
    var revision = 0
    var mutationId = UUID().uuidString.lowercased()
    var createdBy: String?
    var controlAt: Double?
    var sideChangedAt: Double?
    var pauseChangedAt: Double?
    var volumeChangedAt: Double?
    var isRunning: Bool { endedAt == nil && !deleted }
    var startDate: Date { Date(timeIntervalSince1970: startedAt / 1000) }
    func seconds(_ side: BreastSide, at date: Date = .now) -> Double {
        let stored = side == .left ? leftSeconds : rightSeconds
        guard self.side == side, !paused, endedAt == nil, let segmentStartedAt else { return stored }
        return stored + max(0, date.timeIntervalSince1970 - segmentStartedAt / 1000)
    }
    func total(at date: Date = .now) -> Double { seconds(.left, at: date) + seconds(.right, at: date) }
    mutating func settle(at date: Date) {
        leftSeconds = seconds(.left, at: date)
        rightSeconds = seconds(.right, at: date)
        segmentStartedAt = nil
    }
    mutating func switchSide(at date: Date = .now) {
        settle(at: date); side = side.other
        if !paused { segmentStartedAt = date.timeIntervalSince1970 * 1000 }
    }
    mutating func togglePause(at date: Date = .now) {
        settle(at: date); paused.toggle()
        if !paused { segmentStartedAt = date.timeIntervalSince1970 * 1000 }
    }
    mutating func finish(at date: Date = .now) { settle(at: date); endedAt = date.timeIntervalSince1970 * 1000; paused = true }
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds)); return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
struct FeedAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var side: String
        var paused: Bool
        var elapsed: Double
        var timerStart: Date
        var leftSeconds: Double
        var rightSeconds: Double
    }
    var activityId: String
    var babyName: String
}

struct ActivityCommand: Codable, Identifiable {
    var id = UUID().uuidString.lowercased()
    var activityId: String
    var occurredAt = Date().timeIntervalSince1970 * 1000
    var side: BreastSide?
    var paused: Bool?
    var finish: Bool?
    var volumeML: Double?
    func applying(to original: CareActivity) -> CareActivity {
        var a = original
        guard a.isRunning else { return a }
        let time = max(a.segmentStartedAt ?? a.startedAt, a.controlAt ?? a.startedAt, occurredAt)
        let date = Date(timeIntervalSince1970: time / 1000)
        let changeSide = a.kind == .breast && side != nil && side != a.side && occurredAt >= (a.sideChangedAt ?? a.startedAt)
        let changePause = paused != nil && paused != a.paused && occurredAt >= (a.pauseChangedAt ?? a.startedAt)
        if changeSide || changePause || finish == true {
            if changeSide { a.switchSide(at: date); a.sideChangedAt = occurredAt }
            if changePause { a.togglePause(at: date); a.pauseChangedAt = occurredAt }
            if finish == true { a.finish(at: date) }
            a.controlAt = time
        }
        if let volumeML, occurredAt >= (a.volumeChangedAt ?? a.startedAt) { a.volumeML = volumeML; a.volumeChangedAt = occurredAt }
        return a
    }
}
