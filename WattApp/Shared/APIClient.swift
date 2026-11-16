import Foundation

enum APIError: LocalizedError {
    case badResponse
    case unauthorized
    case server(Int, String?)

    var errorDescription: String? {
        switch self {
        case .badResponse: return "Onverwacht antwoord van de server."
        case .unauthorized: return "Het API-token klopt niet."
        case .server(let code, let detail):
            return detail ?? "De server gaf foutcode \(code)."
        }
    }
}

struct APIClient: Sendable {
    let baseURL: URL
    let token: String

    /// Nil zolang server en token niet zijn ingesteld.
    static var current: APIClient? {
        let token = AppSettings.token
        guard let url = AppSettings.serverURL, !token.isEmpty else { return nil }
        return APIClient(baseURL: url, token: token)
    }

    // MARK: Metingen

    func now() async throws -> NowReading {
        try await get("now")
    }

    func series(hours: Int, points: Int = 300) async throws -> [SeriesPoint] {
        try await get("series", ["hours": hours, "points": points])
    }

    func daily(days: Int = 30) async throws -> [DayUsage] {
        try await get("daily", ["days": days])
    }

    func heatmap(days: Int = 90) async throws -> [HeatCell] {
        try await get("heatmap", ["days": days])
    }

    func peaks(days: Int = 30, limit: Int = 10) async throws -> [Peak] {
        try await get("peaks", ["days": days, "limit": limit])
    }

    func baseload(days: Int = 30) async throws -> [BaseloadDay] {
        try await get("baseload", ["days": days])
    }

    func compare() async throws -> Comparison {
        try await get("compare")
    }

    func gridLoad(days: Int = 7) async throws -> GridLoadResponse {
        try await get("grid-load", ["days": days])
    }

    // MARK: Instellingen en meldingen

    func settings() async throws -> SettingsEnvelope {
        try await get("settings")
    }

    func updateSettings(_ settings: ServerSettings) async throws -> SettingsEnvelope {
        let data = try await request("settings", method: "PUT", body: Self.encode(settings))
        return try Self.decode(data)
    }

    func registerDevice(_ device: DeviceRegistration) async throws -> DeviceRegistrationResponse {
        let data = try await request("devices", method: "POST", body: Self.encode(device))
        return try Self.decode(data)
    }

    func removeDevice(token: String) async throws {
        _ = try await request("devices/\(token)", method: "DELETE")
    }

    /// `channel` is "telegram" of "push"; nil stuurt naar alle ingestelde kanalen.
    func sendTestNotification(channel: String?) async throws {
        let query = channel.map { ["channel": $0] } ?? [:]
        _ = try await request("notifications/test", method: "POST", query: query)
    }

    // MARK: Transport

    private func get<T: Decodable>(_ path: String, _ query: [String: Int] = [:]) async throws -> T {
        let data = try await request(path, query: query.mapValues(String.init))
        return try Self.decode(data)
    }

    private func request(
        _ path: String,
        method: String = "GET",
        query: [String: String] = [:],
        body: Data? = nil
    ) async throws -> Data {
        let endpoint = baseURL.appendingPathComponent("api").appendingPathComponent(path)
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw APIError.badResponse
        }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw APIError.badResponse }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = method == "GET" ? 8 : 12
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.server(http.statusCode, Self.errorDetail(from: data))
        }
        return data
    }

    private static func decode<T: Decodable>(_ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(value)
    }

    private static func errorDetail(from data: Data) -> String? {
        struct ErrorBody: Decodable { let detail: String }
        return try? JSONDecoder().decode(ErrorBody.self, from: data).detail
    }
}
