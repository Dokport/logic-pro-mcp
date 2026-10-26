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

    static func verify(before: [String], memberIndices: [Int], after: [Row]) -> Verdict {
        if after.map(\.name) == before { return .unchanged }
        let expected = expectedAfter(before: before, memberIndices: memberIndices)
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
