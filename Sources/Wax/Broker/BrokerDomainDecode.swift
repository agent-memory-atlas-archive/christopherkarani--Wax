import Foundation
import WaxCore

extension KnowledgeGraphWrite {
    package static func decode(_ args: BrokerArguments) throws -> KnowledgeGraphWrite {
        let subject = Self.presentIdentifier(try args.optionalString("subject"))
        let predicate = Self.presentIdentifier(try args.optionalString("predicate"))
        let object: AgentBrokerValue?
        if let value = try args.optionalValue("object"), value != .null {
            object = value
        } else {
            object = nil
        }
        let aliases = try args.optionalStringArray("aliases") ?? []
        let kind = Self.resolvedKind(try args.optionalString("kind"))

        switch (subject, predicate, object) {
        case (nil, nil, nil):
            return .none
        case (let subject?, nil, nil):
            return .entity(key: EntityKey(subject), kind: kind, aliases: aliases)
        case (let subject?, let predicate?, let object?):
            return .fact(
                subject: EntityKey(subject),
                predicate: PredicateKey(predicate),
                object: try BrokerCommand.parseFactValue(object),
                kind: kind,
                aliases: aliases
            )
        case (nil, _, .some):
            throw BrokerValidationError.invalid("object requires subject and predicate")
        case (nil, .some, nil):
            throw BrokerValidationError.invalid("predicate requires subject")
        case (.some, nil, .some):
            throw BrokerValidationError.invalid("object requires subject and predicate")
        case (.some, .some, nil):
            throw BrokerValidationError.invalid("fact requires subject, predicate, and object")
        }
    }

    private static func presentIdentifier(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    private static func resolvedKind(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "concept" }
        return raw
    }
}

extension BrokerCommand {
    /// Wire JSON/string → ``FactValue``. Shared by `fact_assert` and
    /// `knowledge_capture` fact writes at decode.
    package static func parseFactValue(_ value: AgentBrokerValue) throws -> FactValue {
        switch value {
        case .string(let raw):
            return .string(raw)
        case .bool(let raw):
            return .bool(raw)
        case .int(let raw):
            return .int(raw)
        case .double(let raw):
            return .double(raw)
        case .object(let raw):
            if raw.count == 2,
               let type = raw["type"]?.stringValue,
               let genericValue = raw["value"] {
                switch type {
                case "entity":
                    guard let entity = genericValue.stringValue else {
                        throw BrokerValidationError.invalid("entity typed object value must be a string")
                    }
                    return .entity(EntityKey(entity))
                case "time_ms":
                    guard let time = genericValue.intValue else {
                        throw BrokerValidationError.invalid("time_ms typed object value must be an integer")
                    }
                    return .timeMs(time)
                case "data_base64":
                    guard let data = genericValue.stringValue, let decoded = Data(base64Encoded: data) else {
                        throw BrokerValidationError.invalid("data_base64 typed object value must be a base64 string")
                    }
                    return .data(decoded)
                default:
                    throw BrokerValidationError.invalid("typed object type must be one of: entity, time_ms, data_base64")
                }
            }
            if let entity = raw["entity"]?.stringValue, raw.count == 1 {
                return .entity(EntityKey(entity))
            }
            if let time = raw["time_ms"]?.intValue, raw.count == 1 {
                return .timeMs(time)
            }
            if let data = raw["data_base64"]?.stringValue, raw.count == 1, let decoded = Data(base64Encoded: data) {
                return .data(decoded)
            }
            throw BrokerValidationError.invalid("typed object values must be one of {entity}, {time_ms}, or {data_base64}")
        default:
            throw BrokerValidationError.invalid("object must be a string, number, bool, or typed object")
        }
    }

    package static func parseVersionRelation(_ raw: String) throws -> VersionRelation {
        guard let relation = VersionRelation(wireName: raw) else {
            throw BrokerValidationError.invalid("relation must be one of: sets, updates, extends, retracts")
        }
        return relation
    }
}
