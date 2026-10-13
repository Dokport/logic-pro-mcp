@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

@Suite("fresh non-Help AX attribute batches", .serialized)
struct AXHelpersMultiAttributeTests {
    @Test("Complete role-only traversal batches each descendant's fresh role and children")
    func completeRoleCensusAvoidsSeparateRoleAndChildrenRoundTrips() throws {
        let builder = FakeAXRuntimeBuilder(), state = Reads()
        let root = builder.element(965_810), group = builder.element(965_811), target = builder.element(965_812)
        builder.setChildren(root, [group]); builder.setChildren(group, [target]); builder.setChildren(target, [])
        builder.setRole(group, kAXGroupRole as String); builder.setRole(target, kAXScrollBarRole as String)
        let base = builder.makeAXRuntime()
        let ax = AXHelpers.Runtime(axApp: base.axApp, attributeValue: base.attributeValue,
            setAttributeValue: base.setAttributeValue, children: base.children,
            performAction: base.performAction, childCount: base.childCount,
            childrenResult: base.childrenResult, attributeValueResult: { element, attribute in
                if attribute == kAXRoleAttribute as String { state.singles.append(attribute) }
                if attribute == kAXChildrenAttribute as String { return .success(base.children(element) as NSArray) }
                return .success(builder.attributeValue(element, attribute).map { $0 as AnyObject })
            }, attributeValuesResult: { element, attributes in
                state.batch += 1
                #expect(attributes == [kAXRoleAttribute as String, kAXChildrenAttribute as String])
                return .success(attributes.map { attribute -> AnyObject in
                    if attribute == kAXChildrenAttribute as String { return base.children(element) as NSArray }
                    return builder.attributeValue(element, attribute).map { $0 as AnyObject } ?? NSNull()
                })
            })
        let result = try AXHelpers.censusDescendantResult(of: root, role: kAXScrollBarRole as String,
            maxDepth: 2, runtime: ax, requiresCompleteTraversal: true, batchingRoleAndChildren: true).get()
        #expect(result.matches.count == 1 && CFEqual(result.matches[0], target))
        #expect(state.batch == 2 && state.singles.isEmpty,
            "Complete viewport census must avoid two separate host messages per descendant")
        #expect(builder.setCalls.isEmpty && builder.actionCalls.isEmpty)
    }

    private final class Reads: @unchecked Sendable {
        var batch = 0
        var childReads = 0
        var singles: [String] = []
        var permit = true
        var values: Result<[AnyObject], AXHelpers.AXStatusError> = .success([])
    }

    @Test(arguments: ["batch_failure", "malformed_role", "malformed_children", "mixed_children", "cutoff"])
    func completeRoleBatchPreservesFailureAndCutoff(_ fault: String) {
        let state = Reads(), builder = FakeAXRuntimeBuilder()
        let root = builder.element(965_820), child = builder.element(965_821)
        state.permit = fault != "cutoff"
        let role: AnyObject = fault == "malformed_role" ? NSNumber(value: 1) : kAXScrollBarRole as NSString
        let children: AnyObject = fault == "malformed_children" ? "not children" as NSString
            : fault == "mixed_children" ? ["not an AX element"] as NSArray : [] as NSArray
        state.values = .success([role, children])
        let ax = AXHelpers.Runtime(axApp: { _ in root },
            attributeValue: { _, _ in Issue.record("no lossy fallback"); return nil },
            setAttributeValue: { _, _, _ in Issue.record("read-only"); return false },
            children: { _ in [] }, performAction: { _, _ in false }, childCount: { _ in 0 },
            childrenResult: { _ in state.childReads += 1; return .success([child]) },
            attributeValuesResult: { _, _ in
                state.batch += 1
                return fault == "batch_failure" ? .failure(.init(raw: AXError.invalidUIElement.rawValue))
                    : state.values
            })
        let result = AXHelpers.censusDescendantResult(of: root, role: kAXScrollBarRole as String,
            runtime: ax, requiresCompleteTraversal: true, batchingRoleAndChildren: true,
            permittingRead: { state.permit })
        guard case .failure(let error) = result else { Issue.record("an incomplete census cannot prove absence"); return }
        if fault == "cutoff" { #expect(state.childReads == 0 && state.batch == 0) }
        if fault == "batch_failure" { #expect(error.raw == AXError.invalidUIElement.rawValue) }
        #expect(builder.setCalls.isEmpty && builder.actionCalls.isEmpty)
    }

    private func runtime(_ state: Reads,
                         values: Result<[AnyObject], AXHelpers.AXStatusError>) -> AXHelpers.Runtime {
        state.values = values
        return AXHelpers.Runtime(axApp: { AXUIElementCreateApplication($0) },
            attributeValue: { _, _ in Issue.record("no lossy or native fallback"); return nil },
            setAttributeValue: { _, _, _ in Issue.record("read-only"); return false },
            children: { _ in [] }, performAction: { _, _ in false }, childCount: { _ in 0 },
            attributeValueResult: { _, attribute in
                state.singles.append(attribute)
                return .failure(.init(raw: AXError.cannotComplete.rawValue))
            }, attributeValuesResult: { _, _ in state.batch += 1; return state.values })
    }

    @Test func aSingleFreshCallPreservesRequestedPositionAndRawTypes() throws {
        let state = Reads(), element = AXUIElementCreateApplication(4242)
        let reads = AXHelpers.getNonHelpAttributes(element, ["AXValue", "AXTitle"],
            runtime: runtime(state, values: .success([NSNumber(value: 7), "Title" as NSString])))
        #expect(state.batch == 1 && state.singles.isEmpty)
        guard case .success(let value) = reads[0], case .success(let title) = reads[1] else {
            Issue.record("fresh values were discarded"); return
        }
        #expect((value as? NSNumber)?.intValue == 7)
        #expect(title as? String == "Title")
    }

    @Test func eachEmbeddedNativeStatusRemainsAStatus() throws {
        var absent = AXError.attributeUnsupported, failed = AXError.cannotComplete
        let first = try #require(AXValueCreate(.axError, &absent))
        let second = try #require(AXValueCreate(.axError, &failed))
        let state = Reads()
        let reads = AXHelpers.getNonHelpAttributes(AXUIElementCreateApplication(4242), ["AXValue", "AXSelectedText"],
            runtime: runtime(state, values: .success([first, second])))
        guard case .failure(let a) = reads[0], case .failure(let b) = reads[1] else {
            Issue.record("an embedded AX failure became a successful absence"); return
        }
        #expect(a.raw == absent.rawValue && b.raw == failed.rawValue)
        #expect(state.singles.isEmpty)
    }

    @Test func ambiguousNullNeedsAnActualStatusRead() {
        let state = Reads()
        let reads = AXHelpers.getNonHelpAttributes(AXUIElementCreateApplication(4242), ["AXValue"],
            runtime: runtime(state, values: .success([NSNull()])))
        guard case .failure(let error) = reads[0] else { Issue.record("null is not definitive absence"); return }
        #expect(error.raw == AXError.cannotComplete.rawValue)
        #expect(state.batch == 1 && state.singles == ["AXValue"])
    }

    @Test(arguments: [true, false]) func malformedOrFailedBatchCannotRebindByPosition(short: Bool) {
        let state = Reads()
        let payload: Result<[AnyObject], AXHelpers.AXStatusError> = short
            ? .success([NSNumber(value: 0)]) : .failure(.init(raw: AXError.invalidUIElement.rawValue))
        let reads = AXHelpers.getNonHelpAttributes(AXUIElementCreateApplication(4242), ["AXValue", "AXTitle"],
            runtime: runtime(state, values: payload))
        #expect(reads.count == 2)
        #expect(reads.allSatisfy { if case .failure = $0 { return true }; return false })
        #expect(state.singles.isEmpty)
    }

    @Test func helpCannotBypassItsPerReadGuardThroughABatch() {
        let state = Reads()
        let reads = AXHelpers.getNonHelpAttributes(AXUIElementCreateApplication(4242), ["AXTitle", "AXHelp"],
            runtime: runtime(state, values: .success(["Title" as NSString, "Help" as NSString])))
        #expect(state.batch == 0 && state.singles.isEmpty)
        #expect(reads.allSatisfy { if case .failure = $0 { return true }; return false })
    }

    @Test func aCutoffCannotStartTheBatchOrASecondFallbackRead() {
        let state = Reads(); state.permit = false
        _ = AXHelpers.getNonHelpAttributes(AXUIElementCreateApplication(4242), ["AXValue"],
            runtime: runtime(state, values: .success([NSNull()])), permittingRead: { state.permit })
        #expect(state.batch == 0 && state.singles.isEmpty)
        let fallback = AXHelpers.Runtime(axApp: { AXUIElementCreateApplication($0) },
            attributeValue: { _, _ in nil }, setAttributeValue: { _, _, _ in false },
            children: { _ in [] }, performAction: { _, _ in false }, childCount: { _ in 0 },
            attributeValueResult: { _, attribute in
                state.singles.append(attribute); state.permit = false
                return .success(NSNumber(value: 0))
            })
        state.permit = true
        let reads = AXHelpers.getNonHelpAttributes(AXUIElementCreateApplication(4242), ["AXValue", "AXTitle"],
            runtime: fallback, permittingRead: { state.permit })
        #expect(state.singles == ["AXValue"])
        guard case .failure = reads[1] else { Issue.record("a later read survived its cutoff"); return }
    }
}
