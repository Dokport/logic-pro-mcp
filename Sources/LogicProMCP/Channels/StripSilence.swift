import Foundation

/// The four numeric fields of Logic's Remove Silence dialog, in the order they appear top to
/// bottom (measured on Logic 12.4, `research/ax/remove-silence-dialog.txt`), with the ranges the
/// fields' own segment sliders publish as `AXMinValue` / `AXMaxValue`.
struct StripSilenceSettings: Equatable, Sendable {
    var thresholdDB: Double = -28
    var minimumSilenceSec: Double = 0.1
    var preAttackSec: Double = 0.006
    var postReleaseSec: Double = 0

    enum Field: Int, CaseIterable, Sendable {
        case threshold, minimumSilence, preAttack, postRelease

        var parameter: String {
            switch self {
            case .threshold: "threshold_db"
            case .minimumSilence: "min_silence_sec"
            case .preAttack: "pre_attack_sec"
            case .postRelease: "post_release_sec"
            }
        }

        var range: ClosedRange<Double> {
            switch self {
            case .threshold: -80...0
            case .minimumSilence, .preAttack, .postRelease: 0...60
            }
        }

        /// Digits after the decimal mark the field displays (`-28`, `0,1000`).
        var fractionDigits: Int { self == .threshold ? 0 : 4 }
    }

    func value(_ field: Field) -> Double {
        switch field {
        case .threshold: thresholdDB
        case .minimumSilence: minimumSilenceSec
        case .preAttack: preAttackSec
        case .postRelease: postReleaseSec
        }
    }

    /// The text to type into a field: rounded to its display precision, with the decimal mark
    /// the field itself shows (Logic follows the system number format; a Danish macOS uses `,`,
    /// and the field rejects `.` there). A leading minus is typed as the character `-`, which
    /// the caller must post as a Unicode character: on a Danish layout the US minus key is `+`.
    static func typed(_ value: Double, field: Field, decimalMark: Character) -> String {
        let digits = field.fractionDigits
        let text = digits == 0 ? String(Int(value.rounded())) : String(format: "%.\(digits)f", value)
        return decimalMark == "." ? text : text.replacingOccurrences(of: ".", with: String(decimalMark))
    }

    /// A field's displayed value as a number, either decimal mark.
    static func parse(_ display: String) -> Double? {
        Double(display.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "−", with: "-"))
    }

    /// Whether a field's display after typing is the requested value, at the field's precision.
    static func agrees(_ display: String, _ requested: Double, field: Field) -> Bool {
        guard let shown = parse(display) else { return false }
        let step = field.fractionDigits == 0 ? 0.5 : 0.00005
        return abs(shown - requested) <= step
    }

    /// The decimal mark a field's own display uses; `.` when it shows none.
    static func decimalMark(of display: String) -> Character {
        display.contains(",") ? "," : "."
    }

    /// The dialog's live preview, e.g. `16 Regions` (localized): its first integer.
    static func previewCount(_ text: String) -> Int? {
        let digits = text.drop(while: { !$0.isNumber }).prefix(while: \.isNumber)
        return digits.isEmpty ? nil : Int(digits)
    }

    enum Validation: Equatable, Sendable {
        case valid(StripSilenceSettings)
        case outOfRange(String)
    }

    static func validated(threshold: Double?, minimum: Double?, preAttack: Double?, postRelease: Double?) -> Validation {
        var settings = StripSilenceSettings()
        if let threshold { settings.thresholdDB = threshold }
        if let minimum { settings.minimumSilenceSec = minimum }
        if let preAttack { settings.preAttackSec = preAttack }
        if let postRelease { settings.postReleaseSec = postRelease }
        for field in Field.allCases where !field.range.contains(settings.value(field)) || !settings.value(field).isFinite {
            return .outOfRange("\(field.parameter) must lie in \(field.range.lowerBound)...\(field.range.upperBound)")
        }
        return .valid(settings)
    }
}
