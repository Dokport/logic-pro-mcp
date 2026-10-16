struct SendChange: Equatable, Sendable {
    let before: SendEdge
    let after: SendEdge
}

struct RoutingEdgeChange: Equatable, Sendable {
    let before: RoutingEdge?
    let after: RoutingEdge?
}

struct RoutingDiff: Equatable, Sendable {
    let addedSends: [SendEdge]
    let removedSends: [SendEdge]
    let changedSends: [SendChange]
    let inputChanges: [RoutingEdgeChange]
    let outputChanges: [RoutingEdgeChange]
}

func routingDiff(before: RoutingGraph, after: RoutingGraph) -> RoutingDiff {
    let beforeSends = sendsBySlot(before.edges)
    let afterSends = sendsBySlot(after.edges)
    let sendKeys = Set(beforeSends.keys).union(afterSends.keys).sorted(by: sendKeyOrder)

    var addedSends: [SendEdge] = []
    var removedSends: [SendEdge] = []
    var changedSends: [SendChange] = []
    for key in sendKeys {
        switch (beforeSends[key], afterSends[key]) {
        case (nil, let added?):
            addedSends.append(added)
        case (let removed?, nil):
            removedSends.append(removed)
        case (let old?, let new?) where old != new:
            changedSends.append(SendChange(before: old, after: new))
        default:
            break
        }
    }

    return RoutingDiff(
        addedSends: addedSends,
        removedSends: removedSends,
        changedSends: changedSends,
        inputChanges: assignmentChanges(kind: .inputAssignment, before: before, after: after),
        outputChanges: assignmentChanges(kind: .mainOutput, before: before, after: after)
    )
}

private struct SendKey: Hashable {
    let source: TargetReference
    let physicalSlot: Int
}

private func sendsBySlot(_ edges: [RoutingEdge]) -> [SendKey: SendEdge] {
    var result: [SendKey: SendEdge] = [:]
    for edge in edges where edge.kind == .send {
        guard let send = edge.send else { continue }
        result[SendKey(source: send.sourceTrackRef, physicalSlot: send.physicalSlot)] = send
    }
    return result
}

private func sendKeyOrder(_ lhs: SendKey, _ rhs: SendKey) -> Bool {
    if lhs.source.rawValue != rhs.source.rawValue {
        return lhs.source.rawValue < rhs.source.rawValue
    }
    return lhs.physicalSlot < rhs.physicalSlot
}

private func assignmentChanges(
    kind: RoutingEdgeKind,
    before: RoutingGraph,
    after: RoutingGraph
) -> [RoutingEdgeChange] {
    let beforeEdges = assignmentsByOwner(kind: kind, edges: before.edges)
    let afterEdges = assignmentsByOwner(kind: kind, edges: after.edges)
    return Set(beforeEdges.keys)
        .union(afterEdges.keys)
        .sorted()
        .compactMap { owner in
            let old = beforeEdges[owner]
            let new = afterEdges[owner]
            guard old != new else { return nil }
            return RoutingEdgeChange(before: old, after: new)
        }
}

private func assignmentsByOwner(
    kind: RoutingEdgeKind,
    edges: [RoutingEdge]
) -> [String: RoutingEdge] {
    var result: [String: RoutingEdge] = [:]
    for edge in edges where edge.kind == kind {
        // An input is owned by its receiving strip, not its upstream Bus:
        // several receivers can share that Bus, and one receiver can change it.
        // Main-output assignments remain owned by their emitting source.
        let owner = kind == .inputAssignment ? edge.destination : edge.source
        result[owner] = edge
    }
    return result
}
