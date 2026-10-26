import CoreGraphics
import Foundation

/// One swatch of Logic's track colour palette (Track > Assign Track Color…).
///
/// `row` and `column` are the VISIBLE grid position, 1-based, row 1 at the top. `storedIndex`
/// is the value Logic writes into the track record of `ProjectData` when that swatch is chosen.
/// `rgb` is the swatch centre read from a screenshot of the palette, converted to sRGB; it is a
/// description for callers, never an input to actuation or verification.
struct TrackColorSwatch: Sendable, Equatable {
    let row: Int
    let column: Int
    let storedIndex: Int
    let rgb: String
}

/// The track colour palette as measured on Logic Pro 12.4 (en-US) on 2026-10-26.
///
/// Nothing about it is readable through Accessibility: the palette's 97 children answer every
/// attribute except `AXPosition` with `kAXErrorNoValue`, `AXPress` on a swatch reports success
/// and changes nothing, and no element anywhere carries a colour attribute (#448). Each fact
/// below therefore comes from a measurement, recorded in `research/FINDINGS.md`:
///
/// - the visible layout (24 columns × 4 rows, brightest row on top) and every swatch's colour
///   come from a user screenshot of the palette (`research/palette/palette-12.4.json`);
/// - the stored index of each visible position was measured by clicking a swatch, saving, and
///   reading the track record, and one position was confirmed visually by the palette's own
///   selection outline;
/// - AX child `k` (1…96) is stored index `((k - 1 + 24) mod 96) + 1`; the 24 children of the
///   TOP row report an `AXPosition` 80 pt below the grid, so their click point is derived from
///   the row beneath (see `TrackColorPaletteGeometry`). Child 0 is the reset button.
enum TrackColorPalette {
    static let measuredLogicVersion = "12.4"
    static let columns = 24
    static let rows = 4
    /// The colour Logic gives a new audio track (row 2, column 16).
    static let defaultAudioTrackStoredIndex = 16

    /// Stored index for a visible position: row 1 → 73…96, row 2 → 1…24, row 3 → 25…48,
    /// row 4 → 49…72.
    static func storedIndex(row: Int, column: Int) -> Int? {
        guard (1...rows).contains(row), (1...columns).contains(column) else { return nil }
        let rowBase = [1: 72, 2: 0, 3: 24, 4: 48][row]!
        return rowBase + column
    }

    static func swatch(row: Int, column: Int) -> TrackColorSwatch? {
        guard let storedIndex = storedIndex(row: row, column: column) else { return nil }
        return TrackColorSwatch(
            row: row,
            column: column,
            storedIndex: storedIndex,
            rgb: measuredRGB[row - 1][column - 1]
        )
    }

    static func swatch(storedIndex: Int) -> TrackColorSwatch? {
        guard (1...(rows * columns)).contains(storedIndex) else { return nil }
        for row in 1...rows {
            for column in 1...columns where self.storedIndex(row: row, column: column) == storedIndex {
                return swatch(row: row, column: column)
            }
        }
        return nil
    }

    /// Swatch centres from the 2026-10-26 screenshot, sRGB, visible row by visible row.
    static let measuredRGB: [[String]] = [
        ["#CC4925", "#CC6529", "#CC842E", "#CCA937", "#CCCB41", "#AACA3F", "#86CA3E", "#63C93E",
         "#1FC94C", "#1FC96B", "#21C98B", "#23CAAC", "#27CBCC", "#25AACA", "#349DCF", "#428BD3",
         "#4A72D4", "#5153D6", "#6851D4", "#804BD2", "#9744CF", "#AB30C9", "#CD34C8", "#CC31A7"],
        ["#A84528", "#A85B2B", "#A8722F", "#A88E34", "#A8A73A", "#8EA639", "#74A638", "#59A638",
         "#24A545", "#24A65F", "#26A677", "#28A790", "#28A7A8", "#288EA7", "#3584A9", "#4177AE",
         "#4766AF", "#4D4EB1", "#5E4CAE", "#6F47AD", "#8242AD", "#8F30A5", "#A932A5", "#A9308C"],
        ["#843E28", "#844D2A", "#835E2C", "#84712F", "#838333", "#718233", "#5F8232", "#4B8232",
         "#26823D", "#268250", "#278361", "#288373", "#298384", "#287183", "#326B85", "#3B6187",
         "#3F5589", "#434489", "#504389", "#5C4087", "#6A3C87", "#722D82", "#842E82", "#842D70"],
        ["#5F3225", "#5F3B25", "#5E4626", "#5E5227", "#5E5E2A", "#535E29", "#475D29", "#3B5D29",
         "#235D31", "#235D3D", "#235E48", "#235E53", "#235E5E", "#24535E", "#2A4F60", "#314A62",
         "#334162", "#363661", "#3D3661", "#463461", "#4D305F", "#53275D", "#5F285D", "#5F2751"],
    ]

    /// Hue names → palette column. Chosen by reading the row-1 swatch colours above; a name
    /// is a convenience, and every reply carries the resolved row, column and RGB so a caller
    /// can see what the name meant.
    static let namedColumns: [String: Int] = [
        "red": 1, "vermilion": 2, "orange": 3, "amber": 4, "yellow": 5, "chartreuse": 6,
        "lime": 7, "green": 9, "spring green": 10, "mint": 11, "teal": 12, "cyan": 13,
        "sky blue": 15, "azure": 16, "blue": 17, "indigo": 18, "violet": 19, "purple": 21,
        "plum": 22, "magenta": 23, "pink": 24,
    ]

    /// Shade words → visible row. A bare hue is the brightest row.
    static let namedRows: [String: Int] = [
        "": 1, "bright": 1, "light": 1,
        "medium": 2, "muted": 2,
        "dark": 3,
        "darker": 4, "darkest": 4, "deep": 4,
    ]

    enum Resolution: Equatable, Sendable {
        case resolved(TrackColorSwatch)
        case unknownName(String)
        case outOfRange(String)
    }

    /// `"red"`, `"dark blue"`, `"Darkest Green"` (case-insensitive, single spaces).
    static func resolve(name raw: String) -> Resolution {
        let words = raw.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return .unknownName(raw) }
        var candidates: [(row: Int, hue: String)] = []
        if let row = namedRows[words[0]], words.count > 1 {
            candidates.append((row, words.dropFirst().joined(separator: " ")))
        }
        candidates.append((1, words.joined(separator: " ")))
        for candidate in candidates {
            if let column = namedColumns[candidate.hue],
               let swatch = swatch(row: candidate.row, column: column) {
                return .resolved(swatch)
            }
        }
        return .unknownName(raw)
    }

    static func resolve(row: Int, column: Int) -> Resolution {
        guard let swatch = swatch(row: row, column: column) else {
            return .outOfRange("row \(row), column \(column)")
        }
        return .resolved(swatch)
    }

    static func resolve(storedIndex: Int) -> Resolution {
        guard let swatch = swatch(storedIndex: storedIndex) else {
            return .outOfRange("stored index \(storedIndex)")
        }
        return .resolved(swatch)
    }
}

/// Where to click for a swatch, derived from the palette's own AX children.
///
/// Only the rows whose children report a believable position (visible rows 2, 3 and 4) are
/// trusted. They must agree with each other — one x per column, a constant row pitch — before
/// any point is produced, so a palette whose layout changed is refused instead of clicked.
enum TrackColorPaletteGeometry {
    /// The palette group's children, as `AXPosition` values, in child order (index 0 is the
    /// reset button). Exactly 97 are expected.
    static let expectedChildCount = 1 + TrackColorPalette.rows * TrackColorPalette.columns

    enum Outcome: Equatable, Sendable {
        case point(CGPoint)
        case layoutUnrecognized(String)
    }

    /// AX child holding a visible position, for the rows whose positions are trusted.
    static func childIndex(row: Int, column: Int) -> Int? {
        switch row {
        case 2: return 72 + column
        case 3: return column
        case 4: return 24 + column
        default: return nil
        }
    }

    /// Swatch size observed in the screenshot (≈ 24.5 × 15.5 pt at a 28 × 20 pt pitch); the
    /// click lands in the middle of that, measured from the child's reported origin.
    static let clickInset = CGPoint(x: 12, y: 8)

    static func clickPoint(row: Int, column: Int, childPositions: [CGPoint]) -> Outcome {
        guard childPositions.count == expectedChildCount else {
            return .layoutUnrecognized("palette has \(childPositions.count) children, expected \(expectedChildCount)")
        }
        guard (1...TrackColorPalette.rows).contains(row),
              (1...TrackColorPalette.columns).contains(column) else {
            return .layoutUnrecognized("row \(row), column \(column) is outside the palette")
        }
        // Rows 2, 3 and 4 must each be one horizontal line, stacked at one pitch, with every
        // column at the same x in all three.
        var rowY: [Int: CGFloat] = [:]
        for trustedRow in 2...4 {
            let ys = (1...TrackColorPalette.columns).map { childPositions[childIndex(row: trustedRow, column: $0)!].y }
            guard let first = ys.first, ys.allSatisfy({ abs($0 - first) < 0.5 }) else {
                return .layoutUnrecognized("row \(trustedRow) is not one horizontal line")
            }
            rowY[trustedRow] = first
        }
        let pitch = rowY[3]! - rowY[2]!
        guard pitch > 5, abs((rowY[4]! - rowY[3]!) - pitch) < 0.5 else {
            return .layoutUnrecognized("rows 2-4 are not evenly stacked")
        }
        for column in 1...TrackColorPalette.columns {
            let xs = (2...4).map { childPositions[childIndex(row: $0, column: column)!].x }
            guard xs.allSatisfy({ abs($0 - xs[0]) < 0.5 }) else {
                return .layoutUnrecognized("column \(column) is not one vertical line")
            }
        }
        let anchorRow = row == 1 ? 2 : row
        let anchor = childPositions[childIndex(row: anchorRow, column: column)!]
        let y = row == 1 ? anchor.y - pitch : anchor.y
        return .point(CGPoint(x: anchor.x + clickInset.x, y: y + clickInset.y))
    }
}

/// Reads a track's colour from a saved `ProjectData`, the only place Logic exposes it.
///
/// Measured on 12.4: each track record carries `… 0x80 <colour> 0x00 0x00 <len: UInt16 LE>
/// <name UTF-8> …`. The format is undocumented, so the reader is strict: it accepts a name only
/// when exactly one occurrence has that prefix, and reports anything else rather than guessing.
enum TrackColorProjectFile {
    enum Read: Equatable, Sendable {
        case found(Int)
        case absent
        case ambiguous(Int)
    }

    static func colorIndex(trackName: String, projectData data: Data) -> Read {
        let name = Array(trackName.utf8)
        guard !name.isEmpty, name.count <= Int(UInt16.max) else { return .absent }
        let needle = [UInt8(name.count & 0xFF), UInt8(name.count >> 8)] + name
        let bytes = [UInt8](data)
        guard bytes.count >= needle.count + 4 else { return .absent }
        var found: [Int] = []
        var index = 4
        while index + needle.count <= bytes.count {
            if bytes[index] == needle[0],
               Array(bytes[index..<(index + needle.count)]) == needle,
               bytes[index - 4] == 0x80, bytes[index - 2] == 0, bytes[index - 1] == 0 {
                found.append(Int(bytes[index - 3]))
            }
            index += 1
        }
        switch found.count {
        case 0: return .absent
        case 1: return .found(found[0])
        default: return .ambiguous(found.count)
        }
    }

    /// `<bundle>/Alternatives/000/ProjectData`, under the same path rules as the metadata reader.
    static func projectDataURL(bundlePath: String) -> URL? {
        guard let validated = LogicProjectFileReader.validatePath(bundlePath) else { return nil }
        let url = validated.bundle
            .appendingPathComponent("Alternatives", isDirectory: true)
            .appendingPathComponent("000", isDirectory: true)
            .appendingPathComponent("ProjectData")
            .resolvingSymlinksInPath()
        let root = validated.bundle.path.hasSuffix("/") ? validated.bundle.path : validated.bundle.path + "/"
        return url.path.hasPrefix(root) ? url : nil
    }
}

/// Upgrades `set_color`'s State B to a verdict by saving the project and reading the track record.
///
/// The save goes through the ordinary `project.save` route, whose own State A means the package
/// on disk advanced. Only then is `ProjectData` read; the colour index found there for the
/// track's name is the readback. Any doubt along the way leaves the answer at State B and says why.
enum TrackColorProjectReadback {
    static func verify(
        channelResult: ChannelResult,
        expected: TrackColorSwatch,
        save: () async -> ChannelResult,
        readProjectData: (URL) -> Data? = { try? Data(contentsOf: $0, options: .mappedIfSafe) }
    ) async -> ChannelResult {
        guard var evidence = decodedJSONObject(channelResult.message),
              let trackName = evidence["track_name"] as? String else {
            return channelResult
        }
        for key in ["success", "verified", "state", "reason"] { evidence.removeValue(forKey: key) }
        evidence["readback"] = "project_file"

        let saved = await save()
        let saveJSON = decodedJSONObject(saved.message) ?? [:]
        guard saved.isSuccess, saveJSON["verified"] as? Bool == true,
              let documentPath = saveJSON["document_path"] as? String else {
            evidence["project_save"] = saveJSON.isEmpty ? saved.message : saveJSON
            evidence["readback_detail"] = "project_save_unverified"
            return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: evidence))
        }
        evidence["project_saved"] = documentPath
        guard let url = TrackColorProjectFile.projectDataURL(bundlePath: documentPath),
              let data = readProjectData(url) else {
            evidence["readback_detail"] = "project_data_unreadable"
            return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: evidence))
        }
        switch TrackColorProjectFile.colorIndex(trackName: trackName, projectData: data) {
        case .found(let observed):
            evidence["observed_stored_index"] = observed
            evidence["observed_color"] = TrackColorPalette.swatch(storedIndex: observed)
                .map(AccessibilityChannel.trackColorDescription) ?? NSNull()
            guard observed == expected.storedIndex else {
                return .success(HonestContract.encodeStateB(reason: .readbackMismatch, extras: evidence))
            }
            return .success(HonestContract.encodeStateA(extras: evidence))
        case .absent:
            evidence["readback_detail"] = "track_record_not_found"
            return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: evidence))
        case .ambiguous(let count):
            evidence["readback_detail"] = "track_record_ambiguous"
            evidence["track_record_matches"] = count
            return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: evidence))
        }
    }
}
