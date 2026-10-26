import Foundation

/// The two kinds Logic's Create Track Stack sheet offers, in the order its radio buttons appear
/// (measured on Logic 12.4 en-US, `research/ax/create-track-stack-dialog.txt`).
enum TrackStackKind: String, CaseIterable, Sendable {
    case folder
    case summing

    /// Index of this kind's radio button among the sheet's radio buttons.
    var radioIndex: Int {
        switch self {
        case .folder: 0
        case .summing: 1
        }
    }
}

/// Pure decision core for `track.create_stack`: which rows to select, and whether the rail read
/// after the sheet's Create button is exactly the measured result.
///
/// Measured on Logic 12.4: creating a stack from selected tracks inserts ONE new stack main track
/// at the position of the first selected track, and the members follow it in their original
/// relative order; tracks that sat between non-contiguous members move to after the stack. So the
/// expected after-order is computable from the before-order and the members alone, and anything
/// else — a missing member, a second new track, a header that is not a stack — is not a success.
enum TrackStackVerifier {
    enum MemberResolution: Equatable, Sendable {
        case resolved([Int])
        case missing([String])
        case ambiguous([String])
        case duplicateMembers([String])
        case tooFew
    }

    /// Exact, unique names only. A name present twice in the project cannot say which row is meant.
    static func resolveMembers(_ members: [String], in names: [String]) -> MemberResolution {
        guard members.count >= 1 else { return .tooFew }
        let duplicates = Dictionary(grouping: members, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        guard duplicates.isEmpty else { return .duplicateMembers(duplicates) }
        var indices: [Int] = []
        var missing: [String] = []
        var ambiguous: [String] = []
        for member in members {
            let matches = names.indices.filter { names[$0].utf8.elementsEqual(member.utf8) }
            switch matches.count {
            case 0: missing.append(member)
            case 1: indices.append(matches[0])
            default: ambiguous.append(member)
            }
        }
        if !missing.isEmpty { return .missing(missing) }
        if !ambiguous.isEmpty { return .ambiguous(ambiguous) }
        return .resolved(indices.sorted())
    }

    /// The rail Logic should show after the stack is created, with `nil` where the new stack main
    /// track goes (its name is Logic's to choose).
    static func expectedAfter(before: [String], memberIndices: [Int]) -> [String?] {
        let members = Set(memberIndices)
        guard let first = memberIndices.min() else { return before }
        var after: [String?] = []
        for (index, name) in before.enumerated() {
            if index == first {
                after.append(nil)
                after.append(contentsOf: memberIndices.sorted().map { before[$0] })
            }
            if !members.contains(index) { after.append(name) }
        }
        return after
    }

    struct Row: Equatable, Sendable {
        let name: String
        let isStackHeader: Bool?
    }

    enum Verdict: Equatable, Sendable {
        /// The rail is exactly the expected one; the stack main track is at `headerIndex`.
        case verified(headerIndex: Int, headerName: String)
        /// Nothing changed at all.
        case unchanged
        /// Something changed, but not into the expected rail.
        case mismatch(String)
    }

    /// The rail with the new stack collapsed: Logic 12.4 creates a folder stack closed, so its
    /// members are not rows of the track list until it is opened (measured 2026-10-26).
    static func expectedCollapsedAfter(before: [String], memberIndices: [Int]) -> [String?] {
        let members = Set(memberIndices)
        guard let first = memberIndices.min() else { return before }
        var after: [String?] = []
        for (index, name) in before.enumerated() {
            if index == first { after.append(nil) }
            if !members.contains(index) { after.append(name) }
        }
        return after
    }

    static func verify(before: [String], memberIndices: [Int], after: [Row]) -> Verdict {
        if after.map(\.name) == before { return .unchanged }
        let open = expectedAfter(before: before, memberIndices: memberIndices)
        let collapsed = expectedCollapsedAfter(before: before, memberIndices: memberIndices)
        let expected = after.count == collapsed.count && memberIndices.count > 1 ? collapsed : open
        guard after.count == expected.count else {
            return .mismatch("expected \(expected.count) tracks after, read \(after.count)")
        }
        guard let headerIndex = expected.firstIndex(where: { $0 == nil }) else {
            return .mismatch("no stack position in the expected rail")
        }
        for (index, name) in expected.enumerated() where index != headerIndex {
            guard after[index].name.utf8.elementsEqual(name!.utf8) else {
                return .mismatch("row \(index) reads '\(after[index].name)', expected '\(name!)'")
            }
        }
        let header = after[headerIndex]
        guard header.isStackHeader == true else {
            return .mismatch("row \(headerIndex) ('\(header.name)') does not read as a stack main track")
        }
        return .verified(headerIndex: headerIndex, headerName: header.name)
    }
}

/// Pure core of `track.move_verified`: the rail after a track is moved to directly follow an
/// anchor above it (stack + flatten, measured on Logic 12.4: everything else keeps its order).
enum TrackMoveVerifier {
    static func expectedAfter(before: [String], moving: Int, after anchor: Int) -> [String] {
        guard before.indices.contains(moving), before.indices.contains(anchor), anchor < moving else { return before }
        var rail = before
        let track = rail.remove(at: moving)
        rail.insert(track, at: anchor + 1)
        return rail
    }

    /// The moves that turn `current` into `target` by placing each track after the previous one,
    /// top to bottom. Nil when the first track of `target` is not already first: nothing can be
    /// moved to the top this way. Both lists must hold the same names.
    static func plan(current: [String], target: [String]) -> [(name: String, after: String)]? {
        guard Set(current) == Set(target), current.count == target.count else { return nil }
        guard let first = target.first else { return [] }
        guard current.first == first else { return nil }
        var rail = current
        var moves: [(name: String, after: String)] = []
        for position in 1..<target.count {
            let name = target[position]
            guard rail[position] != name, let from = rail.firstIndex(of: name) else { continue }
            moves.append((name, target[position - 1]))
            rail = expectedAfter(before: rail, moving: from, after: position - 1)
        }
        return moves
    }
}
