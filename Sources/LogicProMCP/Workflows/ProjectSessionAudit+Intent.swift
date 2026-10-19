import Foundation
import MCP

// #966 P1 (ADR-021): a finite intent model over #28's audit and one deterministic rule.
//
// Everything here lives inside `ProjectSessionAudit` so the namespace is extended, not
// paralleled, and nothing here touches the legacy `Finding`, `buildAudit` or the cleanup plan: a
// #28 client keeps the wire contract ProjectSessionAuditTests pins. The assessor consumes a #965
// `Capture` and the #291 `RoutingGraph` published from that same capture as immutable data. It
// never sees a cache, a router, a registry or the host, and the same inputs always encode to the
// same bytes.
//
// What the rule reads: the capture's boundaries and issued references, the graph's snapshot id,
// project reference, consistency, epoch and the `main_output` / `strip_track_association` coverage
// states, the source node found by `targetRef`, its `outputClassification`, its `.mainOutput` edges
// and the destination's `busNumber`. Each node and captured row it looks up must match exactly
// once: `isConsistent` skips its duplicate-id check on a partial graph, and a partial `sends`
// domain makes a graph partial while the two domains read here stay complete. What it never
// reads: a track name, type or output label, a coverage reason string, any `SendEdge` field, a
// `.send` or `.inputAssignment` edge, a level, an enabled flag, or a track's automation or mute
// state. ADR-021 section 2: none of those proves a route right, and none proves a connection
// absent. `displayName` and the coverage reasons are copied into the finding as evidence for the
// reader; no decision is taken on them.

extension ProjectSessionAudit {
    static let intentPolicySchema = "logic_pro_mcp_repair_policy.v1"
    static let intentAssessmentSchema = "logic_pro_mcp_intent_assessment.v1"
    static let mainOutputAssignmentRule = "main_output_assignment"

    // MARK: - Approved intent (input)

    /// An exact issued target. A physical Mixer naming origin keeps its original reference until
    /// a retained #965 pair resolves the existing coupled Track action; it grants no Track routing
    /// authority. `handle` is local to the policy, never a host name or an ordinal identity.
    struct IntentTarget: Equatable, Sendable {
        let handle: String
        let trackRef: TargetReference
        /// A physical naming origin, retained even after its captured pair resolves a Track action.
        let mixerRef: TargetReference?

        init(handle: String, trackRef: TargetReference, mixerRef: TargetReference? = nil) {
            self.handle = handle; self.trackRef = trackRef; self.mixerRef = mixerRef
        }
    }

    struct IntentRoleMember: Equatable, Sendable {
        let handle: String
        let accepted: Bool
    }

    /// A proposed role. Members the client has not accepted are candidates, and a role with no
    /// accepted member stays a question (ADR-021 section 2): the rule never picks one from a name.
    struct IntentRole: Equatable, Sendable {
        let role: String
        let members: [IntentRoleMember]
    }

    enum IntentSubject: Equatable, Sendable {
        case target(String)
        case role(String)
    }

    /// Where a subject's main output is meant to go: an existing bus, or deliberately nowhere. P1
    /// uses #291's supported bus-number range. Allocation/availability remains observed evidence
    /// #291/#967 own, not a guess made here.
    enum IntentMainOutput: Hashable, Sendable {
        case bus(Int)
        case noOutput
        case physical(Int, Int)
        case stereoOutput

        /// The wire form a conflict is reported and sorted by.
        var token: String {
            switch self {
            case .bus(let number): return "bus_\(number)"
            case .noOutput: return RoutingOutputClassification.noOutput.rawValue
            case .physical(let first, let second): return "physical:\(first)-\(second)"
            case .stereoOutput: return "stereo_output"
            }
        }

        /// `no_output` before every bus, buses ascending.
        static func ordered(_ outputs: Set<IntentMainOutput>) -> [IntentMainOutput] {
            outputs.sorted { lhs, rhs in
                switch (lhs, rhs) {
                case (.noOutput, .bus): return true
                case (.bus, .noOutput): return false
                case (.bus(let left), .bus(let right)): return left < right
                default: return lhs.token < rhs.token
                }
            }
        }
    }

    struct IntentOutput: Equatable, Sendable {
        let subject: IntentSubject
        let destination: IntentMainOutput
    }

    struct IntentInput: Encodable, Equatable, Sendable {
        let target: String
        let bus: Int
    }

    /// Physical slots and observed source-census ordinals are distinct selectors. Neither is
    /// native write authority. Removal is explicit, never inferred from a scalar or nil bus.
    struct IntentSend: Equatable, Encodable, Sendable {
        enum Selector: Hashable, Sendable {
            case physicalSlot(Int)
            case observedOrdinal(Int)
        }
        enum Destination: Equatable, Sendable {
            case bus(Int)
            case physical(Int, Int)
            case stereoOutput
            case remove
        }
        let target: String
        let selector: Selector
        let destination: Destination
        var bus: Int? { if case .bus(let value) = destination { value } else { nil } }
        var localOutput: OutputAssignment? {
            switch destination {
            case .physical(let first, let second): .physical(first, second)
            case .stereoOutput: .stereoOutput
            default: nil
            }
        }
        var isRemoval: Bool { destination == .remove }
        var destinationValue: Value {
            switch destination {
            case .bus(let number): .object(["kind": .string("bus"), "number": .int(number)])
            case .physical(let first, let second): .object(["kind": .string("physical"), "ports": .array([.int(first), .int(second)])])
            case .stereoOutput: .object(["kind": .string("stereo_output")])
            case .remove: .object(["kind": .string("no_send")])
            }
        }
        var physicalSlot: Int? { if case .physicalSlot(let value) = selector { value } else { nil } }
        var observedOrdinal: Int? { if case .observedOrdinal(let value) = selector { value } else { nil } }
        var selectorID: String {
            switch selector {
            case .physicalSlot(let value): "slot.\(value)"
            case .observedOrdinal(let value): "ordinal.\(value)"
            }
        }
        init(target: String, selector: Selector, bus: Int?) {
            self.init(target: target, selector: selector, destination: bus.map(Destination.bus) ?? .remove)
        }
        init(target: String, selector: Selector, destination: Destination) {
            self.target = target; self.selector = selector; self.destination = destination
        }
        init(target: String, physicalSlot: Int, bus: Int?) {
            self.init(target: target, selector: .physicalSlot(physicalSlot), bus: bus)
        }

        enum CodingKeys: String, CodingKey {
            case target, bus, remove, output
            case physicalSlot = "physical_slot", observedOrdinal = "observed_ordinal"
        }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(target, forKey: .target)
            try container.encodeIfPresent(physicalSlot, forKey: .physicalSlot)
            try container.encodeIfPresent(observedOrdinal, forKey: .observedOrdinal)
            switch destination {
            case .bus(let number): try container.encode(number, forKey: .bus)
            case .physical, .stereoOutput: try container.encode(destinationValue, forKey: .output)
            case .remove: try container.encode(true, forKey: .remove)
            }
        }
    }

    struct IntentSort: Equatable, Sendable {
        let criterion: TrackSortCriterion
        let expectedOrder: [String]
        let inverseCriterion: TrackSortCriterion
    }

    /// Preserve structural connectivity to this exact node in the bound routing capture. A node
    /// ID is not a label, a guessed port, write authority, or a claim of audible signal.
    struct IntentProtectedPath: Equatable, Hashable, Sendable {
        let target: String
        let sinkNodeID: String
    }

    /// Only `parseIntentPolicy` constructs this, so `assessIntent` never sees an unvalidated policy.
    /// `projectRef`, when present, is the project the policy was written for.
    struct IntentPolicy: Equatable, Sendable {
        let projectRef: TargetReference?
        let targets: [IntentTarget]
        let roles: [IntentRole]
        let outputs: [IntentOutput]
        let inputs: [IntentInput]
        let sends: [IntentSend]
        /// The approved receiving-aux intent per bus (#1090 review R3, R1090-004): an output
        /// approves only the bus a track feeds, not what reads that bus. `.new` approves planning a
        /// new aux that reads it; `.keep` approves the observed receivers; `.noReceiver` (wire `none`) says nothing is meant to read it (a sidechain-only bus).
        let receivers: [Int: IntentReceiver]
        let mixerVisible: Bool?
        let trackSort: IntentSort?
        let protectedPaths: [IntentProtectedPath]

        fileprivate init(
            projectRef: TargetReference?,
            targets: [IntentTarget],
            roles: [IntentRole],
            outputs: [IntentOutput],
            inputs: [IntentInput] = [],
            sends: [IntentSend] = [],
            receivers: [Int: IntentReceiver] = [:],
            mixerVisible: Bool? = nil,
            trackSort: IntentSort? = nil,
            protectedPaths: [IntentProtectedPath] = []
        ) {
            self.projectRef = projectRef
            self.targets = targets
            self.roles = roles
            self.outputs = outputs
            self.inputs = inputs
            self.sends = sends
            self.receivers = receivers
            self.mixerVisible = mixerVisible
            self.trackSort = trackSort
            self.protectedPaths = protectedPaths
        }
    }

    enum IntentReceiver: String, Equatable, Sendable {
        case new
        case noReceiver = "none"
        /// The receivers observed reading the bus are the intended ones.
        case keep
    }

    enum IntentPolicyRejection: Equatable, Sendable {
        case unsupportedSchema(String)
        case unknownKey(path: String, key: String)
        case missingKey(path: String, key: String)
        case wrongType(path: String, expected: String)
        case invalidHandle(path: String)
        case duplicateHandle(String)
        case duplicateTrackRef(String)
        case unsupportedTargetRef(handle: String, ref: String)
        case unsupportedProjectRef(String)
        case unknownSubject(path: String, subject: String)
        case outputNamesBothOrNeither(path: String)
        case outputDestinationBothOrNeither(path: String)
        case unsupportedOutput(path: String, value: String)
        case conflictingOutputs(subject: String, outputs: [IntentMainOutput])
        case busBelowOne(path: String, value: Int)
        case busOutOfRange(path: String, value: Int)
        case duplicateReceiver(bus: Int)
        case unsupportedSortCriterion(path: String, value: String)
        case invalidSortOrder(path: String)
        case sendDestinationBothOrNeither(path: String)
        case sendSelectorBothOrNeither(path: String)
        case sendRemovalMustBeTrue(path: String)
        case sendSlotOutOfRange(path: String, value: Int)
        case duplicateSend(target: String, slot: Int)
        case duplicateInput(target: String)
        case invalidProtectedPath(path: String)

        /// The deterministic form the rejection list is sorted by.
        var sortKey: String {
            switch self {
            case .unsupportedSchema(let schema):
                return "unsupported_schema \(schema)"
            case .unknownKey(let path, let key):
                return "unknown_key \(path).\(key)"
            case .missingKey(let path, let key):
                return "missing_key \(path).\(key)"
            case .wrongType(let path, let expected):
                return "wrong_type \(path) expected \(expected)"
            case .invalidHandle(let path):
                return "invalid_handle \(path)"
            case .duplicateHandle(let handle):
                return "duplicate_handle \(handle)"
            case .duplicateTrackRef(let ref):
                return "duplicate_track_ref \(ref)"
            case .unsupportedTargetRef(let handle, let ref):
                return "unsupported_target_ref \(handle) \(ref)"
            case .unsupportedProjectRef(let ref):
                return "unsupported_project_ref \(ref)"
            case .unknownSubject(let path, let subject):
                return "unknown_subject \(path) \(subject)"
            case .outputNamesBothOrNeither(let path):
                return "output_names_both_or_neither \(path)"
            case .outputDestinationBothOrNeither(let path):
                return "output_destination_both_or_neither \(path)"
            case .unsupportedOutput(let path, let value):
                return "unsupported_output \(path) \(value)"
            case .conflictingOutputs(let subject, let outputs):
                return "conflicting_outputs \(subject) \(outputs.map(\.token))"
            case .busBelowOne(let path, let value):
                return "bus_below_one \(path) \(value)"
            case .busOutOfRange(let path, let value):
                return "bus_out_of_range \(path) \(value)"
            case .duplicateReceiver(let bus):
                return "duplicate_receiver bus \(bus)"
            case .unsupportedSortCriterion(let path, let value):
                return "unsupported_sort_criterion \(path) \(value)"
            case .invalidSortOrder(let path):
                return "invalid_sort_order \(path)"
            case .sendDestinationBothOrNeither(let path): return "send_destination_both_or_neither \(path)"
            case .sendSelectorBothOrNeither(let path): return "send_selector_both_or_neither \(path)"
            case .sendRemovalMustBeTrue(let path): return "send_removal_must_be_true \(path)"
            case .sendSlotOutOfRange(let path, let value): return "send_slot_out_of_range \(path) \(value)"
            case .duplicateSend(let target, let slot): return "duplicate_send \(target) \(slot)"
            case .duplicateInput(let target): return "duplicate_input \(target)"
            case .invalidProtectedPath(let path): return "invalid_protected_path \(path)"
            }
        }
    }

    enum IntentPolicyParse: Equatable, Sendable {
        case accepted(IntentPolicy)
        case rejected([IntentPolicyRejection])
    }

    // MARK: - Assessment (output)

    enum IntentStatus: String, Codable, Sendable {
        case compliant
        case violation
        case needsInput = "needs_input"
        case unverified
        case outsideScope = "outside_scope"
    }

    /// Every P1 finding rests on `approved_policy`. The other two are declared so a later phase
    /// keeps observed facts, approved intent and preference distinguishable on the wire.
    enum IntentBasis: String, Codable, Sendable {
        case observedStructure = "observed_structure"
        case approvedPolicy = "approved_policy"
        case preference
    }

    enum IntentReason: String, Codable, Sendable {
        // Capture and graph validity: the graph cannot be read against this capture at all.
        case cacheMovedDuringCapture = "cache_moved_during_capture"
        case graphNotFromCapture = "graph_not_from_capture"
        case graphProjectMismatch = "graph_project_mismatch"
        case routingGraphInconsistent = "routing_graph_inconsistent"
        case noDocument = "no_document"
        case axOccluded = "ax_occluded"
        // The policy's project and the target's reference.
        case projectReferenceUnavailable = "project_reference_unavailable"
        case policyProjectMismatch = "policy_project_mismatch"
        case referencesUnavailable = "references_unavailable"
        case targetSnapshotStale = "target_snapshot_stale"
        case targetNotInSnapshot = "target_not_in_snapshot"
        case targetAmbiguousInSnapshot = "target_ambiguous_in_snapshot"
        case graphEpochMismatch = "graph_epoch_mismatch"
        // Domain coverage: compliant and violation need both domains complete.
        case mainOutputCoverageIncomplete = "main_output_coverage_incomplete"
        case stripTrackAssociationIncomplete = "strip_track_association_incomplete"
        // The source's own output.
        case trackNotInGraph = "track_not_in_graph"
        case sourceNodeAmbiguous = "source_node_ambiguous"
        case sourceNodeNotTrack = "source_node_not_track"
        case outputUnclassified = "output_unclassified"
        case outputEdgeAmbiguous = "output_edge_ambiguous"
        case outputDestinationAmbiguous = "output_destination_ambiguous"
        case expectedBusNotObserved = "expected_bus_not_observed"
        case roleHasNoAcceptedMember = "role_has_no_accepted_member"
        case sendCoverageIncomplete = "send_coverage_incomplete"
        case populationCoverageIncomplete = "population_coverage_incomplete"
        case sendSlotAmbiguous = "send_slot_ambiguous"
        case sendEndpointUnverified = "send_endpoint_unverified"
        case sendScalarUnserializable = "send_scalar_unserializable"
    }

    enum IntentAspect: String, Codable, Sendable {
        case sends
        case sidechain
        case monitoring

        /// The main-output rule reads none of these: #291 publishes no send edge (send slots
        /// answer occupancy, not destination), and sidechain and monitoring have no reader at all.
        /// Every finding names all three as not verified, so a consumer cannot mistake silence for
        /// coverage.
        static let withoutObservationSource: [IntentAspect] = [.sends, .sidechain, .monitoring]
    }

    /// `main_output` and `strip_track_association` are the graph's two domain coverages copied
    /// verbatim, reasons included, as evidence: the status reads their `state` only.
    /// `expected_bus_observed` is absent when the policy expects no output.
    struct IntentCoverage: Encodable, Equatable, Sendable {
        let outputEdgeObserved: Bool
        let destinationBusObserved: Bool
        let expectedBusObserved: Bool?
        let graphComplete: Bool
        let mainOutput: RoutingDomainCoverage
        let stripTrackAssociation: RoutingDomainCoverage
        let notVerified: [IntentAspect]

        enum CodingKeys: String, CodingKey {
            case outputEdgeObserved = "output_edge_observed"
            case destinationBusObserved = "destination_bus_observed"
            case expectedBusObserved = "expected_bus_observed"
            case graphComplete = "graph_complete"
            case mainOutput = "main_output"
            case stripTrackAssociation = "strip_track_association"
            case notVerified = "not_verified"
        }
    }

    /// `expected` carries `output` (`bus` with its `bus_number`, or `no_output`) and no node
    /// fields: intent names a bus, not a node. `observed` carries the source's classified `output`
    /// and, for a bus, the destination node the one `mainOutput` edge reaches.
    struct IntentEndpoint: Encodable, Equatable, Sendable {
        let nodeId: String?
        let displayName: String?
        let busNumber: Int?
        let output: RoutingOutputClassification
        var kind: String? = nil
        var ports: [Int]? = nil

        enum CodingKeys: String, CodingKey {
            case nodeId = "node_id"
            case displayName = "display_name"
            case busNumber = "bus_number"
            case output, kind, ports
        }

        static func expected(_ destination: IntentMainOutput) -> IntentEndpoint {
            switch destination {
            case .bus(let number):
                return IntentEndpoint(nodeId: nil, displayName: nil, busNumber: number, output: .bus)
            case .noOutput:
                return IntentEndpoint(nodeId: nil, displayName: nil, busNumber: nil, output: .noOutput)
            case .physical(let first, let second):
                return IntentEndpoint(nodeId: nil, displayName: nil, busNumber: nil, output: .physicalOutput,
                    kind: "physical", ports: [first, second])
            case .stereoOutput:
                return IntentEndpoint(nodeId: nil, displayName: nil, busNumber: nil, output: .physicalOutput,
                    kind: "stereo_output")
            }
        }
    }

    struct IntentTargetEvidence: Encodable, Equatable, Sendable {
        let handle: String?
        let role: String?
        let trackRef: String?
        let trackIndex: Int?

        enum CodingKeys: String, CodingKey {
            case handle
            case role
            case trackRef = "track_ref"
            case trackIndex = "track_index"
        }
    }

    struct IntentFinding: Encodable, Equatable, Sendable {
        let id: String
        let rule: String
        let basis: IntentBasis
        let severity: Severity
        let status: IntentStatus
        let target: IntentTargetEvidence
        let observed: IntentEndpoint?
        let expected: IntentEndpoint
        let coverage: IntentCoverage
        let reasons: [IntentReason]
    }

    struct IntentCandidate: Encodable, Equatable, Sendable {
        let handle: String
        let trackRef: String

        enum CodingKeys: String, CodingKey {
            case handle
            case trackRef = "track_ref"
        }
    }

    /// Candidates are the role's unaccepted members as the client proposed them, less any whose
    /// reference the capture did not issue for exactly one row. No track name, type or label is
    /// consulted to add or remove one.
    struct IntentQuestion: Encodable, Equatable, Sendable {
        let id: String
        let role: String
        let rule: String
        let expected: IntentEndpoint
        let candidates: [IntentCandidate]
    }

    struct IntentAssessment: Encodable, Equatable, Sendable {
        let schema: String
        let readOnly: Bool
        let snapshotId: String
        let projectEpoch: UInt64
        let graphProjectEpoch: UInt64
        let findings: [IntentFinding]
        let questions: [IntentQuestion]
        let changeRequired: Bool
        /// Omitted for old policies, preserving their assessment wire shape.
        var sendFindings: [IntentSendFinding]? = nil
        var inputFindings: [IntentInputFinding]? = nil

        enum CodingKeys: String, CodingKey {
            case schema
            case readOnly = "read_only"
            case snapshotId = "snapshot_id"
            case projectEpoch = "project_epoch"
            case graphProjectEpoch = "graph_project_epoch"
            case findings
            case questions
            case changeRequired = "change_required"
            case sendFindings = "send_findings"
            case inputFindings = "input_findings"
        }
    }

    struct IntentInputFinding: Encodable, Equatable, Sendable {
        let id: String
        let rule = "input_assignment"
        let basis = IntentBasis.approvedPolicy
        let status: IntentStatus
        let target: IntentTargetEvidence
        let observed: Value?
        let expected: IntentInput
        let reasons: [String]
    }

    struct IntentSendFinding: Encodable, Equatable, Sendable {
        let id: String
        let rule = "send_assignment"
        let basis = IntentBasis.approvedPolicy
        let severity: Severity
        let status: IntentStatus
        let target: IntentTargetEvidence
        let physicalSlot: Int?
        let observedOrdinal: Int?
        let observed: RoutingEdge?
        let expected: IntentSend
        let coverage: RoutingCoverage
        let notVerified: [IntentAspect] = [.sidechain, .monitoring]
        let reasons: [IntentReason]

        enum CodingKeys: String, CodingKey {
            case id, rule, basis, severity, status, target, observed, expected, coverage, reasons
            case physicalSlot = "physical_slot"
            case observedOrdinal = "observed_ordinal"
            case notVerified = "not_verified"
        }
    }

    // MARK: - Policy parsing

    private static let maxHandleBytes = 128
    private static let trackReferencePrefix = "trk_"
    private static let projectReferencePrefix = "prj_"

    /// Parses a wire policy. Every rejection is collected, so a client sees the whole list at
    /// once, and the list is sorted by `sortKey` so two parses of one object are equal.
    static func parseIntentPolicy(_ object: [String: Value]) -> IntentPolicyParse {
        var rejections: [IntentPolicyRejection] = []
        rejectUnknownKeys(
            object,
            allowed: ["schema", "project_ref", "targets", "roles", "outputs", "inputs", "sends", "receivers", "presentation", "protected_paths"],
            path: "policy",
            into: &rejections
        )

        if let rawSchema = object["schema"] {
            if let schema = rawSchema.stringValue {
                if schema != intentPolicySchema {
                    rejections.append(.unsupportedSchema(schema))
                }
            } else {
                rejections.append(.wrongType(path: "policy.schema", expected: "string"))
            }
        } else {
            rejections.append(.missingKey(path: "policy", key: "schema"))
        }

        let projectRef = optionalString(object, key: "project_ref", path: "policy", into: &rejections)
        if let projectRef, !projectRef.hasPrefix(projectReferencePrefix) {
            rejections.append(.unsupportedProjectRef(projectRef))
        }
        let targets = parseTargets(object, into: &rejections)
        let roles = parseRoles(object, into: &rejections)
        let outputs = parseOutputs(object, into: &rejections)
        let inputs = parseInputs(object, targets: targets, into: &rejections)
        let sends = parseSends(object, targets: targets, into: &rejections)
        let receivers = parseReceivers(object, into: &rejections)
        let protectedPaths = parseProtectedPaths(object, targets: targets, into: &rejections)
        var mixerVisible: Bool?
        var trackSort: IntentSort?
        if let raw = object["presentation"] {
            if let presentation = raw.objectValue {
                rejectUnknownKeys(presentation, allowed: ["mixer_visible", "sort"], path: "policy.presentation", into: &rejections)
                if presentation["mixer_visible"] != nil || presentation["sort"] == nil {
                    mixerVisible = requiredBool(presentation, key: "mixer_visible", path: "policy.presentation", into: &rejections)
                }
                if let sort = presentation["sort"] {
                    trackSort = parseIntentSort(sort, into: &rejections)
                }
            } else {
                rejections.append(.wrongType(path: "policy.presentation", expected: "object"))
            }
        }
        validate(targets: targets, roles: roles, outputs: outputs, into: &rejections)
        // Mixer origins contribute only names, never Track routing/role or presentation authority.
        if !roles.isEmpty || !outputs.isEmpty || !inputs.isEmpty || !sends.isEmpty || !receivers.isEmpty
            || !protectedPaths.isEmpty || mixerVisible != nil || trackSort != nil {
            for target in targets where target.mixerRef != nil {
                rejections.append(.unsupportedTargetRef(handle: target.handle, ref: target.trackRef.rawValue))
            }
        }

        guard rejections.isEmpty else {
            var unique: [IntentPolicyRejection] = []
            for rejection in rejections.sorted(by: { $0.sortKey < $1.sortKey }) where !unique.contains(rejection) {
                unique.append(rejection)
            }
            return .rejected(unique)
        }
        return .accepted(IntentPolicy(
            projectRef: projectRef.map(TargetReference.init(rawValue:)),
            targets: targets,
            roles: roles,
            outputs: outputs,
            inputs: inputs,
            sends: sends,
            receivers: receivers,
            mixerVisible: mixerVisible,
            trackSort: trackSort,
            protectedPaths: protectedPaths
        ))
    }

    private static func parseInputs(_ object: [String: Value], targets: [IntentTarget],
                                    into rejections: inout [IntentPolicyRejection]) -> [IntentInput] {
        guard let raw = object["inputs"] else { return [] }
        guard let entries = raw.arrayValue, entries.count <= 32 else {
            rejections.append(.wrongType(path: "policy.inputs", expected: "array of at most 32 inputs"))
            return []
        }
        var seen = Set<String>()
        var result: [IntentInput] = []
        for (index, value) in entries.enumerated() {
            let path = "policy.inputs[\(index)]"
            guard let entry = value.objectValue else {
                rejections.append(.wrongType(path: path, expected: "object")); continue
            }
            rejectUnknownKeys(entry, allowed: ["target", "bus"], path: path, into: &rejections)
            guard let target = requiredString(entry, key: "target", path: path, into: &rejections),
                  let bus = requiredInt(entry, key: "bus", path: path, into: &rejections) else { continue }
            guard targets.contains(where: { $0.handle == target }) else {
                rejections.append(.unknownSubject(path: path, subject: target)); continue
            }
            guard validateIntentBus(bus, path: "\(path).bus", into: &rejections) else { continue }
            guard seen.insert(target).inserted else {
                rejections.append(.duplicateInput(target: target)); continue
            }
            result.append(.init(target: target, bus: bus))
        }
        return result.sorted { $0.target < $1.target }
    }

    /// At most 64 explicit target/sink pairs; the graph, not this syntax, supplies their identity
    /// and observation. Missing/foreign/duplicate constraints never disappear into a partial plan.
    private static func parseProtectedPaths(_ object: [String: Value], targets: [IntentTarget],
                                            into rejections: inout [IntentPolicyRejection]) -> [IntentProtectedPath] {
        guard let raw = object["protected_paths"] else { return [] }
        guard let entries = raw.arrayValue else {
            rejections.append(.wrongType(path: "policy.protected_paths", expected: "array")); return []
        }
        guard entries.count <= 64 else {
            rejections.append(.invalidProtectedPath(path: "policy.protected_paths")); return []
        }
        var result = Set<IntentProtectedPath>()
        for (index, rawEntry) in entries.enumerated() {
            let path = "policy.protected_paths[\(index)]"
            guard let entry = rawEntry.objectValue else {
                rejections.append(.wrongType(path: path, expected: "object")); continue
            }
            rejectUnknownKeys(entry, allowed: ["target", "sink_node_id"], path: path, into: &rejections)
            guard let target = requiredString(entry, key: "target", path: path, into: &rejections),
                  let sink = requiredString(entry, key: "sink_node_id", path: path, into: &rejections) else { continue }
            guard targets.contains(where: { $0.handle == target }) else {
                rejections.append(.unknownSubject(path: path, subject: target)); continue
            }
            guard isValidHandle(sink) else {
                rejections.append(.invalidProtectedPath(path: path)); continue
            }
            guard result.insert(.init(target: target, sinkNodeID: sink)).inserted else {
                rejections.append(.invalidProtectedPath(path: path)); continue
            }
        }
        return result.sorted { $0.target == $1.target ? $0.sinkNodeID < $1.sinkNodeID : $0.target < $1.target }
    }

    private static func parseIntentSort(_ value: Value, into rejections: inout [IntentPolicyRejection]) -> IntentSort? {
        let path = "policy.presentation.sort"
        guard let object = value.objectValue else {
            rejections.append(.wrongType(path: path, expected: "object"))
            return nil
        }
        rejectUnknownKeys(object, allowed: ["criterion", "expected_order", "inverse_criterion"], path: path, into: &rejections)
        func criterion(_ key: String) -> TrackSortCriterion? {
            guard let raw = requiredString(object, key: key, path: path, into: &rejections) else { return nil }
            guard let criterion = TrackSortCriterion(rawValue: raw) else {
                rejections.append(.unsupportedSortCriterion(path: "\(path).\(key)", value: raw))
                return nil
            }
            return criterion
        }
        let forward = criterion("criterion")
        let inverse = criterion("inverse_criterion")
        guard let rawOrder = object["expected_order"] else {
            rejections.append(.missingKey(path: path, key: "expected_order"))
            return nil
        }
        guard let values = rawOrder.arrayValue, values.allSatisfy({ $0.stringValue != nil }) else {
            rejections.append(.wrongType(path: "\(path).expected_order", expected: "array of track references"))
            return nil
        }
        let references = values.compactMap(\.stringValue)
        guard !references.isEmpty, Set(references).count == references.count,
              references.allSatisfy({ $0.hasPrefix(trackReferencePrefix) }) else {
            rejections.append(.invalidSortOrder(path: "\(path).expected_order"))
            return nil
        }
        guard let forward, let inverse else { return nil }
        return .init(criterion: forward, expectedOrder: references, inverseCriterion: inverse)
    }

    /// Optional `receivers`: supported bus number and `aux: new|keep|none`, at most one per bus.
    private static func parseReceivers(
        _ object: [String: Value],
        into rejections: inout [IntentPolicyRejection]
    ) -> [Int: IntentReceiver] {
        guard let raw = object["receivers"] else { return [:] }
        guard let array = raw.arrayValue else {
            rejections.append(.wrongType(path: "policy.receivers", expected: "array"))
            return [:]
        }
        var receivers: [Int: IntentReceiver] = [:]
        for (index, element) in array.enumerated() {
            let path = "policy.receivers[\(index)]"
            guard let entry = element.objectValue else {
                rejections.append(.wrongType(path: path, expected: "object"))
                continue
            }
            rejectUnknownKeys(entry, allowed: ["bus", "aux"], path: path, into: &rejections)
            let bus = requiredInt(entry, key: "bus", path: path, into: &rejections)
            let word = requiredString(entry, key: "aux", path: path, into: &rejections)
            guard let bus, let word else { continue }
            guard validateIntentBus(bus, path: "\(path).bus", into: &rejections) else { continue }
            guard let receiver = IntentReceiver(rawValue: word) else {
                rejections.append(.unsupportedOutput(path: "\(path).aux", value: word))
                continue
            }
            if receivers[bus] != nil {
                rejections.append(.duplicateReceiver(bus: bus))
                continue
            }
            receivers[bus] = receiver
        }
        return receivers
    }

    private static func validateIntentBus(_ number: Int, path: String,
                                          into rejections: inout [IntentPolicyRejection]) -> Bool {
        guard number >= 1 else {
            rejections.append(.busBelowOne(path: path, value: number)); return false
        }
        guard OutputAssignment.busNumbers.contains(number) else {
            rejections.append(.busOutOfRange(path: path, value: number)); return false
        }
        return true
    }

    private static func parseTargets(
        _ object: [String: Value],
        into rejections: inout [IntentPolicyRejection]
    ) -> [IntentTarget] {
        guard let rawTargets = object["targets"] else {
            rejections.append(.missingKey(path: "policy", key: "targets"))
            return []
        }
        guard let array = rawTargets.arrayValue else {
            rejections.append(.wrongType(path: "policy.targets", expected: "array"))
            return []
        }
        var targets: [IntentTarget] = []
        for (index, element) in array.enumerated() {
            let path = "policy.targets[\(index)]"
            guard let entry = element.objectValue else {
                rejections.append(.wrongType(path: path, expected: "object"))
                continue
            }
            let mixerOrigin = entry["mixer_ref"] != nil
            let referenceKey = mixerOrigin ? "mixer_ref" : "track_ref"
            rejectUnknownKeys(entry, allowed: ["handle", referenceKey], path: path, into: &rejections)
            let handle = requiredString(entry, key: "handle", path: path, into: &rejections)
            let trackRef = requiredString(entry, key: referenceKey, path: path, into: &rejections)
            guard let handle, let trackRef else { continue }
            let reference = TargetReference(rawValue: trackRef)
            targets.append(IntentTarget(handle: handle, trackRef: reference, mixerRef: mixerOrigin ? reference : nil))
        }
        return targets
    }

    /// Resolve only a producer-retained physical pair into the already qualified coupled Track
    /// action. Mixer indices, equal labels and caller JSON cannot create or renew this association.
    static func normalizedMixerNaming(
        policy: IntentPolicy, names: [ApprovedName], capture: SessionPopulationObservation.Capture,
        request: SessionPopulationObservation.Request
    ) -> (policy: IntentPolicy, reasons: [String: String]) {
        guard policy.targets.contains(where: { $0.mixerRef != nil }) else { return (policy, [:]) }
        var targets = policy.targets
        var reasons: [String: String] = [:]
        for index in targets.indices {
            let original = targets[index]
            guard let mixerRef = original.mixerRef else { continue }
            reasons[original.handle] = "mixer_name_association_unverified"
            guard request.domains.contains(.tracks), request.domains.contains(.strips),
                  request.domains.contains(.associations), capture.referencesEnabled, !capture.referencesStale,
                  capture.before == capture.after, !capture.before.axOccluded,
                  capture.requestedProjectMatches != false,
                  let fresh = capture.freshPopulation, fresh.stable, fresh.uiEffects.restoration == "restored",
                  case .issued(let project)? = capture.projectIssuance, policy.projectRef == project,
                  let issued = capture.issued, let path = capture.project.filePath,
                  let desired = names.first(where: { $0.target == original.handle }) else { continue }
            let stripRows = capture.channelStrips.indices.filter { capture.mixerReference(at: $0) == mixerRef }
            guard stripRows.count == 1, let stripRow = stripRows.first,
                  let strip = capture.channelStrips[stripRow].physicalBinding,
                  strip.projectPath?.utf8.elementsEqual(path.utf8) == true else { continue }
            let pairs = fresh.selectionAssociations.filter { $0.strip.matches(strip) }
            guard pairs.count == 1, let pair = pairs.first,
                  fresh.selectionAssociations.filter({ $0.track.matches(pair.track) }).count == 1,
                  CFEqual(pair.track.window, pair.strip.window),
                  pair.track.document.utf8.elementsEqual(pair.strip.document.utf8) else { continue }
            let rows = capture.tracks.filter { $0.physicalBinding?.matches(pair.track) == true }
            guard rows.count == 1, let track = rows.first,
                  let reference = issued.byTrackIndex[track.id],
                  case .located(let located) = locate(reference, in: issued), located == track.id else { continue }
            guard ExactTrackNameAdapter.hasCapturedCoupledFootprint(.init(projectReference: project,
                targetReference: reference, expectedBefore: track.name, desiredAfter: desired.name), capture: capture) else {
                reasons[original.handle] = "mixer_name_coupled_footprint_unavailable"
                continue
            }
            targets[index] = .init(handle: original.handle, trackRef: reference, mixerRef: mixerRef)
            reasons.removeValue(forKey: original.handle)
        }
        // Two declarations of the same actual pair remain two rejected tasks, not two writes or
        // a silently collapsed instruction, even when their approved strings happen to agree.
        for aliases in Dictionary(grouping: targets, by: \.trackRef).values
            where aliases.count > 1 && aliases.contains(where: { $0.mixerRef != nil }) {
            for target in aliases { reasons[target.handle] = "naming_target_alias_conflict" }
        }
        return (IntentPolicy(projectRef: policy.projectRef, targets: targets, roles: policy.roles,
            outputs: policy.outputs, inputs: policy.inputs, sends: policy.sends, receivers: policy.receivers,
            mixerVisible: policy.mixerVisible, trackSort: policy.trackSort, protectedPaths: policy.protectedPaths), reasons)
    }

    private static func parseRoles(
        _ object: [String: Value],
        into rejections: inout [IntentPolicyRejection]
    ) -> [IntentRole] {
        guard let rawRoles = object["roles"] else { return [] }
        guard let array = rawRoles.arrayValue else {
            rejections.append(.wrongType(path: "policy.roles", expected: "array"))
            return []
        }
        var roles: [IntentRole] = []
        for (index, element) in array.enumerated() {
            let path = "policy.roles[\(index)]"
            guard let entry = element.objectValue else {
                rejections.append(.wrongType(path: path, expected: "object"))
                continue
            }
            rejectUnknownKeys(entry, allowed: ["role", "members"], path: path, into: &rejections)
            let role = requiredString(entry, key: "role", path: path, into: &rejections)
            let members = parseMembers(entry, path: path, into: &rejections)
            guard let role, let members else { continue }
            roles.append(IntentRole(role: role, members: members))
        }
        return roles
    }

    private static func parseMembers(
        _ entry: [String: Value],
        path: String,
        into rejections: inout [IntentPolicyRejection]
    ) -> [IntentRoleMember]? {
        guard let rawMembers = entry["members"] else {
            rejections.append(.missingKey(path: path, key: "members"))
            return nil
        }
        guard let array = rawMembers.arrayValue else {
            rejections.append(.wrongType(path: "\(path).members", expected: "array"))
            return nil
        }
        var members: [IntentRoleMember] = []
        for (index, element) in array.enumerated() {
            let memberPath = "\(path).members[\(index)]"
            guard let member = element.objectValue else {
                rejections.append(.wrongType(path: memberPath, expected: "object"))
                continue
            }
            rejectUnknownKeys(member, allowed: ["handle", "accepted"], path: memberPath, into: &rejections)
            let handle = requiredString(member, key: "handle", path: memberPath, into: &rejections)
            let accepted = requiredBool(member, key: "accepted", path: memberPath, into: &rejections)
            guard let handle, let accepted else { continue }
            members.append(IntentRoleMember(handle: handle, accepted: accepted))
        }
        return members
    }

    private static func parseOutputs(
        _ object: [String: Value],
        into rejections: inout [IntentPolicyRejection]
    ) -> [IntentOutput] {
        guard let rawOutputs = object["outputs"] else { return [] }
        guard let array = rawOutputs.arrayValue else {
            rejections.append(.wrongType(path: "policy.outputs", expected: "array"))
            return []
        }
        var outputs: [IntentOutput] = []
        for (index, element) in array.enumerated() {
            let path = "policy.outputs[\(index)]"
            guard let entry = element.objectValue else {
                rejections.append(.wrongType(path: path, expected: "object"))
                continue
            }
            rejectUnknownKeys(entry, allowed: ["target", "role", "bus", "output"], path: path, into: &rejections)
            let target = optionalString(entry, key: "target", path: path, into: &rejections)
            let role = optionalString(entry, key: "role", path: path, into: &rejections)
            let destination = parseDestination(entry, path: path, into: &rejections)
            let subject: IntentSubject?
            switch (target, role) {
            case (.some(let handle), .none):
                subject = .target(handle)
            case (.none, .some(let name)):
                subject = .role(name)
            default:
                // Both or neither: the wire carried a shape this rule cannot read, or a key whose
                // type was already rejected above.
                if entry["target"] != nil, entry["role"] != nil {
                    rejections.append(.outputNamesBothOrNeither(path: path))
                } else if entry["target"] == nil, entry["role"] == nil {
                    rejections.append(.outputNamesBothOrNeither(path: path))
                }
                subject = nil
            }
            guard let subject, let destination else { continue }
            outputs.append(IntentOutput(subject: subject, destination: destination))
        }
        return outputs
    }

    private static func parseSends(_ object: [String: Value], targets: [IntentTarget],
                                   into rejections: inout [IntentPolicyRejection]) -> [IntentSend] {
        guard let raw = object["sends"] else { return [] }
        guard let entries = raw.arrayValue else {
            rejections.append(.wrongType(path: "policy.sends", expected: "array")); return []
        }
        var result: [IntentSend] = []
        var slots: [String: Set<IntentSend.Selector>] = [:]
        for (index, rawEntry) in entries.enumerated() {
            let path = "policy.sends[\(index)]"
            guard let entry = rawEntry.objectValue else {
                rejections.append(.wrongType(path: path, expected: "object")); continue
            }
            rejectUnknownKeys(entry, allowed: ["target", "physical_slot", "observed_ordinal", "bus", "remove", "output"], path: path, into: &rejections)
            let target = requiredString(entry, key: "target", path: path, into: &rejections)
            guard (entry["physical_slot"] == nil) != (entry["observed_ordinal"] == nil) else {
                rejections.append(.sendSelectorBothOrNeither(path: path)); continue
            }
            let key = entry["physical_slot"] != nil ? "physical_slot" : "observed_ordinal"
            let slot = requiredInt(entry, key: key, path: path, into: &rejections)
            guard ["bus", "remove", "output"].filter({ entry[$0] != nil }).count == 1 else {
                rejections.append(.sendDestinationBothOrNeither(path: path)); continue
            }
            let destination: IntentSend.Destination
            if entry["bus"] != nil {
                guard let number = requiredInt(entry, key: "bus", path: path, into: &rejections) else { continue }
                guard validateIntentBus(number, path: "\(path).bus", into: &rejections) else { continue }
                destination = .bus(number)
            } else if let raw = entry["output"] {
                let parsed = MixerDispatcher.outputAssignmentParam(raw, field: "\(path).output")
                switch parsed.assignment {
                case .physical(let first, let second)?: destination = .physical(first, second)
                case .stereoOutput?: destination = .stereoOutput
                default:
                    rejections.append(.unsupportedOutput(path: "\(path).output", value: parsed.problem ?? "physical or Stereo output required")); continue
                }
            } else {
                guard let remove = requiredBool(entry, key: "remove", path: path, into: &rejections) else { continue }
                guard remove else { rejections.append(.sendRemovalMustBeTrue(path: path)); continue }
                destination = .remove
            }
            guard let target, let slot else { continue }
            guard targets.contains(where: { $0.handle == target }) else {
                rejections.append(.unknownSubject(path: path, subject: target)); continue
            }
            guard key == "physical_slot" ? routingPhysicalSendSlots.contains(slot) : slot >= 0 else {
                rejections.append(.sendSlotOutOfRange(path: "\(path).\(key)", value: slot)); continue
            }
            let selector: IntentSend.Selector = key == "physical_slot" ? .physicalSlot(slot) : .observedOrdinal(slot)
            guard slots[target, default: []].insert(selector).inserted else {
                rejections.append(.duplicateSend(target: target, slot: slot)); continue
            }
            result.append(IntentSend(target: target, selector: selector, destination: destination))
        }
        return result.sorted {
            if $0.target != $1.target { return $0.target < $1.target }
            switch ($0.selector, $1.selector) {
            case (.physicalSlot(let a), .physicalSlot(let b)), (.observedOrdinal(let a), .observedOrdinal(let b)): return a < b
            case (.physicalSlot, .observedOrdinal): return true
            case (.observedOrdinal, .physicalSlot): return false
            }
        }
    }

    /// Exactly one of `bus` (a supported number) or `output` (`"no_output"`, the one non-bus main output
    /// P1 accepts: a track deliberately routed nowhere).
    private static func parseDestination(
        _ entry: [String: Value],
        path: String,
        into rejections: inout [IntentPolicyRejection]
    ) -> IntentMainOutput? {
        guard (entry["bus"] == nil) != (entry["output"] == nil) else {
            rejections.append(.outputDestinationBothOrNeither(path: path))
            return nil
        }
        if entry["bus"] != nil {
            guard let bus = requiredInt(entry, key: "bus", path: path, into: &rejections) else { return nil }
            guard validateIntentBus(bus, path: "\(path).bus", into: &rejections) else { return nil }
            return .bus(bus)
        }
        if let value = entry["output"], value.objectValue != nil {
            let parsed = MixerDispatcher.outputAssignmentParam(value, field: "\(path).output")
            switch parsed.assignment {
            case .physical(let first, let second)?: return .physical(first, second)
            case .stereoOutput?: return .stereoOutput
            default:
                rejections.append(.unsupportedOutput(path: "\(path).output", value: parsed.problem ?? "unsupported typed output"))
                return nil
            }
        }
        guard let output = optionalString(entry, key: "output", path: path, into: &rejections) else { return nil }
        guard output == RoutingOutputClassification.noOutput.rawValue else {
            rejections.append(.unsupportedOutput(path: "\(path).output", value: output))
            return nil
        }
        return .noOutput
    }

    /// Semantic checks after the shape is read: identifiers, uniqueness, reference kind, subject
    /// existence, and conflicting buses once roles are expanded to their accepted members.
    private static func validate(
        targets: [IntentTarget],
        roles: [IntentRole],
        outputs: [IntentOutput],
        into rejections: inout [IntentPolicyRejection]
    ) {
        for (index, target) in targets.enumerated() where !isValidHandle(target.handle) {
            rejections.append(.invalidHandle(path: "policy.targets[\(index)].handle"))
        }
        for (index, role) in roles.enumerated() {
            if !isValidHandle(role.role) {
                rejections.append(.invalidHandle(path: "policy.roles[\(index)].role"))
            }
            for (memberIndex, member) in role.members.enumerated() where !isValidHandle(member.handle) {
                rejections.append(.invalidHandle(path: "policy.roles[\(index)].members[\(memberIndex)].handle"))
            }
        }

        for handle in duplicates(in: targets.map(\.handle)) {
            rejections.append(.duplicateHandle(handle))
        }
        for ref in duplicates(in: targets.map(\.trackRef.rawValue)) {
            rejections.append(.duplicateTrackRef(ref))
        }
        // Role names and member handles within one role share the rule: one name, one meaning.
        for name in duplicates(in: roles.map(\.role)) {
            rejections.append(.duplicateHandle(name))
        }
        for role in roles {
            for handle in duplicates(in: role.members.map(\.handle)) {
                rejections.append(.duplicateHandle(handle))
            }
        }

        for target in targets where !target.trackRef.rawValue.hasPrefix(target.mixerRef == nil ? trackReferencePrefix : "mix_") {
            rejections.append(.unsupportedTargetRef(handle: target.handle, ref: target.trackRef.rawValue))
        }

        let handles = Set(targets.map(\.handle))
        let roleNames = Set(roles.map(\.role))
        for (index, role) in roles.enumerated() {
            for (memberIndex, member) in role.members.enumerated() where !handles.contains(member.handle) {
                rejections.append(.unknownSubject(
                    path: "policy.roles[\(index)].members[\(memberIndex)]",
                    subject: member.handle
                ))
            }
        }
        for (index, output) in outputs.enumerated() {
            switch output.subject {
            case .target(let handle) where !handles.contains(handle):
                rejections.append(.unknownSubject(path: "policy.outputs[\(index)]", subject: handle))
            case .role(let name) where !roleNames.contains(name):
                rejections.append(.unknownSubject(path: "policy.outputs[\(index)]", subject: name))
            default:
                break
            }
        }

        // Roles expand to their accepted members before conflicts are read, so a target named
        // directly and again through a role with another bus is one contradiction, not two intents.
        var destinationsByHandle: [String: Set<IntentMainOutput>] = [:]
        var destinationsByRole: [String: Set<IntentMainOutput>] = [:]
        for output in outputs {
            switch output.subject {
            case .target(let handle):
                destinationsByHandle[handle, default: []].insert(output.destination)
            case .role(let name):
                destinationsByRole[name, default: []].insert(output.destination)
                for role in roles where role.role == name {
                    for member in role.members where member.accepted {
                        destinationsByHandle[member.handle, default: []].insert(output.destination)
                    }
                }
            }
        }
        for (handle, destinations) in destinationsByHandle where destinations.count > 1 {
            rejections.append(.conflictingOutputs(subject: handle, outputs: IntentMainOutput.ordered(destinations)))
        }
        for (name, destinations) in destinationsByRole where destinations.count > 1 {
            rejections.append(.conflictingOutputs(subject: name, outputs: IntentMainOutput.ordered(destinations)))
        }
    }

    private static func isValidHandle(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && value.utf8.count <= maxHandleBytes
    }

    private static func duplicates(in values: [String]) -> [String] {
        var seen: Set<String> = []
        var repeated: Set<String> = []
        for value in values where !seen.insert(value).inserted {
            repeated.insert(value)
        }
        return repeated.sorted()
    }

    private static func rejectUnknownKeys(
        _ object: [String: Value],
        allowed: Set<String>,
        path: String,
        into rejections: inout [IntentPolicyRejection]
    ) {
        for key in Set(object.keys).subtracting(allowed).sorted() {
            rejections.append(.unknownKey(path: path, key: key))
        }
    }

    private static func requiredString(
        _ object: [String: Value],
        key: String,
        path: String,
        into rejections: inout [IntentPolicyRejection]
    ) -> String? {
        guard object[key] != nil else {
            rejections.append(.missingKey(path: path, key: key))
            return nil
        }
        return optionalString(object, key: key, path: path, into: &rejections)
    }

    private static func optionalString(
        _ object: [String: Value],
        key: String,
        path: String,
        into rejections: inout [IntentPolicyRejection]
    ) -> String? {
        guard let raw = object[key] else { return nil }
        guard let value = raw.stringValue else {
            rejections.append(.wrongType(path: "\(path).\(key)", expected: "string"))
            return nil
        }
        return value
    }

    private static func requiredBool(
        _ object: [String: Value],
        key: String,
        path: String,
        into rejections: inout [IntentPolicyRejection]
    ) -> Bool? {
        guard let raw = object[key] else {
            rejections.append(.missingKey(path: path, key: key))
            return nil
        }
        guard let value = raw.boolValue else {
            rejections.append(.wrongType(path: "\(path).\(key)", expected: "bool"))
            return nil
        }
        return value
    }

    private static func requiredInt(
        _ object: [String: Value],
        key: String,
        path: String,
        into rejections: inout [IntentPolicyRejection]
    ) -> Int? {
        guard let raw = object[key] else {
            rejections.append(.missingKey(path: path, key: key))
            return nil
        }
        guard let value = raw.intValue else {
            rejections.append(.wrongType(path: "\(path).\(key)", expected: "int"))
            return nil
        }
        return value
    }

    // MARK: - Assessment

    private struct ResolvedOutput {
        let destination: IntentMainOutput
        var namedDirectly: Bool
        var roles: Set<String>
    }

    /// A reason that holds for every target of one assessment, with the status it forces.
    struct AssessmentGate {
        let status: IntentStatus
        let reason: IntentReason
    }

    /// The track references the capture issued, or the token for why no target can be checked
    /// against them. A direct target and a role's candidates both read `trackReferences(of:)`.
    private enum TrackReferenceReading {
        case issued(IssuedTrackReferences)
        case unreadable(IntentReason)
    }

    /// The one captured row a reference names, or the status and token a target carrying it gets.
    /// A direct target and each of a role's candidates both read `locate(_:in:)`.
    enum ReferenceLocation {
        case located(trackIndex: Int)
        case unlocated(IntentStatus, IntentReason)
    }

    /// What the graph shows for one source, before intent is compared with it: where its main
    /// output goes, or why the graph does not say.
    private enum MainOutputObservation {
        case observed(IntentEndpoint)
        case unobserved(IntentReason, edgeObserved: Bool)

        var endpoint: IntentEndpoint? {
            if case .observed(let endpoint) = self { return endpoint }
            return nil
        }

        var failure: IntentReason? {
            if case .unobserved(let reason, _) = self { return reason }
            return nil
        }

        var edgeObserved: Bool {
            switch self {
            case .observed(let endpoint): return endpoint.output == .bus
            case .unobserved(_, let edgeObserved): return edgeObserved
            }
        }
    }

    /// Assesses an approved policy against one capture and the graph published from it. Pure: no
    /// host, cache or registry, and byte-identical output for identical inputs.
    static func assessIntent(
        policy: IntentPolicy,
        capture: SessionPopulationObservation.Capture,
        graph: RoutingGraph
    ) -> IntentAssessment {
        var targetsByHandle: [String: IntentTarget] = [:]
        for target in policy.targets {
            targetsByHandle[target.handle] = target
        }
        var rolesByName: [String: IntentRole] = [:]
        for role in policy.roles {
            rolesByName[role.role] = role
        }

        // The parser guarantees one destination per handle and per role, so a handle reached twice
        // (once directly, once through a role, or through two roles) is one finding.
        var resolved: [String: ResolvedOutput] = [:]
        var unresolvedRoles: [String: IntentMainOutput] = [:]
        for output in policy.outputs {
            switch output.subject {
            case .target(let handle):
                var entry = resolved[handle]
                    ?? ResolvedOutput(destination: output.destination, namedDirectly: false, roles: [])
                entry.namedDirectly = true
                resolved[handle] = entry
            case .role(let name):
                guard let role = rolesByName[name] else { continue }
                let accepted = role.members.filter(\.accepted)
                if accepted.isEmpty {
                    unresolvedRoles[name] = output.destination
                    continue
                }
                for member in accepted {
                    var entry = resolved[member.handle]
                        ?? ResolvedOutput(destination: output.destination, namedDirectly: false, roles: [])
                    entry.roles.insert(name)
                    resolved[member.handle] = entry
                }
            }
        }

        let gate = assessmentGate(policy: policy, capture: capture, graph: graph)
        var findings: [IntentFinding] = []
        var questions: [IntentQuestion] = []
        for (handle, entry) in resolved.sorted(by: { $0.key < $1.key }) {
            guard let target = targetsByHandle[handle] else { continue }
            findings.append(assessMainOutput(
                handle: handle,
                role: entry.namedDirectly ? nil : entry.roles.sorted().first,
                trackRef: target.trackRef,
                destination: entry.destination,
                gate: gate,
                capture: capture,
                graph: graph
            ))
        }
        for (name, destination) in unresolvedRoles.sorted(by: { $0.key < $1.key }) {
            guard let role = rolesByName[name] else { continue }
            func roleFinding(_ status: IntentStatus, reasons: [IntentReason]) -> IntentFinding {
                IntentFinding(
                    id: "main_output.role.\(name)",
                    rule: mainOutputAssignmentRule,
                    basis: .approvedPolicy,
                    severity: .info,
                    status: status,
                    target: IntentTargetEvidence(handle: nil, role: name, trackRef: nil, trackIndex: nil),
                    observed: nil,
                    expected: .expected(destination),
                    coverage: coverage(edgeObserved: false, destinationBusObserved: false, expected: destination, graph: graph),
                    reasons: reasons
                )
            }
            // A question about another project, or over a graph this capture cannot vouch for,
            // would be answered for the wrong project: the gate speaks instead and nothing is asked.
            if let gate {
                findings.append(roleFinding(gate.status, reasons: [gate.reason]))
                continue
            }
            // The candidates carry the policy's references. While the capture's own are off or
            // stale a question could name a track this capture does not have, so the role reads the
            // check a direct target reads, and nothing is asked.
            let issued: IssuedTrackReferences
            switch trackReferences(of: capture) {
            case .unreadable(let reason):
                findings.append(roleFinding(.unverified, reasons: [reason]))
                continue
            case .issued(let references):
                issued = references
            }
            // A candidate is offered only where a direct target with its reference would be found:
            // on exactly one captured row. The rest are dropped, and the order is the policy's. When
            // every candidate is dropped, the role carries their tokens, and it is `outside_scope`
            // only when every one of them is.
            var candidates: [IntentCandidate] = []
            var dropped: [(status: IntentStatus, reason: IntentReason)] = []
            for member in role.members where !member.accepted {
                guard let target = targetsByHandle[member.handle] else { continue }
                switch locate(target.trackRef, in: issued) {
                case .located:
                    candidates.append(IntentCandidate(handle: member.handle, trackRef: target.trackRef.rawValue))
                case .unlocated(let status, let reason):
                    dropped.append((status, reason))
                }
            }
            if candidates.isEmpty, !dropped.isEmpty {
                let statuses = Set(dropped.map(\.status))
                var reasons: [IntentReason] = []
                for (_, reason) in dropped where !reasons.contains(reason) {
                    reasons.append(reason)
                }
                findings.append(roleFinding(statuses.count == 1 ? dropped[0].status : .unverified, reasons: reasons))
                continue
            }
            // The graph's epoch, read as a direct target reads it. The domains are read more
            // narrowly: a direct target's verdict is about routing, so it needs both domains
            // complete, but the question asks which captured track fills the role, and a `partial`
            // domain, which every real read publishes while #291 is open, does not put that in
            // doubt. An `unstable` one does: `publish` marks every domain `unstable` when the
            // capture moved under its own read, a stale project reference among them, so the role
            // stops there and asks nothing.
            if let reason = graphEpochMismatch(graph, capture: capture) {
                findings.append(roleFinding(.unverified, reasons: [reason]))
                continue
            }
            let unstableReasons = domainCoverageReasons(of: graph, where: { $0 == .unstable })
            if !unstableReasons.isEmpty {
                findings.append(roleFinding(.unverified, reasons: unstableReasons))
                continue
            }
            findings.append(roleFinding(.needsInput, reasons: [.roleHasNoAcceptedMember]))
            questions.append(IntentQuestion(
                id: "role.\(name)",
                role: name,
                rule: mainOutputAssignmentRule,
                expected: .expected(destination),
                candidates: candidates
            ))
        }
        findings.sort { $0.id < $1.id }
        questions.sort { $0.id < $1.id }

        let sendFindings = policy.sends.compactMap { intent -> IntentSendFinding? in
            guard let target = targetsByHandle[intent.target] else { return nil } // validated by the parser
            return assessSend(intent, trackRef: target.trackRef, gate: gate, capture: capture, graph: graph)
        }
        let inputFindings = policy.inputs.compactMap { intent -> IntentInputFinding? in
            guard let target = targetsByHandle[intent.target] else { return nil }
            return assessInput(intent, target: target, gate: gate, capture: capture)
        }
        return IntentAssessment(
            schema: intentAssessmentSchema,
            readOnly: true,
            snapshotId: SessionPopulationObservation.snapshotID(for: capture),
            projectEpoch: capture.projectEpoch,
            graphProjectEpoch: graph.projectEpoch,
            findings: findings,
            questions: questions,
            changeRequired: findings.contains { $0.status == .violation } || sendFindings.contains { $0.status == .violation }
                || inputFindings.contains { $0.status == .violation },
            sendFindings: sendFindings.isEmpty ? nil : sendFindings,
            inputFindings: inputFindings.isEmpty ? nil : inputFindings
        )
    }

    private static func assessInput(_ intent: IntentInput, target: IntentTarget, gate: AssessmentGate?,
                                    capture: SessionPopulationObservation.Capture) -> IntentInputFinding {
        func finding(_ status: IntentStatus, index: Int? = nil, observed: Value? = nil,
                     reasons: [String] = []) -> IntentInputFinding {
            .init(id: "input.target.\(intent.target)", status: status,
                target: .init(handle: intent.target, role: nil, trackRef: target.trackRef.rawValue, trackIndex: index),
                observed: observed, expected: intent, reasons: reasons)
        }
        if let gate { return finding(gate.status, reasons: [gate.reason.rawValue]) }
        guard capture.referencesEnabled, !capture.referencesStale, let issued = capture.issued,
              case .located(let index) = locate(target.trackRef, in: issued),
              let fresh = capture.freshPopulation, fresh.stable else {
            return finding(.unverified, reasons: ["captured_input_association_unverified"])
        }
        let rows = capture.tracks.filter { $0.id == index }
        guard rows.count == 1, let track = rows.first?.physicalBinding else {
            return finding(.unverified, reasons: ["captured_input_association_unverified"])
        }
        let pairs = fresh.selectionAssociations.filter { $0.track.matches(track) }
        guard pairs.count == 1, let pair = pairs.first,
              fresh.selectionAssociations.filter({ $0.strip.matches(pair.strip) }).count == 1 else {
            return finding(.unverified, index: index, reasons: ["captured_input_association_unverified"])
        }
        let strips = capture.channelStrips.filter { $0.physicalBinding?.matches(pair.strip) == true }
        guard strips.count == 1, let strip = strips.first,
              let checked = SessionPopulationObservation.reportedCheckedInput(of: strip, capture: capture,
                qualified: capture.before == capture.after && !capture.referencesStale) else {
            return finding(.unverified, index: index, reasons: ["checked_input_unavailable"])
        }
        var observed: [String: Value] = ["kind": .string(checked.kind), "source": .string(checked.source)]
        if let number = checked.number { observed["number"] = .int(number) }
        if let ports = checked.ports { observed["ports"] = .array(ports.map(Value.int)) }
        return finding(checked.kind == "bus" && checked.number == intent.bus ? .compliant : .violation,
            index: index, observed: .object(observed))
    }

    /// One shared pure send assessment for audit and planning. No label, scalar level or bypass
    /// supplies connectivity; absence needs complete requested source-slot population evidence.
    private static func assessSend(_ intent: IntentSend, trackRef: TargetReference, gate: AssessmentGate?,
                                   capture: SessionPopulationObservation.Capture, graph: RoutingGraph) -> IntentSendFinding {
        func finding(_ status: IntentStatus, index: Int? = nil, observed: RoutingEdge? = nil,
                     reasons: [IntentReason] = []) -> IntentSendFinding {
            IntentSendFinding(id: "send.target.\(intent.target).\(intent.selectorID)",
                severity: status == .violation ? .warn : .info, status: status,
                target: IntentTargetEvidence(handle: intent.target, role: nil, trackRef: trackRef.rawValue, trackIndex: index),
                physicalSlot: intent.physicalSlot, observedOrdinal: intent.observedOrdinal,
                observed: observed, expected: intent, coverage: graph.coverage, reasons: reasons)
        }
        if let gate { return finding(gate.status, reasons: [gate.reason]) }
        // The routing graph's physical-slot edges cannot authenticate a source-census ordinal.
        guard intent.physicalSlot != nil else { return finding(.unverified, reasons: [.sendCoverageIncomplete]) }
        let issued: IssuedTrackReferences
        switch trackReferences(of: capture) {
        case .unreadable(let reason): return finding(.unverified, reasons: [reason])
        case .issued(let references): issued = references
        }
        let index: Int
        switch locate(trackRef, in: issued) {
        case .unlocated(let status, let reason): return finding(status, reasons: [reason])
        case .located(let value): index = value
        }
        if let reason = graphEpochMismatch(graph, capture: capture) { return finding(.unverified, index: index, reasons: [reason]) }
        var reasons: [IntentReason] = []
        if graph.coverage.population.state != .complete { reasons.append(.populationCoverageIncomplete) }
        if graph.coverage.stripTrackAssociation.state != .complete { reasons.append(.stripTrackAssociationIncomplete) }
        if graph.coverage.sends.state != .complete { reasons.append(.sendCoverageIncomplete) }
        if !reasons.isEmpty { return finding(.unverified, index: index, reasons: reasons) }
        let sources = graph.nodes.filter { $0.targetRef == trackRef }
        guard sources.count == 1, let source = sources.first, source.kind == .track,
              graph.nodes.filter({ $0.id == source.id }).count == 1 else {
            return finding(.unverified, index: index, reasons: [.sourceNodeAmbiguous])
        }
        let candidates = graph.edges.filter { $0.kind == .send
            && ($0.source == source.id || $0.send?.sourceTrackRef == trackRef)
            && ($0.send?.physicalSlot == intent.physicalSlot || $0.send == nil) }
        guard candidates.count <= 1 else { return finding(.unverified, index: index, reasons: [.sendSlotAmbiguous]) }
        let before = candidates.first
        if let before {
            guard let send = before.send, before.source == source.id, send.sourceTrackRef == trackRef,
                  let destination = graph.nodes.first(where: { $0.id == before.destination }), destination.kind == .bus,
                  graph.nodes.filter({ $0.id == before.destination }).count == 1,
                  send.destinationBusNumber == destination.busNumber, destination.busNumber != nil,
                  send.destinationRef == nil || send.destinationRef == destination.targetRef else {
                return finding(.unverified, index: index, reasons: [.sendEndpointUnverified])
            }
            if let level = before.send?.level, !level.isFinite {
                // Preserve an accounted, blocked task rather than invent a scalar or fail the
                // entire canonical draft's strict JSON encoding. This is not observed absence.
                return finding(.unverified, index: index, reasons: [.sendScalarUnserializable])
            }
        }
        if let bus = intent.bus {
            let destinations = graph.nodes.filter { $0.kind == .bus && $0.busNumber == bus }
            guard destinations.count == 1, let destination = destinations.first,
                  graph.nodes.filter({ $0.id == destination.id }).count == 1 else {
                return finding(.unverified, index: index, observed: before, reasons: [.expectedBusNotObserved])
            }
            return finding(before?.destination == destination.id ? .compliant : .violation, index: index, observed: before)
        }
        guard intent.isRemoval else { return finding(.unverified, index: index, observed: before, reasons: [.sendEndpointUnverified]) }
        return finding(before == nil ? .compliant : .violation, index: index, observed: before)
    }

    /// Whether this graph can be read against this capture at all, and whether the policy is for
    /// the captured project. In a fixed order, first hit wins.
    static func assessmentGate(
        policy: IntentPolicy,
        capture: SessionPopulationObservation.Capture,
        graph: RoutingGraph
    ) -> AssessmentGate? {
        if capture.before != capture.after {
            return AssessmentGate(status: .unverified, reason: .cacheMovedDuringCapture)
        }
        // The graph must be the one published from this capture's cache revision, not another read.
        if graph.snapshotId != SessionPopulationObservation.snapshotID(for: capture) {
            return AssessmentGate(status: .unverified, reason: .graphNotFromCapture)
        }
        // The snapshot id names cache revisions, not graph contents, so it cannot say whose project
        // the graph describes; the project reference the capture issued can. `publish` copies it and
        // leaves the graph's nil when the capture issued none, so one side alone is a mismatch too.
        var capturedProject: TargetReference?
        if case .issued(let reference)? = capture.projectIssuance {
            capturedProject = reference
        }
        if graph.projectReference != capturedProject {
            return AssessmentGate(status: .unverified, reason: .graphProjectMismatch)
        }
        if !graph.isConsistent {
            return AssessmentGate(status: .unverified, reason: .routingGraphInconsistent)
        }
        if !capture.before.hasDocument {
            return AssessmentGate(status: .unverified, reason: .noDocument)
        }
        if capture.before.axOccluded {
            return AssessmentGate(status: .unverified, reason: .axOccluded)
        }
        if let wanted = policy.projectRef {
            guard case .issued(let captured)? = capture.projectIssuance else {
                return AssessmentGate(status: .unverified, reason: .projectReferenceUnavailable)
            }
            if captured != wanted {
                return AssessmentGate(status: .outsideScope, reason: .policyProjectMismatch)
            }
        }
        return nil
    }

    /// References off are `references_unavailable`; references on with none issued, which the
    /// capture reports when the registry moved on during issuance, are `target_snapshot_stale`.
    private static func trackReferences(of capture: SessionPopulationObservation.Capture) -> TrackReferenceReading {
        guard capture.referencesEnabled else { return .unreadable(.referencesUnavailable) }
        guard let issued = capture.issued else { return .unreadable(.targetSnapshotStale) }
        return .issued(issued)
    }

    /// Every captured row is searched, so row order never picks one: no row is `outside_scope`
    /// with `target_not_in_snapshot`, and more than one is `unverified` with
    /// `target_ambiguous_in_snapshot`.
    static func locate(_ trackRef: TargetReference, in issued: IssuedTrackReferences) -> ReferenceLocation {
        let trackIndices = issued.byTrackIndex.filter { $0.value == trackRef }.keys.sorted()
        guard let trackIndex = trackIndices.first else { return .unlocated(.outsideScope, .targetNotInSnapshot) }
        guard trackIndices.count == 1 else { return .unlocated(.unverified, .targetAmbiguousInSnapshot) }
        return .located(trackIndex: trackIndex)
    }

    /// The graph carries the epoch of the registry snapshot the capture issued under; any other
    /// epoch is `graph_epoch_mismatch`.
    static func graphEpochMismatch(
        _ graph: RoutingGraph,
        capture: SessionPopulationObservation.Capture
    ) -> IntentReason? {
        graph.projectEpoch == capture.targetSnapshot?.projectEpoch ? nil : .graphEpochMismatch
    }

    /// The token for each of the two domains the rule reads whose state `stops` the finding: by
    /// default any state but `complete`, which is what a direct target's routing verdict needs, and
    /// only `unstable` for a role's question. The state decides, never a reason string. A capture
    /// whose project reference went stale is published with every domain `unstable`, so both stop
    /// here.
    private static func domainCoverageReasons(
        of graph: RoutingGraph,
        where stops: (RoutingCoverageState) -> Bool = { $0 != .complete }
    ) -> [IntentReason] {
        var reasons: [IntentReason] = []
        if stops(graph.coverage.mainOutput.state) {
            reasons.append(.mainOutputCoverageIncomplete)
        }
        if stops(graph.coverage.stripTrackAssociation.state) {
            reasons.append(.stripTrackAssociationIncomplete)
        }
        return reasons
    }

    /// The one P1 rule, in a fixed order. `compliant` and `violation` need a capture and graph that
    /// pass every gate, a target the capture issued, both the `main_output` and the
    /// `strip_track_association` domains complete, and a source whose output the graph classifies
    /// unambiguously. Every weaker reading is `unverified` or `outside_scope`, because what was not
    /// observed is not evidence of a wrong route.
    private static func assessMainOutput(
        handle: String,
        role: String?,
        trackRef: TargetReference,
        destination: IntentMainOutput,
        gate: AssessmentGate?,
        capture: SessionPopulationObservation.Capture,
        graph: RoutingGraph
    ) -> IntentFinding {
        func finding(
            _ status: IntentStatus,
            _ observation: MainOutputObservation?,
            trackIndex: Int?,
            reasons: [IntentReason]
        ) -> IntentFinding {
            IntentFinding(
                id: "main_output.target.\(handle)",
                rule: mainOutputAssignmentRule,
                basis: .approvedPolicy,
                severity: status == .violation ? .warn : .info,
                status: status,
                target: IntentTargetEvidence(
                    handle: handle,
                    role: role,
                    trackRef: trackRef.rawValue,
                    trackIndex: trackIndex
                ),
                observed: observation?.endpoint,
                expected: .expected(destination),
                coverage: coverage(
                    edgeObserved: observation?.edgeObserved ?? false,
                    destinationBusObserved: observation?.endpoint?.busNumber != nil,
                    expected: destination,
                    graph: graph
                ),
                reasons: reasons
            )
        }

        if let gate {
            return finding(gate.status, nil, trackIndex: nil, reasons: [gate.reason])
        }
        let issued: IssuedTrackReferences
        switch trackReferences(of: capture) {
        case .unreadable(let reason):
            return finding(.unverified, nil, trackIndex: nil, reasons: [reason])
        case .issued(let references):
            issued = references
        }
        let trackIndex: Int
        switch locate(trackRef, in: issued) {
        case .unlocated(let status, let reason):
            return finding(status, nil, trackIndex: nil, reasons: [reason])
        case .located(let index):
            trackIndex = index
        }
        if let reason = graphEpochMismatch(graph, capture: capture) {
            return finding(.unverified, nil, trackIndex: trackIndex, reasons: [reason])
        }

        // The observation is read first only so an unverified finding can carry it as evidence;
        // the coverage verdict does not depend on it.
        let observation = observeMainOutput(of: trackRef, in: graph)
        let coverageReasons = domainCoverageReasons(of: graph)
        if !coverageReasons.isEmpty {
            return finding(
                .unverified,
                observation,
                trackIndex: trackIndex,
                reasons: coverageReasons + [observation.failure].compactMap { $0 }
            )
        }
        let observed: IntentEndpoint
        switch observation {
        case .unobserved(let reason, _):
            return finding(.unverified, observation, trackIndex: trackIndex, reasons: [reason])
        case .observed(let endpoint):
            observed = endpoint
        }

        switch destination {
        case .bus(let bus):
            if observed.output == .bus, observed.busNumber == bus {
                return finding(.compliant, observation, trackIndex: trackIndex, reasons: [])
            }
            var reasons: [IntentReason] = []
            if !graph.nodes.contains(where: { $0.kind == .bus && $0.busNumber == bus }) {
                reasons.append(.expectedBusNotObserved)
            }
            return finding(.violation, observation, trackIndex: trackIndex, reasons: reasons)
        case .noOutput:
            if observed.output == .noOutput {
                return finding(.compliant, observation, trackIndex: trackIndex, reasons: [])
            }
            return finding(.violation, observation, trackIndex: trackIndex, reasons: [])
        case .physical, .stereoOutput:
            // A physical classification has no checked port/kind identity in this graph.
            // The local retained output task consumes the request-held typed reader instead.
            return finding(.unverified, observation, trackIndex: trackIndex, reasons: [.outputUnclassified])
        }
    }

    /// The source is the one node carrying the target's reference, never a node found by name.
    /// Only its `outputClassification` and its `.mainOutput` edges are read. Every lookup runs over
    /// all nodes and needs exactly one match, so node order never picks the observation.
    private static func observeMainOutput(of trackRef: TargetReference, in graph: RoutingGraph) -> MainOutputObservation {
        func classified(_ output: RoutingOutputClassification) -> MainOutputObservation {
            .observed(IntentEndpoint(nodeId: nil, displayName: nil, busNumber: nil, output: output))
        }

        let sources = graph.nodes.filter { $0.targetRef == trackRef }
        guard let source = sources.first else { return .unobserved(.trackNotInGraph, edgeObserved: false) }
        guard sources.count == 1 else { return .unobserved(.sourceNodeAmbiguous, edgeObserved: false) }
        guard source.kind == .track else { return .unobserved(.sourceNodeNotTrack, edgeObserved: false) }

        switch source.outputClassification {
        case nil, .unclassified?:
            return .unobserved(.outputUnclassified, edgeObserved: false)
        case .noOutput?:
            // A label cannot certify absence when the same source has contradictory edges
            // or its graph identity is ambiguous, even if an unrelated domain is partial.
            guard graph.nodes.filter({ $0.id == source.id }).count == 1 else {
                return .unobserved(.sourceNodeAmbiguous, edgeObserved: false)
            }
            guard !graph.edges.contains(where: { $0.kind == .mainOutput && $0.source == source.id }) else {
                return .unobserved(.outputEdgeAmbiguous, edgeObserved: true)
            }
            return classified(.noOutput)
        case .physicalOutput?:
            guard graph.nodes.filter({ $0.id == source.id }).count == 1 else {
                return .unobserved(.sourceNodeAmbiguous, edgeObserved: false)
            }
            // Physical classifications publish no main-output edge. A contradictory edge
            // is evidence of an uncertain observation, not authority to prescribe a repair.
            guard !graph.edges.contains(where: { $0.kind == .mainOutput && $0.source == source.id }) else {
                return .unobserved(.outputEdgeAmbiguous, edgeObserved: true)
            }
            return classified(.physicalOutput)
        case .bus?:
            // Edges name their source by id: another node carrying that id could own the edge.
            guard graph.nodes.filter({ $0.id == source.id }).count == 1 else {
                return .unobserved(.sourceNodeAmbiguous, edgeObserved: false)
            }
            let edges = graph.edges.filter { $0.kind == .mainOutput && $0.source == source.id }
            guard edges.count == 1, let edge = edges.first else {
                return .unobserved(.outputEdgeAmbiguous, edgeObserved: !edges.isEmpty)
            }
            let destinations = graph.nodes.filter { $0.id == edge.destination }
            guard destinations.count <= 1 else {
                return .unobserved(.outputDestinationAmbiguous, edgeObserved: true)
            }
            guard let busNode = destinations.first, busNode.kind == .bus, let busNumber = busNode.busNumber,
                  OutputAssignment.busNumbers.contains(busNumber) else {
                return .unobserved(.outputEdgeAmbiguous, edgeObserved: true)
            }
            // The verdict compares this number, so it has to name one node.
            guard graph.nodes.filter({ $0.busNumber == busNumber }).count == 1 else {
                return .unobserved(.outputDestinationAmbiguous, edgeObserved: true)
            }
            return .observed(IntentEndpoint(
                nodeId: busNode.id,
                displayName: busNode.displayName,
                busNumber: busNumber,
                output: .bus
            ))
        }
    }

    private static func coverage(
        edgeObserved: Bool,
        destinationBusObserved: Bool,
        expected: IntentMainOutput,
        graph: RoutingGraph
    ) -> IntentCoverage {
        var expectedBusObserved: Bool?
        if case .bus(let bus) = expected {
            expectedBusObserved = graph.nodes.contains { $0.kind == .bus && $0.busNumber == bus }
        }
        return IntentCoverage(
            outputEdgeObserved: edgeObserved,
            destinationBusObserved: destinationBusObserved,
            expectedBusObserved: expectedBusObserved,
            graphComplete: graph.complete,
            mainOutput: graph.coverage.mainOutput,
            stripTrackAssociation: graph.coverage.stripTrackAssociation,
            notVerified: IntentAspect.withoutObservationSource
        )
    }
}
