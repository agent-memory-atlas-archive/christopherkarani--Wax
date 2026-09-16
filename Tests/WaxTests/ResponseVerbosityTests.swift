import Foundation
import Testing
@testable import Wax

struct ResponseVerbosityTests {
    @Test
    func parseResponseVerbosityThrowsOnLoud() {
        #expect(
            throws: BrokerValidationError.invalid("verbosity must be one of: compact, verbose")
        ) {
            _ = try BrokerCommand.parseResponseVerbosity(
                BrokerArguments(["verbosity": .string("loud")])
            )
        }
    }

    @Test
    func brokerCommandDecodeRejectsLoudRecallVerbosity() {
        #expect(
            throws: BrokerValidationError.invalid("verbosity must be one of: compact, verbose")
        ) {
            _ = try BrokerCommand.decode(
                command: "recall",
                arguments: [
                    "query": .string("q"),
                    "verbosity": .string("loud"),
                ]
            )
        }
    }

    @Test
    func parseResponseVerbosityDefaultsOmittedToCompact() throws {
        #expect(try BrokerCommand.parseResponseVerbosity(BrokerArguments([:])) == .compact)
    }

    @Test
    func parseResponseVerbosityDecodesVerboseEnum() throws {
        let decoded = try BrokerCommand.decode(
            command: "recall",
            arguments: [
                "query": .string("q"),
                "verbosity": .string("verbose"),
            ]
        )
        guard case .recall(let recall) = decoded else {
            Issue.record("expected recall")
            return
        }
        #expect(recall.verbosity == .verbose)
        #expect(
            try BrokerCommand.parseResponseVerbosity(
                BrokerArguments(["verbosity": .string("compact")])
            ) == .compact
        )
    }
}
