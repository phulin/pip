import Foundation
import Security

struct APIError: LocalizedError {
    var status: Int; var message: String; var current: CareActivity?
    var errorDescription: String? { message }
}
struct API {
    static var baseURL: URL { URL(string: Bundle.main.object(forInfoDictionaryKey: "PipAPIURL") as? String ?? "http://127.0.0.1:8787")! }
    static func request<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil, token: String? = nil) async throws -> T {
        var request = URLRequest(url: URL(string: path, relativeTo: baseURL.appendingPathComponent("/"))!)
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 500
        guard (200..<300).contains(status) else {
            struct Failure: Decodable { var error: String; var current: CareActivity? }
            let failure = try? JSONDecoder().decode(Failure.self, from: data)
            throw APIError(status: status, message: failure?.error ?? "Unable to connect. Please try again.", current: failure?.current)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    static func data(_ object: [String: String]) throws -> Data { try JSONEncoder().encode(object) }
}
enum Keychain {
    static let service = "app.pip.baby.session"
    static func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "session", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ value: String?) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "session"]
        guard let value else { SecItemDelete(query as CFDictionary); return }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw APIError(status: 0, message: "Could not securely save your session.") }
        } else if status != errSecSuccess { throw APIError(status: 0, message: "Could not securely save your session.") }
    }
}
struct OK: Decodable { var ok: Bool }
struct SessionResponse: Decodable { var token: String; var user: CareUser }
struct MeResponse: Decodable { var user: CareUser; var family: Family? }
struct BabyResponse: Decodable { var babies: [Baby] }
struct ActivitiesResponse: Decodable { var activities: [CareActivity]; var nextCursor: Int? }
struct MembersResponse: Decodable { var members: [Member] }
