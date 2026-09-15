import Foundation
import Testing
@testable import Wax

/// Pins HorizonSet lane visibility after session-scope resolution to the exact
/// Bool-table behavior that preceded HorizonSet: a resolved session keeps the
/// request, durableOnly forces the durable lane, unscoped drops working.
struct HorizonScopeSelectionTests {
    private static let allRequests: [HorizonSet] = [
        [],
        [.working],
        [.episodic],
        [.durable],
        [.working, .episodic],
        [.working, .durable],
        [.episodic, .durable],
        HorizonSet.all,
    ]

    @Test
    func sessionScopeKeepsRequestedLanes() {
        let resolved = AgentBrokerService.ResolvedSessionScope.session(
            UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        )
        for requested in Self.allRequests {
            #expect(
                AgentBrokerService.scopedHorizons(scope: resolved, requested: requested) == requested,
                "session scope must keep \(requested.rawValue)"
            )
        }
    }

    @Test
    func unscopedScopeDropsWorkingLaneOnly() {
        for requested in Self.allRequests {
            #expect(
                AgentBrokerService.scopedHorizons(scope: .none, requested: requested) == requested.subtracting(.working),
                "unscoped scope must drop only working from \(requested.rawValue)"
            )
        }
    }

    @Test
    func durableOnlyScopeSelectsDurableLane() {
        for requested in Self.allRequests {
            #expect(
                AgentBrokerService.scopedHorizons(scope: .durableOnly, requested: requested) == [.durable],
                "durableOnly scope must select durable over \(requested.rawValue)"
            )
        }
    }

    @Test
    func laneMembershipMirrorsHorizonVocabulary() {
        #expect(HorizonSet.working.contains(.working))
        #expect(HorizonSet.episodic.contains(.episodic))
        #expect(HorizonSet.durable.contains(.durable))
        #expect(HorizonSet.working.intersection([.episodic, .durable]).isEmpty)
        #expect(HorizonSet.all.subtracting([.working, .episodic, .durable]).isEmpty)
    }

    @Test(arguments: [
        HorizonSet.episodic,
        HorizonSet.durable,
        [.episodic, .durable] as HorizonSet,
    ])
    func unscopedIdentityAllowsEpisodicAndDurableWithoutSession(horizons: HorizonSet) throws {
        let identity = try MemorySearchIdentity.make(sessionID: nil, horizons: horizons)
        #expect(identity == .unscoped(horizons))
        #expect(identity.sessionID == nil)
        #expect(identity.horizons == horizons)
        #expect(identity.includesWorking == false)

        let request = LayeredRecall.SearchRequest(
            query: "q",
            mode: .textOnly,
            topK: 3,
            identity: identity
        )
        #expect(request.sessionID == nil)
        #expect(request.horizons == horizons)
        #expect(request.identity.includesWorking == false)
    }

    @Test(arguments: [
        HorizonSet.working,
        [.working, .episodic] as HorizonSet,
        [.working, .durable] as HorizonSet,
        HorizonSet.all,
    ])
    func identityMakeRejectsWorkingWithoutSession(horizons: HorizonSet) {
        #expect(throws: BrokerValidationError.invalid("working horizon requires a session_id")) {
            _ = try MemorySearchIdentity.make(sessionID: nil, horizons: horizons)
        }
        #expect(throws: BrokerValidationError.invalid("working horizon requires a session_id")) {
            _ = try LayeredRecall.SearchRequest(
                query: "q",
                mode: .textOnly,
                topK: 3,
                sessionID: nil,
                horizons: horizons
            )
        }
    }

    @Test
    func identityMakeRejectsEmptyHorizons() {
        let sessionID = UUID()
        #expect(throws: BrokerValidationError.invalid(
            "memory search identity requires a non-empty horizon set"
        )) {
            _ = try MemorySearchIdentity.make(sessionID: nil, horizons: [])
        }
        #expect(throws: BrokerValidationError.invalid(
            "memory search identity requires a non-empty horizon set"
        )) {
            _ = try MemorySearchIdentity.make(sessionID: sessionID, horizons: [])
        }
    }

    @Test
    func sessionIdentityAllowsWorkingAndReportsIncludesWorking() throws {
        let sessionID = UUID()
        let identity = try MemorySearchIdentity.make(
            sessionID: sessionID,
            horizons: [.working, .durable]
        )
        #expect(identity == .session(sessionID: sessionID, horizons: [.working, .durable]))
        #expect(identity.sessionID == sessionID)
        #expect(identity.horizons == [.working, .durable])
        #expect(identity.includesWorking == true)

        let durableOnly = try MemorySearchIdentity.make(
            sessionID: sessionID,
            horizons: .durable
        )
        #expect(durableOnly.includesWorking == false)
        #expect(durableOnly.sessionID == sessionID)
    }

    @Test
    func unscopedWorkingDirectCaseDoesNotClaimIncludesWorking() {
        // Direct case construction can still name an illegal HorizonSet; includesWorking
        // stays false so search cannot nil-skip a UUID that was never there.
        let identity = MemorySearchIdentity.unscoped([.working])
        #expect(identity.includesWorking == false)
        #expect(identity.sessionID == nil)
    }

    @Test
    func sessionWorkingIdentityRunsWorkingLaneWithoutNilSkip() async throws {
        try await withWorkingSearchLane { stores, sessionID, token in
            let identity = MemorySearchIdentity.session(
                sessionID: sessionID,
                horizons: .working
            )
            #expect(identity.includesWorking == true)
            #expect(identity.sessionID == sessionID)

            let hits = try await LayeredRecall.search(
                request: LayeredRecall.SearchRequest(
                    query: token,
                    mode: .textOnly,
                    topK: 5,
                    identity: identity
                ),
                stores: stores
            )
            #expect(hits.contains { hit in
                hit.text.contains(token) && hit.horizon == .working && hit.sessionID == sessionID
            })
        }
    }

    @Test
    func unscopedEpisodicSearchRunsWithoutSessionUUID() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-unscoped-episodic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableStructuredMemory = false
        let longTerm = try await MemoryOrchestrator(
            at: root.appendingPathComponent("durable.wax"),
            config: config
        )
        do {
            let endedSessionID = UUID()
            let token = "WAXUNSCOPED-\(UUID().uuidString.prefix(8))"
            let manifest = BrokerSessionManifest(
                sessionID: endedSessionID,
                agentID: "ended-agent",
                runID: "ended-run",
                project: "Wax",
                repo: "Wax",
                storePath: "/tmp/ended-session-not-on-disk.wax",
                eventLogPath: "/tmp/ended-session-not-on-disk.events",
                status: .ended,
                brokerLeaseOwnerID: nil,
                leaseExpiresAtMs: nil,
                createdAtMs: 0,
                updatedAtMs: 0,
                endedAtMs: 0
            )
            let ended = InMemoryEndedSessionStore(
                manifests: [manifest],
                searchHits: [
                    endedSessionID: [
                        LayeredRecall.EpisodicLaneHit(
                            frameID: 7,
                            score: 0.88,
                            previewText: "episodic \(token) note",
                            metadata: [:],
                            explanations: [],
                            canonicalFrameID: 7
                        )
                    ]
                ]
            )
            let stores = LayeredRecall.Stores(
                longTermMemory: longTerm,
                workingLane: { _ in nil },
                inferWriteScope: { _, _ in LayeredRecall.Identity() },
                preview: { $0 ?? "" },
                canonicalFrameID: { frameID, _ in frameID },
                endedSessions: ended,
                nowMs: { 0 }
            )
            let hits = try await LayeredRecall.search(
                request: LayeredRecall.SearchRequest(
                    query: token,
                    mode: .textOnly,
                    topK: 5,
                    identity: .unscoped(.episodic)
                ),
                stores: stores
            )
            #expect(hits.contains { $0.text.contains(token) && $0.horizon == .episodic })
            try await longTerm.close()
        } catch {
            try? await longTerm.close()
            throw error
        }
    }
}

private func withWorkingSearchLane(
    _ body: (LayeredRecall.Stores, UUID, String) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-working-search-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    var config = OrchestratorConfig.default
    config.enableTextSearch = true
    config.enableVectorSearch = false
    config.enableStructuredMemory = false
    let working = try await MemoryOrchestrator(
        at: root.appendingPathComponent("working.wax"),
        config: config
    )
    do {
        let durable = try await MemoryOrchestrator(
            at: root.appendingPathComponent("durable.wax"),
            config: config
        )
        do {
            let token = "WAXWORKING-\(UUID().uuidString.prefix(8))"
            try await working.remember("working lane \(token) note")
            try await working.flush()
            let sessionID = UUID()
            let stores = LayeredRecall.Stores(
                longTermMemory: durable,
                workingLane: { requested in
                    guard requested == sessionID else { return nil }
                    return LayeredRecall.WorkingLane(
                        sessionID: sessionID,
                        agentID: "agent",
                        runID: "run",
                        updatedAtMs: 0,
                        project: nil,
                        repo: nil,
                        memory: working
                    )
                },
                inferWriteScope: { _, _ in LayeredRecall.Identity() },
                preview: { $0 ?? "" },
                canonicalFrameID: { frameID, _ in frameID },
                endedSessions: InMemoryEndedSessionStore(),
                nowMs: { 0 }
            )
            try await body(stores, sessionID, token)
            try await durable.close()
        } catch {
            try? await durable.close()
            throw error
        }
        try await working.close()
    } catch {
        try? await working.close()
        throw error
    }
}
