//
//  PrintQueueOwners.swift
//  Replicould — PrintQueueFeature
//
//  Which directive run ordered the print a bench is working. The queue
//  snapshot carries no id, so this can answer by bench and never by position.
//

import GameModels
import SQLiteData

/// Owning-run titles per bench device code, oldest job first.
struct PrintQueueOwners: FetchKeyRequest {
    typealias Value = [String: [String]]

    func fetch(_ db: Database) throws -> Value {
        let operations = try GameModels.Operation
            .where { $0.kind.eq(OperationKind.print.rawValue) && $0.status.in(OperationStatus.openCases) }
            .order { $0.startedAt }
            .fetchAll(db)
        let directives = try Directive.all.fetchAll(db)
        return Self.merge(operations: operations, directives: directives)
    }

    static func merge(operations: [GameModels.Operation], directives: [Directive]) -> Value {
        let byID = Dictionary(directives.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return operations
            .sorted { $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt < $1.startedAt }
            .reduce(into: Value()) { owners, op in
                guard op.status.isOpen, op.kind == OperationKind.print.rawValue,
                      let directiveID = op.directiveID, let directive = byID[directiveID]
                else { return }
                owners[op.entityCode, default: []].append(directive.kind.title)
            }
    }
}
