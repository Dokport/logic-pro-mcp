import ApplicationServices
import Foundation

/// Read-only observation after the caller has bound the occupied insert and
/// editor. Row census is shared with the writer; its actuation rules are not.
enum ControlsViewParameterReader {
    enum Kind: Equatable {
        case numericDisplay
        case radioPair(off: String, on: String)
    }

    enum Outcome {
        case read(raw: Any, display: String)
        case unavailable(String)
    }

    static func kind(for metadata: StockPluginParameterMetadata) -> Kind? {
        guard let label = metadata.controlsViewRowLabel, !label.isEmpty else { return nil }
        if metadata.readbackMethod == "ax_controls_view_slider_display",
           metadata.controlsViewControlRole == "AXSlider" { return .numericDisplay }
        if metadata.readbackMethod == "ax_controls_view_radio_pair",
           metadata.controlsViewControlRole == "AXRadioButton",
           let off = metadata.readbackOffTitle, !off.isEmpty,
           let on = metadata.readbackOnTitle, !on.isEmpty, off != on {
            return .radioPair(off: off, on: on)
        }
        return nil
    }

    private enum Value: Equatable {
        case number(Double)
        case boolean(Bool)

        var raw: Any {
            switch self {
            case let .number(value): return value
            case let .boolean(value): return value
            }
        }
    }

    private struct Snapshot {
        let value: Value
        let display: String
        let controls: [AXUIElement]
    }
    private struct ReadFailure: Error { let status: String }

    static func observe(kind: Kind, label: String, in window: AXUIElement,
                        runtime: AXHelpers.Runtime) -> Outcome {
        do {
            let first = try sample(kind: kind, label: label, in: window, runtime: runtime)
            let last = try sample(kind: kind, label: label, in: window, runtime: runtime)
            guard first.value == last.value, first.display == last.display,
                  first.controls.count == last.controls.count,
                  zip(first.controls, last.controls).allSatisfy({ CFEqual($0.0, $0.1) }) else {
                return .unavailable("unstable")
            }
            return .read(raw: last.value.raw, display: last.display)
        } catch let failure as ReadFailure {
            return .unavailable(failure.status)
        } catch {
            return .unavailable("unreadable")
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String,
                                  runtime: AXHelpers.Runtime) throws -> AnyObject? {
        switch AXHelpers.getAttributeResult(element, name, runtime: runtime) as Result<AnyObject?, AXHelpers.AXStatusError> {
        case let .success(value): return value
        case let .failure(error) where error.isDefinitiveAbsence: return nil
        case .failure: throw ReadFailure(status: "unreadable")
        }
    }

    private static func text(_ element: AXUIElement, _ name: String,
                             runtime: AXHelpers.Runtime) throws -> String? {
        guard let value = try attribute(element, name, runtime: runtime) else { return nil }
        guard let text = value as? String else { throw ReadFailure(status: "malformed") }
        return text
    }

    private static func number(_ element: AXUIElement, runtime: AXHelpers.Runtime) throws -> Double {
        let raw = try attribute(element, kAXValueAttribute as String, runtime: runtime)
        let value: Double?
        if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            value = number.doubleValue
        } else if let text = raw as? String { value = Double(text) }
        else { value = nil }
        guard let value, value.isFinite else { throw ReadFailure(status: raw == nil ? "absent" : "malformed") }
        return value
    }

    private static func sample(kind: Kind, label: String, in window: AXUIElement,
                               runtime: AXHelpers.Runtime) throws -> Snapshot {
        let controls: [AXUIElement]
        switch ControlsViewBooleanParameterWriter.rowControls(label: label, in: window, runtime: runtime) {
        case let .success(found): controls = found
        case let .failure(error): throw ReadFailure(status: error.rawValue)
        }
        let roles = try controls.map { try text($0, kAXRoleAttribute as String, runtime: runtime) }
        switch kind {
        case .numericDisplay:
            // Exact measured Gain shape: a display-bearing slider, a raw-only
            // slider and its value indicator. Every raw read must corroborate;
            // an unreadable sibling cannot be filtered away to fake uniqueness.
            guard controls.count == 3, roles.filter({ $0 == "AXSlider" }).count == 2,
                  roles.filter({ $0 == "AXValueIndicator" }).count == 1 else {
                throw ReadFailure(status: "control_shape_unconfirmed")
            }
            var values: [Double] = []
            var displays: [String] = []
            for (control, role) in zip(controls, roles) {
                values.append(try number(control, runtime: runtime))
                if let display = try text(control, kAXValueDescriptionAttribute as String, runtime: runtime),
                   !display.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    guard role == "AXSlider" else { throw ReadFailure(status: "ambiguous_display") }
                    displays.append(display)
                }
            }
            guard displays.count == 1, let display = displays.first else {
                throw ReadFailure(status: displays.isEmpty ? "display_absent" : "ambiguous_display")
            }
            guard let value = values.first, values.allSatisfy({ $0 == value }) else {
                throw ReadFailure(status: "inconsistent_raw_values")
            }
            return Snapshot(value: .number(value), display: display, controls: controls)
        case let .radioPair(off, on):
            guard controls.count == 2, roles.allSatisfy({ $0 == "AXRadioButton" }) else {
                throw ReadFailure(status: "control_shape_unconfirmed")
            }
            let titles = try controls.map { try text($0, kAXTitleAttribute as String, runtime: runtime) }
            guard titles.filter({ $0 == off }).count == 1,
                  titles.filter({ $0 == on }).count == 1 else { throw ReadFailure(status: "radio_titles_unconfirmed") }
            var states: [Bool] = []
            for control in controls {
                switch AXValueExtractors.extractButtonStateResult(control, runtime: runtime) {
                case let .success(.some(value)): states.append(value)
                case .success(.none): throw ReadFailure(status: "radio_value_unknown")
                case .failure: throw ReadFailure(status: "unreadable")
                }
            }
            guard states.filter({ $0 }).count == 1,
                  let onIndex = titles.firstIndex(where: { $0 == on }) else {
                throw ReadFailure(status: "radio_pair_not_one_hot")
            }
            let value = states[onIndex]
            return Snapshot(value: .boolean(value), display: value ? on : off, controls: controls)
        }
    }
}
