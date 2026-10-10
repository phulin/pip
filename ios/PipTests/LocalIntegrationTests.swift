import XCTest
@testable import Pip

/// Run with `npm run dev` running. Never creates data on a remote server.
@MainActor final class LocalIntegrationTests: XCTestCase {
    func testLocalAccountFamilyAndTrackingRoundTrip() async throws {
        guard API.baseURL.host == "127.0.0.1" else { throw XCTSkip("Local development server only") }
        struct Health: Decodable { var status: String }
        guard let _: Health = try? await API.request("health") else { throw XCTSkip("Start the local Worker to run the end-to-end integration test") }
        let store = PipStore.shared
        if store.user?.email.hasPrefix("sim-") == true && store.user?.email.hasSuffix("@example.com") == true { await store.signOut() }
        guard store.user == nil else { throw XCTSkip("Preserving an existing simulator session") }
        let password = UUID().uuidString
        try await store.authenticate(email: "sim-\(UUID().uuidString)@example.com", password: password, name: "Alex", registering: true)
        addTeardownBlock { @MainActor in
            if store.user != nil { try await store.deleteAccount(password: password) }
        }
        try await store.createFamily(name: "Our little family", babyName: "Milo", birthday: Date().addingTimeInterval(-50 * 86400))
        XCTAssertNotNil(store.baby)
        let babyId = try XCTUnwrap(store.baby?.id)
        var bottle = CareActivity(babyId: babyId, kind: .bottle)
        bottle.startedAt -= 7200000; bottle.endedAt = bottle.startedAt; bottle.paused = true; bottle.volumeML = 90
        store.save(bottle)
        var pump = CareActivity(babyId: babyId, kind: .pump)
        pump.startedAt -= 3600000; pump.endedAt = pump.startedAt + 900000; pump.paused = true; pump.volumeML = 120
        store.save(pump)
        store.startFeed(side: .left)
        let feedId = try XCTUnwrap(store.active?.id)
        try await Task.sleep(for: .seconds(2))
        await store.controlFeed(id: feedId, action: .switchSide)
        XCTAssertEqual(store.active?.side, .right)
        await store.controlFeed(id: feedId, action: .pause)
        XCTAssertTrue(try XCTUnwrap(store.active?.paused))
        await store.controlFeed(id: feedId, action: .pause)
        XCTAssertFalse(try XCTUnwrap(store.active?.paused))
        try await Task.sleep(for: .seconds(2))
        await store.sync()
        XCTAssertTrue(store.pending.isEmpty, store.syncMessage ?? "Changes remain pending")
        XCTAssertTrue(store.conflicts.isEmpty)
        let persisted = PipStore()
        XCTAssertEqual(persisted.activities.count, 3)
        XCTAssertEqual(persisted.active?.id, feedId)
        print("PIP_PREVIEW_READY")
        try await Task.sleep(for: .seconds(3))
        await store.controlFeed(id: feedId, action: .finish)
        await store.sync()
        XCTAssertNil(store.active)
        XCTAssertEqual(store.today.count, 3)
        try await Task.sleep(for: .seconds(1))
        try await store.deleteAccount(password: password)
        XCTAssertNil(store.user)
    }
}
