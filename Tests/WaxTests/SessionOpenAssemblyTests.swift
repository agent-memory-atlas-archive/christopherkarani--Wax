import Foundation
import Testing
@testable import Wax

@Test
func sessionOpenAssemblyPassesThroughMissingHandoff() async {
    let missing = SessionHandoff(found: false)
    let compacted = await SessionOpenAssembly.compactHandoff(
        missing,
        recallQuery: "anything",
        tokenizer: .character
    )
    #expect(compacted == .object(["found": .bool(false)]))
}

@Test
func sessionOpenAssemblyHidesEmptyHandoffBody() async throws {
    let empty = SessionHandoff(found: true, content: "   ", pendingTasks: [])
    let compacted = await SessionOpenAssembly.compactHandoff(
        empty,
        recallQuery: nil,
        tokenizer: .character
    )
    let object = try #require(compacted.objectValue)
    #expect(object["found"]?.boolValue == false)
    #expect(object["relevance"]?.stringValue == "low")
    #expect(object["content"]?.stringValue == "")
    #expect(object["pending_tasks"]?.arrayValue == [])
    #expect(object["truncated"]?.boolValue == false)
}

@Test
func sessionOpenAssemblyNeedsTokenizerOnlyWhenHandoffHasBody() {
    #expect(SessionOpenAssembly.needsTokenizer(SessionHandoff(found: false)) == false)
    #expect(
        SessionOpenAssembly.needsTokenizer(
            SessionHandoff(found: true, content: "   ", pendingTasks: [])
        ) == false
    )
    #expect(
        SessionOpenAssembly.needsTokenizer(
            SessionHandoff(found: true, content: "keep", pendingTasks: [])
        ) == true
    )
    #expect(
        SessionOpenAssembly.needsTokenizer(
            SessionHandoff(found: true, content: "", pendingTasks: ["task"])
        ) == true
    )
}

@Test
func sessionOpenAssemblyTruncatesHandoffToTokenBudget() async throws {
    let content = String(repeating: "a", count: BrokerLimits.maxSessionOpenHandoffContentTokens + 40)
    let compacted = await SessionOpenAssembly.compactHandoff(
        SessionHandoff(found: true, content: content, pendingTasks: []),
        recallQuery: nil,
        tokenizer: .character
    )
    let object = try #require(compacted.objectValue)
    let compactContent = try #require(object["content"]?.stringValue)
    #expect(compactContent.count == BrokerLimits.maxSessionOpenHandoffContentTokens)
    #expect(object["content_truncated"]?.boolValue == true)
    #expect(object["truncated"]?.boolValue == true)
    #expect(object["content_tokens"]?.intValue == Int64(BrokerLimits.maxSessionOpenHandoffContentTokens))
}

@Test
func sessionOpenAssemblyCapsPendingTasksAndTaskBytes() async throws {
    let oversized = String(repeating: "t", count: BrokerLimits.maxSessionOpenPendingTaskBytes + 8)
    let tasks = (1...5).map { "task-\($0)-\(oversized)" }
    let compacted = await SessionOpenAssembly.compactHandoff(
        SessionHandoff(found: true, content: "keep", pendingTasks: tasks),
        recallQuery: nil,
        tokenizer: .character
    )
    let object = try #require(compacted.objectValue)
    let bounded = try #require(object["pending_tasks"]?.arrayValue)
    #expect(bounded.count == BrokerLimits.maxSessionOpenPendingTasks)
    #expect(object["pending_tasks_omitted"]?.intValue == 2)
    #expect(object["pending_tasks_truncated"]?.intValue == Int64(BrokerLimits.maxSessionOpenPendingTasks))
    for task in bounded {
        let text = try #require(task.stringValue)
        #expect(text.utf8.count <= BrokerLimits.maxSessionOpenPendingTaskBytes)
    }
}

@Test
func sessionOpenAssemblyMarksLowRelevanceForUnrelatedRecallQuery() async {
    let compacted = await SessionOpenAssembly.compactHandoff(
        SessionHandoff(
            found: true,
            content: "ship waxmcp 0.1.41 homebrew sha",
            pendingTasks: []
        ),
        recallQuery: "zzzz-unrelated-query-qqqq",
        tokenizer: .character
    )
    #expect(compacted.objectValue?["relevance"]?.stringValue == "low")
}

@Test
func sessionOpenAssemblyUtf8PrefixDoesNotSplitGrapheme() {
    let flag = "🇺🇸"
    #expect(SessionOpenAssembly.utf8Prefix(flag, maxBytes: 1).isEmpty)
    #expect(SessionOpenAssembly.utf8Prefix(flag + "x", maxBytes: flag.utf8.count) == flag)
    #expect(SessionOpenAssembly.utf8Prefix("abc", maxBytes: 2) == "ab")
}

@Test
func sessionOpenAssemblyBootstrapPayloadKeepsWireShape() throws {
    let sessionID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    let recall = AgentBrokerValue.object([
        "query": .string("q"),
        "warning": .string("hybrid fell back to text"),
    ])
    let payload = SessionOpenAssembly.bootstrapPayload(
        sessionID: sessionID,
        rebound: true,
        handoff: .object(["found": .bool(false)]),
        recall: recall
    )
    let object = try #require(payload.objectValue)
    #expect(Set(object.keys) == [
        "session_id", "rebound", "share_prompt", "handoff", "recall", "warning",
    ])
    #expect(object["session_id"]?.stringValue == sessionID.uuidString)
    #expect(object["rebound"]?.boolValue == true)
    #expect(object["share_prompt"]?.stringValue?.contains(sessionID.uuidString) == true)
    #expect(object["warning"]?.stringValue == "hybrid fell back to text")
}

@Test
func sessionOpenAssemblyBootstrapPayloadStringifiesUUIDOnWire() throws {
    let sessionID = UUID()
    let payload = SessionOpenAssembly.bootstrapPayload(
        sessionID: sessionID,
        rebound: false,
        handoff: .object(["found": .bool(false)]),
        recall: nil
    )
    let object = try #require(payload.objectValue)
    #expect(object["session_id"]?.stringValue == sessionID.uuidString)
}
