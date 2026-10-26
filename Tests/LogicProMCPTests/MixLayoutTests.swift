import Foundation
import MCP
import Testing
@testable import LogicProMCP

private let tracks = ["Kick", "Snare", "HH", "OH L", "OH R", "Bass", "Gtr L", "Gtr R", "Keys", "Vox Lead", "Vox BV1", "Vox BV2"]

private func spec(_ object: [String: Value]) throws -> MixLayoutSpec {
    try MixLayoutSpec.parse(.object(object)).get()
}

private func plan(_ spec: MixLayoutSpec, names: [String] = tracks, used: Set<Int> = []) -> MixLayoutPlanner.Plan {
    MixLayoutPlanner.plan(spec: spec, trackNames: names, usedBuses: used,
                          pluginInsertable: { ["ChromaVerb", "Stereo Delay"].contains($0) }, colorKnown: { _ in true })
}

@Test("track names match exactly first, then case-insensitively, and never by guess")
func mixLayoutNameMatching() {
    #expect(MixLayoutNames.match("Kick", in: ["Kick", "kick"]) == .exact("Kick"))
    #expect(MixLayoutNames.match("KICK", in: ["Kick", "Snare"]) == .caseInsensitive("Kick"))
    #expect(MixLayoutNames.match("kick", in: ["Kick", "KICK"]) == .ambiguous(["Kick", "KICK"]))
    #expect(MixLayoutNames.match("Kick", in: ["Kick", "Kick"]) == .ambiguous(["Kick", "Kick"]))
    #expect(MixLayoutNames.match("Tom", in: ["Kick"]) == .missing)
}

@Test("the spec parser refuses unknown keys and malformed rows")
func mixLayoutSpecParsing() {
    guard case .failure = MixLayoutSpec.parse(.object(["orders": .array([])])) else { Issue.record("unknown key accepted"); return }
    guard case .failure = MixLayoutSpec.parse(.object(["groups": .array([.object(["name": .string("D"), "members": .array([])])])])) else {
        Issue.record("empty group accepted"); return
    }
    guard case .failure = MixLayoutSpec.parse(.object(["sends": .array([.object(["from": .array([.string("Kick")]), "to": .string("Plate")])])])) else {
        Issue.record("send without level accepted"); return
    }
    guard case .failure = MixLayoutSpec.parse(.object([:])) else { Issue.record("empty spec accepted"); return }
}

@Test("the CLAUDE.md layout plans bus groups, FX returns, sends and levels with free buses")
func mixLayoutFullPlan() throws {
    let layout = try spec([
        "order": .array(tracks.map { .string($0) }),
        "groups": .array([
            .object(["name": .string("DRUMS"), "type": .string("bus"), "color": .string("red"),
                     "members": .array(["Kick", "Snare", "HH", "OH L", "OH R"].map { .string($0) })]),
            .object(["name": .string("VOX"), "color": .string("yellow"),
                     "members": .array(["Vox Lead", "Vox BV1", "Vox BV2"].map { .string($0) })]),
        ]),
        "fx_returns": .array([
            .object(["name": .string("Plate"), "plugins": .array([.string("ChromaVerb")]), "color": .string("purple")]),
        ]),
        "sends": .array([
            .object(["from": .array([.string("snare"), .string("Vox Lead")]), "to": .string("Plate"), "level_db": .int(-12)]),
        ]),
    ])
    let result = plan(layout, used: [1, 3])
    #expect(result.blockers.isEmpty)
    #expect(result.buses == ["DRUMS": 2, "VOX": 4, "Plate": 5])
    #expect(result.caseInsensitiveMatches == ["snare": "Snare"])
    #expect(!result.steps.contains { if case .moveTrack = $0 { true } else { false } })   // already in order
    #expect(result.steps.first == .routeOutput(track: "Kick", bus: 2, createReceiver: true, owner: "DRUMS"))
    #expect(result.steps.contains(.routeOutput(track: "Snare", bus: 2, createReceiver: false, owner: "DRUMS")))
    #expect(result.steps.contains(.createSend(from: "Snare", bus: 5, createReceiver: true, owner: "Plate")))
    #expect(result.steps.contains(.createSend(from: "Vox Lead", bus: 5, createReceiver: false, owner: "Plate")))
    #expect(result.steps.contains(.createTrackForReceiver(owner: "Plate", after: nil)))
    #expect(result.steps.contains(.insertPlugin(track: "Plate", plugin: "ChromaVerb", slot: 0)))
    #expect(result.steps.contains(.setSendLevel(from: "Snare", bus: 5, levelDB: -12)))
    // Colours come last, together, for the group track and its members.
    let firstColor = try #require(result.steps.firstIndex { if case .setColor = $0 { true } else { false } })
    #expect(result.steps[firstColor...].allSatisfy { if case .setColor = $0 { true } else { false } })
    #expect(result.steps.contains(.setColor(track: "DRUMS", color: "red")))
    #expect(result.steps.contains(.setColor(track: "OH R", color: "red")))
    #expect(result.steps.contains(.setColor(track: "Plate", color: "purple")))
    #expect(plan(layout, used: [1, 3]).hash == result.hash)
    #expect(plan(layout, used: [1]).hash != result.hash)
}

@Test("blockers: missing and ambiguous names, conflicts, a top move, an unknown plug-in")
func mixLayoutBlockers() throws {
    let layout = try spec([
        "order": .array([.string("Snare"), .string("Kick")]),
        "groups": .array([
            .object(["name": .string("kick"), "members": .array([.string("Tom")])]),
            .object(["name": .string("A"), "members": .array([.string("Bass")])]),
            .object(["name": .string("B"), "type": .string("summing"), "members": .array([.string("Bass")])]),
        ]),
        "fx_returns": .array([.object(["name": .string("Verb"), "plugins": .array([.string("Fancy Reverb")])])]),
    ])
    let codes = Set(plan(layout, names: tracks + ["kick"]).blockers.map(\.code))
    #expect(codes.isSuperset(of: ["order_needs_top_move", "track_not_found", "name_conflict",
                                  "member_in_two_groups", "plugin_not_insertable", "fx_return_without_send"]))
    let ambiguous = try spec(["order": .array([.string("kick"), .string("Snare")])])
    #expect(plan(ambiguous, names: ["Kick", "KICK", "Snare"]).blockers.map(\.code) == ["track_ambiguous"])
}

@Test("bus numbers are read from input, output and send titles")
func mixLayoutBusNumbers() {
    #expect(MixLayoutPlanner.busNumbers(in: ["Bus 6", "Bus 6 → Aux 1", "Stereo Output", "Bus 12", "Input 3-4"]) == [6, 12])
    #expect(MixLayoutSaga.formatLevel(-12) == "-12")
    #expect(MixLayoutSaga.formatLevel(-12.5) == "-12.5")
}

@Test("an aux track's colour record (0x00 marker) is read only when it is the name's single record")
func auxTrackColorRecord() {
    func record(_ marker: UInt8, _ color: UInt8, _ name: String) -> [UInt8] {
        [0, 0, 0, 0, marker, color, 0, 0, UInt8(name.utf8.count), 0] + Array(name.utf8) + [0, 0]
    }
    let aux = Data(record(0x00, 73, "DRUMS"))
    #expect(TrackColorProjectFile.colorIndex(trackName: "DRUMS", projectData: aux) == .found(73))
    let both = Data(record(0x00, 0, "Kick") + record(0x80, 73, "Kick"))
    #expect(TrackColorProjectFile.colorIndex(trackName: "Kick", projectData: both) == .found(73))
    let twoAux = Data(record(0x00, 73, "VOX") + record(0x00, 77, "VOX"))
    #expect(TrackColorProjectFile.colorIndex(trackName: "VOX", projectData: twoAux) == .absent)
}
