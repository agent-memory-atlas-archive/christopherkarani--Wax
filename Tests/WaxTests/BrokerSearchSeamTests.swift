import Foundation
import Testing
@testable import Wax

private func withBrokerSearchSeam<T>(
    project: String?,
    repo: String?,
    _ body: (BrokerRecall.Environment, UUID) async throws -> T
) async throws -> T {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-broker-search-seam-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    var config = OrchestratorConfig.default
    config.enableVectorSearch = false
    config.enableTextSearch = true
    config.enableStructuredMemory = false

    let longTerm = try await MemoryOrchestrator(
        at: root.appendingPathComponent("durable.wax"),
        config: config
    )
    let sessionRoot = root.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
    let sessions = VirtualSessionStore(
        sessionRootURL: sessionRoot,
        brokerInstanceID: UUID().uuidString,
        openExisting: { url in
            var sessionConfig = OrchestratorConfig.default
            sessionConfig.enableVectorSearch = false
            sessionConfig.enableTextSearch = true
            sessionConfig.enableStructuredMemory = false
            return try await MemoryOrchestrator(at: url, config: sessionConfig)
        }
    )
    let ended = DiskEndedSessionStore(
        sessionRootURL: sessionRoot,
        noEmbedder: true,
        enableAccessStatsScoring: false,
        readiness: EmbeddingReadiness()
    )
    do {
        let started = try await sessions.start(
            explicitSessionID: nil,
            agentID: "broker-search-seam",
            runID: "broker-search-run",
            inferredScope: MemoryScopeContext(repoName: repo, projectName: project)
        )
        let environment = BrokerRecall.Environment(
            longTermMemory: longTerm,
            sessions: sessions,
            endedSessions: ended,
            preview: { $0 ?? "" },
            canonicalFrameID: { frameID, _ in frameID },
            nowMs: { Int64(Date().timeIntervalSince1970 * 1000) }
        )
        let result = try await body(environment, started.state.id)
        await sessions.closeAll()
        try await longTerm.close()
        return result
    } catch {
        await sessions.closeAll()
        try? await longTerm.close()
        throw error
    }
}

private func brokerSearchCommand(query: String, sessionID: UUID) throws -> BrokerCommand.Search {
    let decoded = try BrokerCommand.decode(
        command: "search",
        arguments: [
            "query": .string(query),
            "mode": .string("text"),
            "topK": .int(10),
            "session_id": .string(sessionID.uuidString),
        ]
    )
    guard case .search(let command) = decoded else {
        throw BrokerValidationError.invalid("expected search command")
    }
    return command
}

private func brokerSearchPreviews(_ packed: BrokerRecall.PackedSearch) -> [String] {
    packed.hits.compactMap(\.previewText) + packed.sessionHits.compactMap(\.previewText)
}

private func brokerSearchPayloadPreviews(_ packed: BrokerRecall.PackedSearch) -> [String] {
    (packed.payload.objectValue?["results"]?.arrayValue ?? []).compactMap { row in
        row.objectValue?["preview"]?.stringValue
    }
}

@Test
func sessionScopedBrokerSearchDropsForeignProjectDurableWhenIdentityIsResolved() async throws {
    try await withBrokerSearchSeam(project: "home-project", repo: "home-repo") { environment, sessionID in
        let homeToken = "zxqHome\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10))"
        let foreignToken = "zxqForeign\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10))"
        _ = try await environment.longTermMemory.remember(
            "Home durable lesson \(homeToken) must stay visible to session-scoped search.",
            metadata: [
                MemoryMetadataKeys.project: "home-project",
                MemoryMetadataKeys.repo: "home-repo",
                MemoryMetadataKeys.type: MemoryType.lesson.rawValue,
            ]
        )
        _ = try await environment.longTermMemory.remember(
            "Foreign durable \(foreignToken) must stay out of session-scoped search.",
            metadata: [
                MemoryMetadataKeys.project: "Foreign-home-project",
                MemoryMetadataKeys.repo: "Foreign-home-repo",
                MemoryMetadataKeys.type: MemoryType.lesson.rawValue,
            ]
        )
        try await environment.longTermMemory.flush()

        let homePacked = try await BrokerRecall.search(
            try brokerSearchCommand(query: homeToken, sessionID: sessionID),
            in: environment
        )
        let homePreviews = brokerSearchPreviews(homePacked) + brokerSearchPayloadPreviews(homePacked)
        #expect(
            homePreviews.contains { $0.contains(homeToken) },
            "resolved identity must keep home-project durable; got \(homePreviews)"
        )

        let foreignPacked = try await BrokerRecall.search(
            try brokerSearchCommand(query: foreignToken, sessionID: sessionID),
            in: environment
        )
        let foreignPreviews = brokerSearchPreviews(foreignPacked) + brokerSearchPayloadPreviews(foreignPacked)
        #expect(
            foreignPreviews.contains { $0.contains(foreignToken) } == false,
            "resolved identity must drop foreign wax.project durable; got \(foreignPreviews)"
        )
    }
}

@Test
func sessionScopedBrokerSearchEmptyIdentityDoesNotLeakStampedForeignDurable() async throws {
    try await withBrokerSearchSeam(project: nil, repo: nil) { environment, sessionID in
        let foreignToken = "zxqEmptyF\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10))"
        let unstampedToken = "zxqEmptyU\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10))"
        _ = try await environment.longTermMemory.remember(
            "Foreign durable \(foreignToken) must stay out of unresolved session search.",
            metadata: [
                MemoryMetadataKeys.project: "other-project",
                MemoryMetadataKeys.repo: "other-repo",
                MemoryMetadataKeys.type: MemoryType.lesson.rawValue,
            ]
        )
        _ = try await environment.longTermMemory.remember(
            "Unstamped durable \(unstampedToken) stays visible when identity is empty.",
            metadata: [
                MemoryMetadataKeys.type: MemoryType.lesson.rawValue,
            ]
        )
        try await environment.longTermMemory.flush()

        let foreignPacked = try await BrokerRecall.search(
            try brokerSearchCommand(query: foreignToken, sessionID: sessionID),
            in: environment
        )
        let foreignPreviews = brokerSearchPreviews(foreignPacked) + brokerSearchPayloadPreviews(foreignPacked)
        #expect(
            foreignPreviews.contains { $0.contains(foreignToken) } == false,
            "empty identity must not leak stamped foreign durable; got \(foreignPreviews)"
        )

        let unstampedPacked = try await BrokerRecall.search(
            try brokerSearchCommand(query: unstampedToken, sessionID: sessionID),
            in: environment
        )
        let unstampedPreviews = brokerSearchPreviews(unstampedPacked) + brokerSearchPayloadPreviews(unstampedPacked)
        #expect(
            unstampedPreviews.contains { $0.contains(unstampedToken) },
            "empty identity must keep unstamped durable; got \(unstampedPreviews)"
        )
    }
}
