import SwiftUI
import ActivityKit
import Network

@MainActor @Observable final class PipStore {
    static let shared = PipStore()
    var user: CareUser?
    var family: Family?
    var babies: [Baby] = []
    var activities: [CareActivity] = []
    var selectedBabyId: String = ""
    var pending: Set<String> = []
    var conflicts: [String: String] = [:]
    var error: String?
    var syncMessage: String?
    var syncing = false
    var online = true
    var sessionExpired = false
    var inviteCode = ""
    private var token: String?
    private var monitor: NWPathMonitor?
    var baby: Baby? { babies.first { $0.id == selectedBabyId } ?? babies.first }
    var visibleActivities: [CareActivity] { activities.filter { !$0.deleted && $0.babyId == baby?.id }.sorted { $0.startedAt > $1.startedAt } }
    var active: CareActivity? { visibleActivities.first { $0.isRunning } }
    var today: [CareActivity] { visibleActivities.filter { Calendar.current.isDateInToday($0.startDate) } }
    private struct Cache: Codable {
        var user: CareUser?; var family: Family?; var babies: [Baby]; var activities: [CareActivity]
        var selectedBabyId: String; var pending: Set<String>; var conflicts: [String: String]
    }
    private var cacheURL: URL { URL.applicationSupportDirectory.appendingPathComponent("pip-cache.json") }
    init() {
        token = Keychain.read()
        if let data = try? Data(contentsOf: cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from: data) {
            user = cache.user; family = cache.family; babies = cache.babies; activities = cache.activities
            selectedBabyId = cache.selectedBabyId; pending = cache.pending; conflicts = cache.conflicts
        }
        sessionExpired = user != nil && token == nil
    }
    func start() async {
        if monitor == nil {
            let m = NWPathMonitor()
            m.pathUpdateHandler = { [weak self] path in Task { @MainActor in
                self?.online = path.status == .satisfied
                if path.status == .satisfied { await self?.sync() }
            } }
            m.start(queue: DispatchQueue(label: "pip.network")); monitor = m
        }
        await refreshProfile(); await sync()
    }
    func persist() {
        do {
            try FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Cache(user: user, family: family, babies: babies, activities: activities, selectedBabyId: selectedBabyId, pending: pending, conflicts: conflicts))
            try data.write(to: cacheURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { self.error = "Could not save on this device. Please free up storage before closing Pip." }
    }
    func authenticate(email: String, password: String, name: String, registering: Bool) async throws {
        let response: SessionResponse = try await API.request(registering ? "auth/register" : "auth/login", method: "POST", body: API.data(["email": email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), "password": password, "name": name]))
        try Keychain.save(response.token)
        if user?.id != response.user.id { clearCache() }
        token = response.token; user = response.user; sessionExpired = false; persist()
        await refreshProfile(); await sync()
    }
    func refreshProfile() async {
        guard token != nil else { return }
        do {
            let result: MeResponse = try await API.request("v1/me", token: token)
            user = result.user
            if family?.id != result.family?.id {
                activities = []; pending = []; conflicts = [:]; babies = []; selectedBabyId = ""
                await endLiveActivities()
            }
            family = result.family
            if family != nil {
                let result: BabyResponse = try await API.request("v1/family/babies", token: token)
                babies = result.babies
                if !babies.contains(where: { $0.id == selectedBabyId }) { selectedBabyId = babies.first?.id ?? "" }
            }
            persist()
        } catch { handle(error) }
    }
    func createFamily(name: String, babyName: String, birthday: Date) async throws {
        let _: Family = try await API.request("v1/families", method: "POST", body: API.data(["name": name, "babyName": babyName, "birthday": Self.day(birthday)]), token: token)
        await refreshProfile()
    }
    func join(code: String) async throws {
        let _: OK = try await API.request("v1/join", method: "POST", body: API.data(["code": code.trimmingCharacters(in: .whitespacesAndNewlines)]), token: token)
        inviteCode = ""; await refreshProfile(); await sync()
    }
    func invite(email: String) async throws {
        let _: OK = try await API.request("v1/family/invites", method: "POST", body: API.data(["email": email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]), token: token)
    }
    func members() async throws -> [Member] {
        let response: MembersResponse = try await API.request("v1/family/members", token: token); return response.members
    }
    func removeMember(_ id: String) async throws {
        let _: OK = try await API.request("v1/family/members/\(id)", method: "DELETE", token: token)
        if id == user?.id { await refreshProfile() }
    }
    func addBaby(name: String, birthday: Date) async throws {
        let result: Baby = try await API.request("v1/family/babies", method: "POST", body: API.data(["name": name, "birthday": Self.day(birthday)]), token: token)
        babies.append(result); selectedBabyId = result.id; persist()
    }
    func changePassword(current: String, new: String) async throws {
        let result: SessionResponse = try await API.request("v1/password", method: "POST", body: API.data(["currentPassword": current, "password": new]), token: token)
        try Keychain.save(result.token); token = result.token
    }
    func deleteAccount(password: String) async throws {
        let _: OK = try await API.request("v1/account", method: "DELETE", body: API.data(["password": password]), token: token)
        await signOut(localOnly: true)
    }
    func signOut(localOnly: Bool = false) async {
        if !localOnly {
            do { let _: OK = try await API.request("v1/logout", method: "POST", token: token) }
            catch { self.error = "Could not sign out securely. Reconnect and try again."; return }
        }
        try? Keychain.save(nil); token = nil; await endLiveActivities(); clearCache(); persist()
    }
    private func clearCache() { user = nil; family = nil; babies = []; activities = []; pending = []; conflicts = [:]; selectedBabyId = ""; sessionExpired = false }
    static func day(_ date: Date) -> String { let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; return formatter.string(from: date) }
    func save(_ activity: CareActivity) {
        var a = activity; a.mutationId = UUID().uuidString.lowercased()
        if let i = activities.firstIndex(where: { $0.id == a.id }) { activities[i] = a } else { activities.append(a) }
        pending.insert(a.id); persist()
        Task { await updateLiveActivities(); await sync() }
    }
    func startFeed(side: BreastSide) {
        guard let baby, active == nil else { return }
        var a = CareActivity(babyId: baby.id, kind: .breast); a.side = side; a.segmentStartedAt = a.startedAt
        save(a)
        Task { await startLiveActivity(a, baby: baby) }
    }
    enum FeedAction { case switchSide, pause, finish }
    func controlFeed(id: String, action: FeedAction) async {
        guard var a = activities.first(where: { $0.id == id && $0.isRunning }) else { return }
        switch action { case .switchSide: a.switchSide(); case .pause: a.togglePause(); case .finish: a.finish() }
        save(a); await updateLiveActivities(); await sync()
    }
    func delete(_ activity: CareActivity) { var a = activity; if a.isRunning { a.finish() }; a.deleted = true; save(a) }
    func sync() async {
        guard !syncing, online, token != nil, family != nil, !sessionExpired else { return }
        syncing = true; defer { syncing = false }
        do {
            for activityId in Array(pending) where conflicts[activityId] == nil {
                guard let sent = activities.first(where: { $0.id == activityId }) else { continue }
                do {
                    let result: CareActivity = try await API.request("v1/family/activities/\(sent.id)", method: "PUT", body: JSONEncoder().encode(sent), token: token)
                    if let i = activities.firstIndex(where: { $0.id == sent.id }) {
                        if activities[i].mutationId == sent.mutationId { activities[i] = result; pending.remove(sent.id) }
                        else { activities[i].revision = result.revision }
                    }
                    persist()
                } catch let failure as APIError where [400, 404, 409].contains(failure.status) {
                    conflicts[sent.id] = failure.message; persist()
                }
            }
            var remote: [CareActivity] = []; var cursor: Int? = nil
            repeat {
                let path = "v1/family/activities" + (cursor.map { "?cursor=\($0)" } ?? "")
                let response: ActivitiesResponse = try await API.request(path, token: token)
                remote += response.activities; cursor = response.nextCursor
            } while cursor != nil
            for a in remote where !pending.contains(a.id) {
                if let i = activities.firstIndex(where: { $0.id == a.id }) { activities[i] = a } else { activities.append(a) }
            }
            syncMessage = nil; persist(); await updateLiveActivities()
        } catch {
            handle(error)
            if let failure = error as? APIError, failure.status == 403 { await refreshProfile() }
        }
    }
    // Explicit conflict resolution preserves the local draft until the caregiver chooses.
    func discardConflict(_ id: String) async {
        pending.remove(id); conflicts.removeValue(forKey: id); activities.removeAll { $0.id == id }; persist(); await sync(); await updateLiveActivities()
    }
    func keepConflict(_ id: String) async throws {
        var remote: [CareActivity] = []; var cursor: Int? = nil
        repeat {
            let path = "v1/family/activities" + (cursor.map { "?cursor=\($0)" } ?? "")
            let response: ActivitiesResponse = try await API.request(path, token: token)
            remote += response.activities; cursor = response.nextCursor
        } while cursor != nil
        guard let i = activities.firstIndex(where: { $0.id == id }) else { return }
        activities[i].revision = remote.first(where: { $0.id == id })?.revision ?? 0
        conflicts.removeValue(forKey: id); save(activities[i]); await sync()
    }
    private func handle(_ error: Error) {
        if let error = error as? APIError, error.status == 401 { sessionExpired = true }
        syncMessage = error.localizedDescription
    }
    private func content(_ a: CareActivity) -> ActivityContent<FeedAttributes.ContentState> {
        let date = Date(); let elapsed = a.total(at: date)
        return ActivityContent(state: .init(side: a.side.title, paused: a.paused, elapsed: elapsed, timerStart: date.addingTimeInterval(-elapsed), leftSeconds: a.seconds(.left, at: date), rightSeconds: a.seconds(.right, at: date)), staleDate: date.addingTimeInterval(8 * 3600))
    }
    private func startLiveActivity(_ a: CareActivity, baby: Baby) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, !Activity<FeedAttributes>.activities.contains(where: { $0.attributes.activityId == a.id }) else { return }
        do { _ = try Activity.request(attributes: FeedAttributes(activityId: a.id, babyName: baby.name), content: content(a), pushType: nil) }
        catch { self.error = "Feed saved. Live Activity couldn’t start; you can still control the timer in Pip." }
    }
    func updateLiveActivities() async {
        for live in Activity<FeedAttributes>.activities {
            if let a = activities.first(where: { $0.id == live.attributes.activityId }), a.isRunning { await live.update(content(a)) }
            else { await live.end(nil, dismissalPolicy: .immediate) }
        }
    }
    private func endLiveActivities() async { for live in Activity<FeedAttributes>.activities { await live.end(nil, dismissalPolicy: .immediate) } }
}
