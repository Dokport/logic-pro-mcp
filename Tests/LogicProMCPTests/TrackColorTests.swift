import CoreGraphics
import Foundation
import MCP
import Testing
@testable import LogicProMCP

// MARK: - Palette: visible position ↔ stored index ↔ name

@Test("stored indices follow the measured row order: row 2 holds 1-24, row 1 holds 73-96")
func trackColorStoredIndexFollowsMeasuredRowOrder() {
    #expect(TrackColorPalette.storedIndex(row: 2, column: 1) == 1)
    #expect(TrackColorPalette.storedIndex(row: 2, column: 24) == 24)
    #expect(TrackColorPalette.storedIndex(row: 3, column: 1) == 25)
    #expect(TrackColorPalette.storedIndex(row: 4, column: 1) == 49)
    #expect(TrackColorPalette.storedIndex(row: 1, column: 1) == 73)
    #expect(TrackColorPalette.storedIndex(row: 1, column: 24) == 96)
    #expect(TrackColorPalette.storedIndex(row: 0, column: 1) == nil)
    #expect(TrackColorPalette.storedIndex(row: 1, column: 25) == nil)
    // Every stored index names exactly one swatch, and back.
    let all = (1...4).flatMap { row in (1...24).compactMap { TrackColorPalette.storedIndex(row: row, column: $0) } }
    #expect(Set(all) == Set(1...96))
    for stored in 1...96 {
        let swatch = TrackColorPalette.swatch(storedIndex: stored)
        #expect(swatch?.storedIndex == stored)
    }
}

@Test("the default audio-track colour is the swatch the palette outlined for a new track")
func trackColorDefaultIsRowTwoColumnSixteen() {
    let swatch = TrackColorPalette.swatch(storedIndex: TrackColorPalette.defaultAudioTrackStoredIndex)
    #expect(swatch?.row == 2)
    #expect(swatch?.column == 16)
    #expect(swatch?.rgb == "#4177AE")
}

@Test("names resolve to a column, shade words to a row, case-insensitively")
func trackColorNamesResolve() {
    #expect(TrackColorPalette.resolve(name: "red") == .resolved(TrackColorPalette.swatch(row: 1, column: 1)!))
    #expect(TrackColorPalette.resolve(name: "Blue") == .resolved(TrackColorPalette.swatch(row: 1, column: 17)!))
    #expect(TrackColorPalette.resolve(name: "dark  blue") == .resolved(TrackColorPalette.swatch(row: 3, column: 17)!))
    #expect(TrackColorPalette.resolve(name: "darkest green") == .resolved(TrackColorPalette.swatch(row: 4, column: 9)!))
    #expect(TrackColorPalette.resolve(name: "sky blue") == .resolved(TrackColorPalette.swatch(row: 1, column: 15)!))
    #expect(TrackColorPalette.resolve(name: "medium sky blue") == .resolved(TrackColorPalette.swatch(row: 2, column: 15)!))
    #expect(TrackColorPalette.resolve(name: "yellow") == .resolved(TrackColorPalette.swatch(row: 1, column: 5)!))
    #expect(TrackColorPalette.resolve(name: "purple") == .resolved(TrackColorPalette.swatch(row: 1, column: 21)!))
    #expect(TrackColorPalette.resolve(name: "chartreuse-ish") == .unknownName("chartreuse-ish"))
    #expect(TrackColorPalette.resolve(name: "dark") == .unknownName("dark"))
    #expect(TrackColorPalette.resolve(name: "") == .unknownName(""))
    #expect(TrackColorPalette.resolve(row: 5, column: 1) == .outOfRange("row 5, column 1"))
    #expect(TrackColorPalette.resolve(storedIndex: 0) == .outOfRange("stored index 0"))
}

// MARK: - Geometry: click points come from the palette's own children

/// The child positions Logic 12.4 reported for a palette whose grid starts at (249, 698): child 0
/// is the reset button, 1-24 are visible row 3, 25-48 row 4, 49-72 the TOP row reported 80 pt
/// too low, 73-96 row 2.
private func measuredPaletteChildren(originX: CGFloat = 249, row2Y: CGFloat = 698) -> [CGPoint] {
    var points = [CGPoint(x: originX - 29, y: row2Y + 2)]
    let rowYByChildBlock: [CGFloat] = [row2Y + 20, row2Y + 40, row2Y + 60, row2Y]
    for block in 0..<4 {
        for column in 0..<24 {
            points.append(CGPoint(x: originX + CGFloat(column) * 28, y: rowYByChildBlock[block]))
        }
    }
    return points
}

@Test("trusted rows click at their own child; the top row is derived one pitch above row 2")
func trackColorClickPointsDeriveFromTrustedRows() {
    let children = measuredPaletteChildren()
    #expect(TrackColorPaletteGeometry.clickPoint(row: 3, column: 1, childPositions: children)
        == .point(CGPoint(x: 261, y: 726)))
    #expect(TrackColorPaletteGeometry.clickPoint(row: 2, column: 24, childPositions: children)
        == .point(CGPoint(x: 249 + 23 * 28 + 12, y: 706)))
    // Measured: a click at the top row's own reported position landed on nothing; one pitch
    // above row 2 set stored index 73 and 80.
    #expect(TrackColorPaletteGeometry.clickPoint(row: 1, column: 1, childPositions: children)
        == .point(CGPoint(x: 261, y: 686)))
}

@Test("a palette whose trusted rows disagree is refused, never clicked")
func trackColorGeometryRefusesUnrecognisedLayouts() {
    var tooFew = measuredPaletteChildren()
    tooFew.removeLast()
    guard case .layoutUnrecognized = TrackColorPaletteGeometry.clickPoint(row: 1, column: 1, childPositions: tooFew) else {
        Issue.record("96 children must be refused")
        return
    }
    var bent = measuredPaletteChildren()
    bent[5].y += 3
    guard case .layoutUnrecognized = TrackColorPaletteGeometry.clickPoint(row: 2, column: 1, childPositions: bent) else {
        Issue.record("a row that is not one line must be refused")
        return
    }
    var skewed = measuredPaletteChildren()
    skewed[30].x += 4
    guard case .layoutUnrecognized = TrackColorPaletteGeometry.clickPoint(row: 2, column: 1, childPositions: skewed) else {
        Issue.record("a column that is not one line must be refused")
        return
    }
}

// MARK: - ProjectData: the colour byte in the track record

private func trackRecord(color: UInt8, name: String) -> [UInt8] {
    let bytes = Array(name.utf8)
    return [0x00, 0x80, color, 0x00, 0x00, UInt8(bytes.count & 0xFF), UInt8(bytes.count >> 8)] + bytes + [0x01, 0x00]
}

@Test("the colour byte is read from the one record carrying the track's name")
func trackColorProjectFileReadsTheRecord() {
    // A channel-strip name occurrence with a different prefix must not count (measured: "Kick"
    // also appears earlier in ProjectData without the track-record prefix).
    let data = Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00] + Array("Kick".utf8)
        + trackRecord(color: 16, name: "Kick") + trackRecord(color: 41, name: "Snare"))
    #expect(TrackColorProjectFile.colorIndex(trackName: "Kick", projectData: data) == .found(16))
    #expect(TrackColorProjectFile.colorIndex(trackName: "Snare", projectData: data) == .found(41))
    #expect(TrackColorProjectFile.colorIndex(trackName: "HH", projectData: data) == .absent)
    let twice = Data(trackRecord(color: 3, name: "Vox") + trackRecord(color: 4, name: "Vox"))
    #expect(TrackColorProjectFile.colorIndex(trackName: "Vox", projectData: twice) == .ambiguous(2))
    // A name that is a suffix of a longer one is a different length prefix, so it is not a match.
    let longer = Data(trackRecord(color: 9, name: "Vox Lead"))
    #expect(TrackColorProjectFile.colorIndex(trackName: "Lead", projectData: longer) == .absent)
}

// MARK: - Readback: State A only from the saved record

private func channelStateB(trackName: String) -> ChannelResult {
    .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: [
        "operation": "track.set_color", "track": 0, "track_name": trackName, "write_attempted": true,
    ]))
}

@Test("project-file readback awards State A only when the saved record holds the requested index")
func trackColorProjectReadbackVerdicts() async throws {
    let bundle = FileManager.default.temporaryDirectory
        .appendingPathComponent("TrackColorReadback-\(UUID().uuidString).logicx", isDirectory: true)
    try FileManager.default.createDirectory(
        at: bundle.appendingPathComponent("Alternatives/000", isDirectory: true),
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: bundle) }
    let saved: ChannelResult = .success(HonestContract.encodeStateA(extras: ["document_path": bundle.path]))
    let red = try #require(TrackColorPalette.swatch(row: 1, column: 1))

    let match = await TrackColorProjectReadback.verify(
        channelResult: channelStateB(trackName: "Kick"), expected: red,
        save: { saved }, readProjectData: { _ in Data(trackRecord(color: 73, name: "Kick")) }
    )
    let matchJSON = try #require(decodedJSONObject(match.message))
    #expect(matchJSON["state"] as? String == "A")
    #expect(matchJSON["observed_stored_index"] as? Int == 73)

    let other = await TrackColorProjectReadback.verify(
        channelResult: channelStateB(trackName: "Kick"), expected: red,
        save: { saved }, readProjectData: { _ in Data(trackRecord(color: 16, name: "Kick")) }
    )
    let otherJSON = try #require(decodedJSONObject(other.message))
    #expect(otherJSON["state"] as? String == "B")
    #expect(otherJSON["reason"] as? String == "readback_mismatch")

    let unsaved = await TrackColorProjectReadback.verify(
        channelResult: channelStateB(trackName: "Kick"), expected: red,
        save: { .success(HonestContract.encodeStateB(reason: .readbackUnavailable)) },
        readProjectData: { _ in Issue.record("nothing may be read after an unverified save"); return nil }
    )
    let unsavedJSON = try #require(decodedJSONObject(unsaved.message))
    #expect(unsavedJSON["state"] as? String == "B")
    #expect(unsavedJSON["readback_detail"] as? String == "project_save_unverified")
}

// MARK: - Dispatcher: request shape and binding are refused before routing

@Test("the colour parameter accepts a name, a stored index, or {row, column}")
func trackColorParameterShapes() {
    #expect(TrackDispatcher.trackColorResolution(.string("red")) == .resolved(TrackColorPalette.swatch(row: 1, column: 1)!))
    #expect(TrackDispatcher.trackColorResolution(.string("16")) == .resolved(TrackColorPalette.swatch(row: 2, column: 16)!))
    #expect(TrackDispatcher.trackColorResolution(.int(41)) == .resolved(TrackColorPalette.swatch(row: 3, column: 17)!))
    #expect(TrackDispatcher.trackColorResolution(.object(["row": .int(4), "column": .int(24)]))
        == .resolved(TrackColorPalette.swatch(row: 4, column: 24)!))
    #expect(TrackDispatcher.trackColorResolution(.object(["row": .int(4), "column": .int(24), "hue": .int(1)])) == nil)
    #expect(TrackDispatcher.trackColorResolution(.bool(true)) == nil)
    #expect(TrackDispatcher.trackColorResolution(nil) == nil)
}

@Test("set_color is corroborated: a bare index is refused before anything is routed")
func trackSetColorRequiresCorroboration() async throws {
    let router = ChannelRouter()
    let result = await TrackDispatcher.handle(
        command: "set_color",
        params: ["index": .int(0), "color": .string("red")],
        router: router,
        cache: StateCache()
    )
    #expect(result.isError == true)
    let text = sharedToolText(result)
    #expect(text.contains("index_binding_corroboration_required"))
    #expect(OperationRegistry.spec(tool: "logic_tracks", command: "set_color")?.indexBinding == .corroborated)
}

@Test("an unknown colour name is refused with the names that exist")
func trackSetColorRefusesUnknownNames() async throws {
    let result = await TrackDispatcher.handle(
        command: "set_color",
        params: ["index": .int(0), "expected_name": .string("Kick"), "color": .string("ultraviolet")],
        router: ChannelRouter(),
        cache: StateCache()
    )
    #expect(result.isError == true)
    let text = sharedToolText(result)
    #expect(text.contains("unknown_color_name"))
    #expect(text.contains("write_attempted"))
}
