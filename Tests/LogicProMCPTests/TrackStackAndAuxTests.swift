import Foundation
import Testing
@testable import LogicProMCP

// MARK: - create_stack: members and the measured rail shape

@Test("members resolve by exact, unique name; anything else is refused before selection")
func trackStackMembersResolveExactly() {
    let names = ["Kick", "Snare", "HH", "OH L", "OH R", "Bass", "Vox", "Vox"]
    #expect(TrackStackVerifier.resolveMembers(["HH", "Kick"], in: names) == .resolved([0, 2]))
    #expect(TrackStackVerifier.resolveMembers(["kick"], in: names) == .missing(["kick"]))
    #expect(TrackStackVerifier.resolveMembers(["Vox"], in: names) == .ambiguous(["Vox"]))
    #expect(TrackStackVerifier.resolveMembers(["HH", "HH"], in: names) == .duplicateMembers(["HH"]))
    #expect(TrackStackVerifier.resolveMembers([], in: names) == .tooFew)
}

@Test("the expected rail gathers members after a new main track at the first member's place")
func trackStackExpectedRailMatchesTheMeasurement() {
    // Measured on Logic 12.4: HH and OH R selected out of Kick, Snare, HH, OH L, OH R, Bass gave
    // Kick, Snare, Sum 1, HH, OH R, OH L, Bass.
    let before = ["Kick", "Snare", "HH", "OH L", "OH R", "Bass"]
    #expect(TrackStackVerifier.expectedAfter(before: before, memberIndices: [2, 4])
        == ["Kick", "Snare", nil, "HH", "OH R", "OH L", "Bass"])
    #expect(TrackStackVerifier.expectedAfter(before: before, memberIndices: [0, 1, 2])
        == [nil, "Kick", "Snare", "HH", "OH L", "OH R", "Bass"])
}

@Test("only the exact rail with a stack main track in place is verified")
func trackStackVerdicts() {
    let before = ["Kick", "Snare", "HH", "OH L", "OH R", "Bass"]
    func rows(_ names: [String], stackAt: Int?) -> [TrackStackVerifier.Row] {
        names.enumerated().map { .init(name: $0.element, isStackHeader: $0.offset == stackAt) }
    }
    #expect(TrackStackVerifier.verify(before: before, memberIndices: [2, 4],
        after: rows(["Kick", "Snare", "Sum 1", "HH", "OH R", "OH L", "Bass"], stackAt: 2))
        == .verified(headerIndex: 2, headerName: "Sum 1"))
    #expect(TrackStackVerifier.verify(before: before, memberIndices: [2, 4], after: rows(before, stackAt: nil)) == .unchanged)
    guard case .mismatch = TrackStackVerifier.verify(before: before, memberIndices: [2, 4],
        after: rows(["Kick", "Snare", "Sum 1", "HH", "OH R", "OH L", "Bass"], stackAt: nil)) else {
        Issue.record("a new row that is not a stack main track must not verify")
        return
    }
    guard case .mismatch = TrackStackVerifier.verify(before: before, memberIndices: [2, 4],
        after: rows(["Kick", "Snare", "Sum 1", "OH R", "HH", "OH L", "Bass"], stackAt: 2)) else {
        Issue.record("members out of their original order must not verify")
        return
    }
}

@Test("create_stack refuses malformed requests before routing")
func trackCreateStackRefusals() async {
    let empty = await TrackDispatcher.handle(command: "create_stack", params: ["members": .array([])],
                                             router: ChannelRouter(), cache: StateCache())
    #expect(sharedToolText(empty).contains("members_invalid"))
    let badKind = await TrackDispatcher.handle(command: "create_stack",
                                               params: ["members": .array([.string("Kick")]), "kind": .string("vca")],
                                               router: ChannelRouter(), cache: StateCache())
    #expect(sharedToolText(badKind).contains("unknown_kind"))
}

// MARK: - create_aux: the strip census

@Test("one new strip with every existing strip unchanged is the only success")
func createAuxVerdicts() {
    let before = ["Kick", "Snare", "Stereo Out", "Master"]
    #expect(CreateAuxVerifier.verdict(before: before, after: ["Kick", "Snare", "Aux 1", "Stereo Out", "Master"])
        == .created(name: "Aux 1", position: 2))
    #expect(CreateAuxVerifier.verdict(before: before, after: before) == .unchanged)
    // A second "Aux 1" is still one new strip.
    #expect(CreateAuxVerifier.verdict(before: ["Aux 1", "Master"], after: ["Aux 1", "Aux 1", "Master"])
        == .created(name: "Aux 1", position: 1))
    guard case .unexpected = CreateAuxVerifier.verdict(before: before, after: ["Kick", "Aux 1", "Aux 2", "Snare", "Stereo Out", "Master"]) else {
        Issue.record("two new strips must not verify")
        return
    }
    guard case .unexpected = CreateAuxVerifier.verdict(before: before, after: ["Snare", "Kick", "Aux 1", "Stereo Out", "Master"]) else {
        Issue.record("reordered existing strips must not verify")
        return
    }
}

// MARK: - Send level tokens

@Test("send levels normalize across decimal marks and minus signs, within -144...+6 dB")
func sendLevelTokens() {
    #expect(AccessibilityChannel.sendLevelToken("-95") == "-95")
    #expect(AccessibilityChannel.sendLevelToken("-95.0") == "-95")
    #expect(AccessibilityChannel.sendLevelToken("-95,0") == "-95")   // Danish number format, measured
    #expect(AccessibilityChannel.sendLevelToken("−12") == "-12")
    #expect(AccessibilityChannel.sendLevelToken("-18,5") == "-18.5")
    #expect(AccessibilityChannel.sendLevelToken("-∞") == "-∞")
    #expect(AccessibilityChannel.sendLevelToken("0") == "0")
    #expect(AccessibilityChannel.sendLevelToken("+6") == "6")
    #expect(AccessibilityChannel.sendLevelToken("-200") == nil)
    #expect(AccessibilityChannel.sendLevelToken("7") == nil)
    #expect(AccessibilityChannel.sendLevelToken("loud") == nil)
}

@Test("a written send level agrees with the knob's quantized display within 0.2 dB")
func sendLevelsAgreeWithinQuantization() {
    #expect(AccessibilityChannel.sendLevelsAgree("-18,1", "-18"))   // measured on Logic 12.4
    #expect(AccessibilityChannel.sendLevelsAgree("-12,0", "-12"))
    #expect(!AccessibilityChannel.sendLevelsAgree("-18,4", "-18"))
    #expect(AccessibilityChannel.sendLevelsAgree("-∞", "-∞"))
    #expect(!AccessibilityChannel.sendLevelsAgree("-95,0", "-∞"))
}

// MARK: - strip_silence

@Test("strip silence values are typed with the field's own decimal mark and precision")
func stripSilenceTypedValues() {
    #expect(StripSilenceSettings.typed(-28, field: .threshold, decimalMark: ",") == "-28")
    #expect(StripSilenceSettings.typed(0.1, field: .minimumSilence, decimalMark: ",") == "0,1000")
    #expect(StripSilenceSettings.typed(0.006, field: .preAttack, decimalMark: ".") == "0.0060")
    #expect(StripSilenceSettings.decimalMark(of: "0,1000") == ",")
    #expect(StripSilenceSettings.agrees("0,1000", 0.1, field: .minimumSilence))
    #expect(StripSilenceSettings.agrees("-40", -40, field: .threshold))
    #expect(!StripSilenceSettings.agrees("-38", -40, field: .threshold))   // measured: a stepped field drifted
    #expect(StripSilenceSettings.previewCount("16 Regions") == 16)
    #expect(StripSilenceSettings.previewCount("1 Region") == 1)
    #expect(StripSilenceSettings.previewCount("dB") == nil)
}

@Test("strip silence settings outside the dialog's ranges are refused")
func stripSilenceRanges() {
    #expect(StripSilenceSettings.validated(threshold: -40, minimum: nil, preAttack: nil, postRelease: nil)
        == .valid(StripSilenceSettings(thresholdDB: -40)))
    guard case .outOfRange = StripSilenceSettings.validated(threshold: 3, minimum: nil, preAttack: nil, postRelease: nil) else {
        Issue.record("a positive threshold must be refused")
        return
    }
    guard case .outOfRange = StripSilenceSettings.validated(threshold: nil, minimum: -1, preAttack: nil, postRelease: nil) else {
        Issue.record("a negative time must be refused")
        return
    }
}
