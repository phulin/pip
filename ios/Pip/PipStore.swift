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
    private var commands: [ActivityCommand] = []
    private var bases: [String: CareActivity] = [:]
    private var syncAgain = false
    private var socket: URLSessionWebSocketTask?
    private var liveConnection: Task<Void, Never>?
    private var foreground = false
    private var pushObservers: [String: Task<Void, Never>] = [:]
    private var pushStartObserver: Task<Void, Never>?
    private var activityObserver: Task<Void, Never>?
    private var pushStartToken: String?
    private var registeredPushTokens: [String: String] = [:]
    private var serverPushEnabled = false
    private var registeringPush = false
    private var token: String?
    private var monitor: NWPathMonitor?
    var baby: Baby? { babies.first { $0.id == selectedBabyId } ?? babies.first }
    var visibleActivities: [CareActivity] { activities.filter { !$0.deleted && $0.babyId == baby?.id }.sorted { $0.startedAt > $1.startedAt } }
    var active: CareActivity? { visibleActivities.first { $0.isRunning && $0.kind == .breast } }
    var today: [CareActivity] { visibleActivities.filter { Calendar.current.isDateInToday($0.startDate) } }
    private struct Cache: Codable {
        var user: CareUser?; var family: Family?; var babies: [Baby]; var activities: [CareActivity]
        var selectedBabyId: String; var pending: Set<String>; var conflicts: [String: String]
        var commands: [ActivityCommand]?; var bases: [String: CareActivity]?
    }
    private var cacheURL: URL { URL.applicationSupportDirectory.appendingPathComponent(API.isLocal ? "pip-cache.json" : "pip-production-cache.json") }
    init() {
        token = Keychain.read()
        if let data = try? Data(contentsOf: cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from: data) {
            user = cache.user; family = cache.family; babies = cache.babies; activities = cache.activities
            selectedBabyId = cache.selectedBabyId; pending = cache.pending; conflicts = cache.conflicts
            commands = cache.commands ?? []; bases = cache.bases ?? [:]
        }
        sessionExpired = user != nil && token == nil
        observePushTokens()
    }
    func start() async {
        observePushTokens()
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
            let data = try JSONEncoder().encode(Cache(user: user, family: family, babies: babies, activities: activities, selectedBabyId: selectedBabyId, pending: pending, conflicts: conflicts, commands: commands, bases: bases))
            try data.write(to: cacheURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { self.error = "Could not save on this device. Please free up storage before closing Pip." }
    }
    func authenticate(email: String, password: String, name: String, registering: Bool) async throws {
        let response: SessionResponse = try await API.request(registering ? "auth/register" : "auth/login", method: "POST", body: API.data(["email": email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), "password": password, "name": name]))
        try Keychain.save(response.token)
        if user?.id != response.user.id { clearCache() }
        registeredPushTokens = [:]
        token = response.token; user = response.user; sessionExpired = false; persist()
        await refreshProfile(); await sync()
    }
    func refreshProfile() async {
        guard token != nil else { return }
        do {
            let result: MeResponse = try await API.request("v1/me", token: token)
            user = result.user
            if family?.id != result.family?.id {
                activities = []; pending = []; conflicts = [:]; commands = []; bases = [:]; babies = []; selectedBabyId = ""
                stopConnection(); registeredPushTokens = [:]
                await endLiveActivities()
            }
            family = result.family
            connectIfNeeded()
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
        try Keychain.save(result.token); token = result.token; registeredPushTokens = [:]
        stopConnection(); connectIfNeeded(); await registerPushTokens()
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
        stopConnection(); registeredPushTokens = [:]; serverPushEnabled = false
        try? Keychain.save(nil); token = nil; await endLiveActivities(); clearCache(); persist()
    }
    private func clearCache() { commands = []; bases = [:]; user = nil; family = nil; babies = []; activities = []; pending = []; conflicts = [:]; selectedBabyId = ""; sessionExpired = false }
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

    }
    func startTracking(kind: ActivityKind, milk: String = "breastMilk") {
        guard let baby, !visibleActivities.contains(where: { $0.kind == kind && $0.isRunning }) else { return }
        var a = CareActivity(babyId: baby.id, kind: kind)
        a.milk = milk; a.segmentStartedAt = a.startedAt
        save(a)
    }
    func setVolume(id: String, volume: Double) {
        guard activities.contains(where: { $0.id == id && $0.isRunning }) else { return }
        enqueue(ActivityCommand(activityId: id, volumeML: min(5000, max(0, volume))))
    }
    enum FeedAction { case switchSide, pause, finish }
    func controlFeed(id: String, action: FeedAction) async {
        guard let a = activities.first(where: { $0.id == id && $0.isRunning }) else { return }
        switch action {
        case .switchSide: enqueue(ActivityCommand(activityId: id, side: a.side.other))
        case .pause: enqueue(ActivityCommand(activityId: id, paused: !a.paused))
        case .finish: enqueue(ActivityCommand(activityId: id, finish: true))
        }
        await sync()
    }
    // Live Activity intents carry the state displayed on the lock screen. Never toggle
    // a stale app-cache value: two caregivers pressing Pause must both mean Pause.
    func controlFromLiveActivity(id: String, side: BreastSide? = nil, paused: Bool? = nil) async {
        enqueue(ActivityCommand(activityId: id, side: side, paused: paused))
        await sync()
    }
    private func enqueue(_ command: ActivityCommand) {
        commands.append(command)
        if let i = activities.firstIndex(where: { $0.id == command.activityId }) { activities[i] = command.applying(to: activities[i]) }
        persist()
        Task { await updateLiveActivities(); await sync() }
    }
    private func receive(_ activity: CareActivity) {
        bases[activity.id] = activity
        let local = commands.filter { $0.activityId == activity.id }.reduce(activity) { $1.applying(to: $0) }
        if let i = activities.firstIndex(where: { $0.id == activity.id }) { activities[i] = local } else { activities.append(local) }
    }
    func delete(_ activity: CareActivity) { var a = activity; if a.isRunning { a.finish() }; a.deleted = true; save(a) }
    func sync() async {
        guard online, token != nil, family != nil, !sessionExpired else { return }
        if syncing { syncAgain = true; return }
        syncing = true
        defer {
            syncing = false
            if syncAgain { syncAgain = false; Task { await self.sync() } }
        }
        do {
            for activityId in Array(pending) where conflicts[activityId] == nil {
                guard let sent = activities.first(where: { $0.id == activityId }) else { continue }
                do {
                    let result: CareActivity = try await API.request("v1/family/activities/\(sent.id)", method: "PUT", body: activityBody(sent), token: token)
                    if let i = activities.firstIndex(where: { $0.id == sent.id }) {
                        if activities[i].mutationId == sent.mutationId { pending.remove(sent.id); receive(result) }
                        else { activities[i].revision = result.revision; bases[sent.id] = result; syncAgain = true }
                    }
                    persist()
                } catch let failure as APIError where [400, 404, 409].contains(failure.status) {
                    if sent.revision == 0, let current = failure.current, current.id != sent.id, current.isRunning, current.babyId == sent.babyId, current.kind == sent.kind {
                        // Another caregiver already started this timer. Join theirs.
                        pending.remove(sent.id); bases.removeValue(forKey: sent.id)
                        activities.removeAll { $0.id == sent.id }
                        for i in commands.indices where commands[i].activityId == sent.id { commands[i].activityId = current.id }
                        receive(current)
                    } else { conflicts[sent.id] = failure.message }
                    persist()
                }
            }
            for command in commands {
                if pending.contains(command.activityId) { continue }
                do {
                    let result: CareActivity = try await API.request("v1/family/activities/\(command.activityId)/commands", method: "POST", body: JSONEncoder().encode(command), token: token)
                    commands.removeAll { $0.id == command.id }
                    // An editor can save while this request is in flight. Keep that
                    // draft for the versioned merge instead of replacing its notes.
                    if !pending.contains(result.id) { receive(result) }
                    persist()
                } catch let failure as APIError where failure.status == 404 {
                    commands.removeAll { $0.id == command.id }; persist()
                }
            }
            var remote: [CareActivity] = []; var cursor: Int? = nil
            repeat {
                let path = "v1/family/activities" + (cursor.map { "?cursor=\($0)" } ?? "")
                let response: ActivitiesResponse = try await API.request(path, token: token)
                remote += response.activities; cursor = response.nextCursor
            } while cursor != nil
            for a in remote where !pending.contains(a.id) {
                receive(a)
            }
            syncMessage = nil; persist(); await registerPushTokens(); await updateLiveActivities(); connectIfNeeded()
        } catch {
            handle(error)
            if let failure = error as? APIError, failure.status == 403 { await refreshProfile() }
        }
    }
    private func activityBody(_ a: CareActivity) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(a)) as! [String: Any]
        if Activity<FeedAttributes>.activities.contains(where: { $0.attributes.activityId == a.id }) { object["liveDeviceId"] = deviceId }
        if let base = bases[a.id] { object["base"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) }
        return try JSONSerialization.data(withJSONObject: object)
    }
    var waitingChanges: Int { pending.count + commands.count }
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
        if let error = error as? APIError, error.status == 401 { sessionExpired = true; stopConnection() }
        syncMessage = error.localizedDescription
    }
    private func content(_ a: CareActivity) -> ActivityContent<FeedAttributes.ContentState> {
        let date = Date(); let elapsed = a.total(at: date)
        return ActivityContent(state: .init(side: a.side.title, paused: a.paused, elapsed: elapsed, timerStart: date.addingTimeInterval(-elapsed), leftSeconds: a.seconds(.left, at: date), rightSeconds: a.seconds(.right, at: date)), staleDate: date.addingTimeInterval(8 * 3600))
    }
    private func startLiveActivity(_ a: CareActivity, baby: Baby) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, !Activity<FeedAttributes>.activities.contains(where: { $0.attributes.activityId == a.id }) else { return }
        do { _ = try Activity.request(attributes: FeedAttributes(activityId: a.id, babyName: baby.name), content: content(a), pushType: API.isLocal ? nil : .token) }
        catch { self.error = "Feed saved. Live Activity couldn’t start; you can still control the timer in Pip." }
    }
    func updateLiveActivities() async {
        if foreground {
            for a in activities where a.isRunning && a.kind == .breast && (!serverPushEnabled || a.revision == 0) {
                if let baby = babies.first(where: { $0.id == a.babyId }) { await startLiveActivity(a, baby: baby) }
            }
        }
        for live in Activity<FeedAttributes>.activities {
            if let a = activities.first(where: { $0.id == live.attributes.activityId }), a.isRunning { await live.update(content(a)) }
            else if activities.contains(where: { $0.id == live.attributes.activityId }) || family == nil { await live.end(nil, dismissalPolicy: .immediate) }
        }
    }
    private func endLiveActivities() async { for live in Activity<FeedAttributes>.activities { await live.end(nil, dismissalPolicy: .immediate) } }
    func setForeground(_ value: Bool) {
        foreground = value
        if value { connectIfNeeded() } else { stopConnection() }
    }
    private func stopConnection() {
        liveConnection?.cancel(); liveConnection = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
    }
    private func connectIfNeeded() {
        guard foreground, liveConnection == nil, token != nil, family != nil, !sessionExpired else { return }
        liveConnection = Task { [weak self] in
            guard let self else { return }
            var retry: Double = 1
            while !Task.isCancelled && self.foreground {
                var url = URLComponents(url: API.baseURL.appendingPathComponent("v1/family/live"), resolvingAgainstBaseURL: false)!
                url.scheme = API.isLocal ? "ws" : "wss"
                var request = URLRequest(url: url.url!); request.setValue("Bearer \(self.token ?? "")", forHTTPHeaderField: "Authorization")
                let connection = URLSession.shared.webSocketTask(with: request)
                self.socket = connection; connection.resume()
                do {
                    while !Task.isCancelled {
                        _ = try await connection.receive()
                        retry = 1
                        await self.sync()
                    }
                } catch { connection.cancel(with: .goingAway, reason: nil) }
                if Task.isCancelled { break }
                try? await Task.sleep(for: .seconds(retry)); retry = min(retry * 2, 30)
            }
        }
    }
    private var deviceId: String {
        let key = "pip.push-device.\(user?.id ?? "anonymous")"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString.lowercased(); UserDefaults.standard.set(id, forKey: key); return id
    }
    private func observePushTokens() {
        guard !API.isLocal, pushStartObserver == nil else { return }
        if #available(iOS 17.2, *) {
            pushStartObserver = Task {
                for await data in Activity<FeedAttributes>.pushToStartTokenUpdates {
                    pushStartToken = data.map { String(format: "%02x", $0) }.joined()
                    registeredPushTokens = [:]
                    await registerPushTokens()
                }
            }
        }
        activityObserver = Task {
            for await activity in Activity<FeedAttributes>.activityUpdates { observe(activity) }
        }
        for activity in Activity<FeedAttributes>.activities { observe(activity) }
    }
    private func observe(_ activity: Activity<FeedAttributes>) {
        guard pushObservers[activity.id] == nil else { return }
        pushObservers[activity.id] = Task {
            for await _ in activity.pushTokenUpdates { await registerPushTokens() }
        }
    }
    private func registerPushTokens() async {
        guard !API.isLocal, !registeringPush, let pushStartToken, token != nil, family != nil else { return }
        registeringPush = true; defer { registeringPush = false }
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        do {
            if registeredPushTokens["start"] != pushStartToken {
                struct Registration: Decodable { var pushEnabled: Bool }
                struct DeviceRegistration: Encodable { var token: String; var environment: String; var activeIds: [String] }
                let body = DeviceRegistration(token: pushStartToken, environment: environment, activeIds: Activity<FeedAttributes>.activities.map { $0.attributes.activityId })
                let result: Registration = try await API.request("v1/family/devices/\(deviceId)", method: "PUT", body: JSONEncoder().encode(body), token: token)
                serverPushEnabled = result.pushEnabled; registeredPushTokens["start"] = pushStartToken
            }
            for activity in Activity<FeedAttributes>.activities {
                observe(activity)
                guard let data = activity.pushToken else { continue }
                let value = data.map { String(format: "%02x", $0) }.joined()
                if registeredPushTokens[activity.id] == value { continue }
                let _: OK = try await API.request("v1/family/devices/\(deviceId)/activities/\(activity.attributes.activityId)", method: "PUT", body: API.data(["token": value]), token: token)
                registeredPushTokens[activity.id] = value
            }
        } catch { /* Foreground sync retries registration; tracking remains available. */ }
    }

}
