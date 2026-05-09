//
//  MemoryService.swift
//  Evlin iOS
//
//  Strategy-agent Task 11.3 — list/create/update/delete the parent memory
//  rows surfaced in Settings → Memory.
//
//  Note: APIClient.baseURL is a String (not URL), and APIClient is not a
//  singleton on this codebase, so we construct a fresh APIClient() at init
//  time to read the user's saved server URL — same pattern used by
//  ScreenTimeManager.
//

import Foundation

struct MemoryService {
    let baseURL: String
    let session: URLSession

    init(baseURL: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL ?? APIClient().baseURL
        self.session = session
    }

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    func list(familyId: UUID) async throws -> [Memory] {
        var comps = URLComponents(string: "\(baseURL)/parent/memory")!
        comps.queryItems = [URLQueryItem(name: "family_id", value: familyId.uuidString)]
        guard let url = comps.url else { throw URLError(.badURL) }
        let (data, _) = try await session.data(from: url)
        return try decoder().decode([Memory].self, from: data)
    }

    func create(_ body: MemoryCreateBody) async throws -> Memory {
        guard let url = URL(string: "\(baseURL)/parent/memory") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, _) = try await session.data(for: req)
        return try decoder().decode(Memory.self, from: data)
    }

    func update(id: UUID, body: MemoryUpdateBody) async throws -> Memory {
        guard let url = URL(string: "\(baseURL)/parent/memory/\(id.uuidString)") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, _) = try await session.data(for: req)
        return try decoder().decode(Memory.self, from: data)
    }

    func delete(id: UUID) async throws {
        guard let url = URL(string: "\(baseURL)/parent/memory/\(id.uuidString)") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        _ = try await session.data(for: req)
    }
}
