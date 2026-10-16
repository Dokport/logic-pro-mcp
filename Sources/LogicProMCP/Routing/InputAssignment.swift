import Foundation

/// Checked input-menu value domain. Neither a missing slot nor a display caption
/// establishes No Input, and No Input is never an OutputAssignment.noOutput.
enum InputAssignment: Equatable, Sendable {
    case bus(Int)
    case physical([Int])
    case noInput

    var busOutputAssignment: OutputAssignment? {
        guard case .bus(let number) = self else { return nil }
        return .bus(number)
    }

    /// Classification inside an input menu, not a control locator or readback
    /// proof. The owned reader must still establish agreeing root/leaf marks.
    static func classifiedMenuTitle(_ title: String) -> Self? {
        if let number = OutputAssignment.busNumber(ofMenuItemTitle: title, receiverArrow: "←") {
            return .bus(number)
        }
        if AXLocalePolicy.noInputMenuLabel.matches(title, mode: .exact) { return .noInput }
        let candidate = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in AXLocalePolicy.unassignedInputSlotLabel.labels {
            guard let range = candidate.range(of: prefix, options: [.anchored, .caseInsensitive]) else { continue }
            let tail = candidate[range.upperBound...].drop { $0.isWhitespace }
            let pieces = tail.split(separator: "-", omittingEmptySubsequences: false)
            guard pieces.count == 1 || pieces.count == 2 else { continue }
            let ports = pieces.compactMap { piece -> Int? in
                guard !piece.isEmpty, piece.count <= 6,
                      piece.allSatisfy({ ("0"..."9").contains($0) }),
                      let number = Int(piece), number > 0 else { return nil }
                return number
            }
            guard ports.count == pieces.count,
                  ports.count == 1 || ports[0] < ports[1] else { continue }
            return .physical(ports)
        }
        return nil
    }
}
