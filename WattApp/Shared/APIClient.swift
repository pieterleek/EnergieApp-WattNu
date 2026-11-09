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
        guard let url = AppSettings.serverURL, !AppSettings.token.isEmpty else { return nil }
        return APIClient(baseURL: url, token: AppSettings.token)
    }

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

    func gridLoad(days: Int = 7) async throws -> GridLoadResponse {
        try await get("grid-load", ["days": days])
    }

    func updateTelegramSettings(_ settings: TelegramSettings) async throws -> Bool {
        let response: TelegramSettingsResponse = try await send(
            "telegram/settings", method: "PUT", body: settings
        )
        return response.configured
    }

    func sendTelegramTest() async throws {
        try await sendWithoutResponse("telegram/test", method: "POST")
    }

    private func get<T: Decodable>(_ path: String, _ query: [String: Int] = [:]) async throws -> T {
        let endpoint = baseURL.appendingPathComponent("api").appendingPathComponent(path)
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw APIError.badResponse
        }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: String($0.value)) }
        }
        guard let url = components.url else { throw APIError.badResponse }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.server(http.statusCode, Self.errorDetail(from: data))
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    private func send<Body: Encodable, Result: Decodable>(
        _ path: String,
        method: String,
        body: Body
    ) async throws -> Result {
        let url = baseURL.appendingPathComponent("api").appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.server(http.statusCode, Self.errorDetail(from: data))
        }
        return try JSONDecoder().decode(Result.self, from: data)
    }

    private func sendWithoutResponse(_ path: String, method: String) async throws {
        let url = baseURL.appendingPathComponent("api").appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.server(http.statusCode, Self.errorDetail(from: data))
        }
    }

    private static func errorDetail(from data: Data) -> String? {
        struct ErrorBody: Decodable { let detail: String }
        return try? JSONDecoder().decode(ErrorBody.self, from: data).detail
    }
}
