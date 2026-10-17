@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// T2 — drift-safe insert-slot enumeration (rev-4 D1/D4, AC12/AC21).
// audioPluginInsertSlots must preserve PHYSICAL slot positions and never drop
// an occupied-but-unreadable slot, and isEmpty (= write-safe) must be true
// ONLY for a verified-empty slot.

private func addEmptySlot(_ builder: FakeAXRuntimeBuilder, _ id: Int) -> AXUIElement {
    let el = builder.element(id)
    builder.setAttribute(el, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(el, kAXDescriptionAttribute as String, "오디오 플러그인")
    builder.setAttribute(el, kAXHelpAttribute as String, "오디오 이펙트 슬롯. 오디오 이펙트를 삽입합니다.")
    frameSlotRow(builder, el, id)
    return el
}

/// Inserts are numbered in screen order, so a chain of several needs frames: one row per slot,
/// top-down in the order the ids give them.
private func frameSlotRow(_ builder: FakeAXRuntimeBuilder, _ el: AXUIElement, _ id: Int) {
    builder.setAttribute(el, kAXPositionAttribute as String, axPoint(100, 300 + CGFloat(id % 100) * 20))
    builder.setAttribute(el, kAXSizeAttribute as String, axSize(58, 16))
}

/// Occupied slot group: AXGroup + bypass + open children. `name == nil` makes
/// it occupied-unreadable; a non-nil name makes it occupied-readable.
private func addOccupiedSlot(_ builder: FakeAXRuntimeBuilder, _ id: Int, name: String?) -> AXUIElement {
    let group = builder.element(id)
    let bypass = builder.element(id * 10 + 1)
    let open = builder.element(id * 10 + 2)
    builder.setAttribute(group, kAXRoleAttribute as String, kAXGroupRole as String)
    if let name { builder.setAttribute(group, kAXDescriptionAttribute as String, name) }
    builder.setChildren(group, [bypass, open])
    builder.setAttribute(bypass, kAXRoleAttribute as String, kAXCheckBoxRole as String)
    builder.setAttribute(bypass, kAXDescriptionAttribute as String, "바이패스")
    builder.setAttribute(bypass, kAXValueAttribute as String, 0)
    builder.setAttribute(open, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(open, kAXDescriptionAttribute as String, "열기")
    frameSlotRow(builder, group, id)
    return group
}

private func addFader(_ builder: FakeAXRuntimeBuilder, _ id: Int) -> AXUIElement {
    let el = builder.element(id)
    builder.setAttribute(el, kAXRoleAttribute as String, kAXSliderRole as String)
    builder.setAttribute(el, kAXDescriptionAttribute as String, "Volume Fader")
    return el
}

private func addFramedButton(
    _ builder: FakeAXRuntimeBuilder,
    _ id: Int,
    x: CGFloat = 100,
    y: CGFloat,
    width: CGFloat = 58,
    height: CGFloat = 18,
    description: String? = nil,
    help: String? = nil,
    subrole: String? = nil
) -> AXUIElement {
    let el = builder.element(id)
    builder.setAttribute(el, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(el, kAXPositionAttribute as String, axPoint(x, y))
    builder.setAttribute(el, kAXSizeAttribute as String, axSize(width, height))
    if let description { builder.setAttribute(el, kAXDescriptionAttribute as String, description) }
    if let help { builder.setAttribute(el, kAXHelpAttribute as String, help) }
    if let subrole { builder.setAttribute(el, kAXSubroleAttribute as String, subrole) }
    return el
}

// MARK: - AC12: physical index preserved across an unreadable occupied slot

@Test func testInsertSlotsPreservePhysicalIndexAcrossUnreadableOccupied() throws {
    let builder = FakeAXRuntimeBuilder()
    let strip = builder.element(500)
    let occ0 = addOccupiedSlot(builder, 501, name: "Gain")
    let unread1 = addOccupiedSlot(builder, 502, name: nil)       // occupied but name unreadable
    let occ2 = addOccupiedSlot(builder, 503, name: "Compressor")
    builder.setChildren(strip, [occ0, unread1, occ2])

    let slots = try #require(AXLogicProElements.audioPluginInsertSlots(in: strip, runtime: builder.makeAXRuntime()))

    #expect(slots.count == 3, "the unreadable occupied slot must NOT be dropped")
    #expect(slots[0].index == 0)
    #expect(slots[0].readStatus == .occupiedReadable)
    #expect(slots[0].name == "Gain")

    #expect(slots[1].index == 1, "physical index 1 must be preserved, not renumbered")
    #expect(slots[1].readStatus == .occupiedUnreadable)
    #expect(slots[1].name == nil)
    #expect(slots[1].occupied)
    #expect(!(slots[1].isEmpty), "AC21: occupied-unreadable is NOT write-safe")

    #expect(slots[2].index == 2, "the slot after an unreadable one keeps its physical index")
    #expect(slots[2].readStatus == .occupiedReadable)
    #expect(slots[2].name == "Compressor")
}

// MARK: - empty vs occupied classification

@Test(arguments: ["legacy", "batched", "noted"])
func knownIONegativeMetadataDoesNotRequirePluginHelp(mode: String) throws {
    final class Reads: @unchecked Sendable { var help = 0, guards = 0 }
    let attributes = [kAXIdentifierAttribute, kAXDescriptionAttribute, kAXTitleAttribute] as [String]
    for (offset, label) in ["Stereo Output", "Input slot", "출력 슬롯", "센드 슬롯"].enumerated() {
        for attribute in attributes {
            let builder = FakeAXRuntimeBuilder(), reads = Reads()
            let io = addFramedButton(builder, 1_971_800 + offset, y: 300,
                help: "Audio Plug-in")
            builder.setAttribute(io, attribute, label)
            builder.setChildren(io, [])
            let base = builder.makeAXRuntime()
            let read: @Sendable (AXUIElement, String) -> AnyObject? = { element, name in
                if name == kAXHelpAttribute as String { reads.help += 1 }
                return base.attributeValue(element, name)
            }
            let batch: (@Sendable (AXUIElement, [String]) -> Result<[AnyObject], AXHelpers.AXStatusError>)?
            if mode == "batched" {
                batch = { element, names in .success(names.map { read(element, $0) ?? NSNull() }) }
            } else { batch = nil }
            let raw = AXHelpers.Runtime(axApp: base.axApp, attributeValue: read,
                attributeIsSettable: base.attributeIsSettable,
                setAttributeValue: base.setAttributeValue, children: base.children,
                performAction: base.performAction, childCount: base.childCount,
                childrenResult: base.childrenResult,
                attributeValueResult: { .success(read($0, $1)) },
                attributeValuesResult: batch)
            let failures = AXPluginInstanceIdentity.FailedReads()
            let runtime = mode == "noted" ? AXPluginInstanceIdentity.noting(failures, over: raw) : raw
            let guardian = AXHelpers.HelpReadGuard(stop: { reads.guards += 1; return false })
            let slots = AXHelpers.HelpReadGuard.$current.withValue(guardian) {
                AXLogicProElements.audioPluginInsertSlots(children: [io], runtime: runtime)
            }
            #expect(slots.isEmpty)
            #expect(reads.help == 0 && reads.guards == 0,
                "Fresh metadata proves both existing negative predicates; even conflicting Help cannot make this button an insert")
            #expect(!failures.any)
            #expect(builder.setCalls.isEmpty && builder.actionCalls.isEmpty)
        }
    }
}

@Test(arguments: ["help_adds_io_exclusion", "help_identifies_insert"])
func undecidedInsertMetadataStillReachesItsFreshHelpGuard(mode: String) throws {
    final class Reads: @unchecked Sendable { var help = 0, guards = 0 }
    let builder = FakeAXRuntimeBuilder(), reads = Reads()
    let ioHelp = mode == "help_adds_io_exclusion"
    let button = addFramedButton(builder, 1_971_820, y: 300,
        description: ioHelp ? "Audio Plug-in" : "Unknown",
        help: ioHelp ? "Output slot" : "Audio Plug-in")
    builder.setChildren(button, [])
    let runtime = builder.makeAXRuntime(attributeValueHandler: { _, attribute in
        if attribute == kAXHelpAttribute as String { reads.help += 1 }
        return nil
    }, setAttributeHandler: nil, performActionHandler: nil)
    let guardian = AXHelpers.HelpReadGuard(stop: { reads.guards += 1; return false })
    let slots = AXHelpers.HelpReadGuard.$current.withValue(guardian) {
        AXLogicProElements.audioPluginInsertSlots(children: [button], runtime: runtime)
    }
    if ioHelp { #expect(slots.isEmpty) }
    else { #expect(slots.count == 1 && slots[0].isEmpty) }
    #expect(reads.help > 0 && reads.guards == reads.help)
    #expect(builder.setCalls.isEmpty && builder.actionCalls.isEmpty)
}

@Test(arguments: ["Stereo Output", "Input slot", "출력 슬롯", "센드 슬롯"])
func structuralOccupiedInsertKeepsItsDestinationShapedName(name: String) throws {
    let builder = FakeAXRuntimeBuilder()
    let occupied = addOccupiedSlot(builder, 1_971_830, name: name)
    let slots = AXLogicProElements.audioPluginInsertSlots(children: [occupied], runtime: builder.makeAXRuntime())
    #expect(slots.count == 1 && slots[0].readStatus == .occupiedReadable && slots[0].name == name)
    #expect(builder.setCalls.isEmpty && builder.actionCalls.isEmpty)
}

@Test func testEmptySlotIsWriteSafe() throws {
    let builder = FakeAXRuntimeBuilder()
    let strip = builder.element(520)
    let empty = addEmptySlot(builder, 521)
    builder.setChildren(strip, [empty])

    let slots = try #require(AXLogicProElements.audioPluginInsertSlots(in: strip, runtime: builder.makeAXRuntime()))
    #expect(slots.count == 1)
    #expect(slots[0].readStatus == .empty)
    #expect(slots[0].isEmpty)
    #expect(!(slots[0].occupied))
    #expect(slots[0].name == nil)
}

@Test func testNonSlotChildrenDoNotConsumeAnIndex() throws {
    // A fader/pan between recognised slots must not shift slot indices.
    let builder = FakeAXRuntimeBuilder()
    let strip = builder.element(540)
    let fader = addFader(builder, 541)
    let empty = addEmptySlot(builder, 542)
    let occ = addOccupiedSlot(builder, 543, name: "Channel EQ")
    builder.setChildren(strip, [fader, empty, occ])

    let slots = try #require(AXLogicProElements.audioPluginInsertSlots(in: strip, runtime: builder.makeAXRuntime()))
    #expect(slots.count == 2, "fader is not an insert slot")
    #expect(slots[0].readStatus == .empty && slots[0].index == 0)
    #expect(slots[1].readStatus == .occupiedReadable && slots[1].index == 1 && slots[1].name == "Channel EQ")
}

// MARK: - mixed inventory (AC12 full scenario)

@Test func testMixedReadableEmptyUnreadableSequence() throws {
    let builder = FakeAXRuntimeBuilder()
    let strip = builder.element(560)
    let occReadable = addOccupiedSlot(builder, 561, name: "Noise Gate")
    let empty = addEmptySlot(builder, 562)
    let occUnreadable = addOccupiedSlot(builder, 563, name: nil)
    builder.setChildren(strip, [occReadable, empty, occUnreadable])

    let slots = try #require(AXLogicProElements.audioPluginInsertSlots(in: strip, runtime: builder.makeAXRuntime()))
    #expect(slots.map(\.readStatus) == [.occupiedReadable, .empty, .occupiedUnreadable])
    #expect(slots.map(\.index) == [0, 1, 2])
    #expect(!(slots[2].isEmpty), "an unreadable slot is never treated as the empty slot")
}

@Test func testLanguageNeutralEmptySlotClusterIsRecognizedByGeometry() throws {
    let builder = FakeAXRuntimeBuilder()
    let strip = builder.element(580)
    let output = addFramedButton(builder, 581, y: 560, description: "Ausgang")
    let send = addFramedButton(builder, 582, y: 540, width: 40, description: "Send")
    let slot0 = addFramedButton(builder, 583, y: 500)
    let slot1 = addFramedButton(builder, 584, y: 483)
    let slot2 = addFramedButton(builder, 585, y: 466)
    let slot3 = addFramedButton(builder, 586, y: 449)
    let input = addFramedButton(builder, 587, y: 420, description: "Eingang")
    builder.setChildren(strip, [output, send, slot0, slot1, slot2, slot3, input])

    let slots = try #require(AXLogicProElements.audioPluginInsertSlots(in: strip, runtime: builder.makeAXRuntime()))

    #expect(slots.count == 4)
    #expect(slots.map(\.index) == [0, 1, 2, 3])
    #expect(slots.allSatisfy { $0.isEmpty })
}

@Test func testLanguageNeutralGeometryDoesNotPromoteSingleButtonOrPhantomStub() throws {
    let builder = FakeAXRuntimeBuilder()
    let strip = builder.element(590)
    let settings = addFramedButton(builder, 591, y: 500, description: "Einstellungen")
    let phantom = addFramedButton(builder, 592, y: 470, width: 58, height: 9)
    builder.setChildren(strip, [settings, phantom])

    let slots = try #require(AXLogicProElements.audioPluginInsertSlots(in: strip, runtime: builder.makeAXRuntime()))

    #expect(slots.isEmpty)
}
