#if MCPServer
import Foundation
import MCP
import Testing
@testable import Wax
@testable import wax_mcp

struct MCPResponseVerbosityTests {
    @Test
    func mcpResponseVerbosityThrowsOnLoud() {
        do {
            _ = try WaxMCPTools.responseVerbosity(from: ["verbosity": .string("loud")])
            Issue.record("expected invalid verbosity to throw")
        } catch {
            #expect(error.localizedDescription == "verbosity must be one of: compact, verbose")
        }
    }

    @Test
    func mcpResponseVerbosityOmitsNilWhenMissing() throws {
        #expect(try WaxMCPTools.responseVerbosity(from: [:]) == nil)
    }

    @Test
    func mcpResponseVerbosityDecodesVerboseEnum() throws {
        #expect(try WaxMCPTools.responseVerbosity(from: ["verbosity": .string("verbose")]) == .verbose)
        #expect(try WaxMCPTools.responseVerbosity(from: ["verbosity": .string("compact")]) == .compact)
    }
}
#endif
