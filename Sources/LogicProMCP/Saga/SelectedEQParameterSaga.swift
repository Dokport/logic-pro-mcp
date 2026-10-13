import Foundation
import MCP

/// A selected pair adapter for the existing Saga, not an automatic EQ mapper.
enum SelectedEQParameterSaga {
    static let pluginID = "logic.stock.effect.channel_eq"
    static func contains(_ plan: SagaPlan) -> Bool { plan.steps.contains { $0.operationID == .pluginsSetEQBandVerified } }

    static func canonicalParams(_ params: [String: Value], inverse: Bool = false) throws -> [String: Value] {
        guard Set(params.keys) == ["band", "parameter", "unit", "value", "expected_before", "recommendation"],
              params["band"]?.stringValue == "Peak 1",
              let parameter = params["parameter"]?.stringValue, ["frequency", "gain"].contains(parameter),
              let metadata = ChannelEQBandCatalog.parameter(bandName: "Peak 1", parameterName: parameter),
              let unit = params["unit"]?.stringValue,
              unit == metadata.displayUnit || (inverse && unit == metadata.rawUnit),
              let value = CompressorParameterSaga.number(params["value"] ?? .null),
              AccessibilityChannel.verifiedEQParameterPreflight(band: "Peak 1", parameter: parameter, value: value, unit: unit),
              let before = CompressorParameterSaga.number(params["expected_before"] ?? .null),
              metadata.range.contains(before),
              !(inverse && unit == metadata.rawUnit) || metadata.range.contains(value),
              parameter != "frequency" || unit == metadata.rawUnit || value > 0,
              let advice = params["recommendation"]?.objectValue,
              Set(advice.keys) == ["artifact_fingerprint", "center_hz", "gain_db", "q"],
              let fingerprint = advice["artifact_fingerprint"]?.stringValue,
              fingerprint.hasPrefix("sha256:"), fingerprint.utf8.count == 71,
              fingerprint.dropFirst(7).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let frequency = CompressorParameterSaga.number(advice["center_hz"] ?? .null), frequency > 0,
              let gain = CompressorParameterSaga.number(advice["gain_db"] ?? .null), gain <= 0,
              let q = CompressorParameterSaga.number(advice["q"] ?? .null), q > 0 else {
            throw SagaWireError.invalid("selected EQ requires Peak 1 Frequency/Hz and Gain/dB, actual raw expected_before, and original advisory content provenance")
        }
        var result = params
        result["value"] = .double(value); result["expected_before"] = .double(before)
        result["recommendation"] = .object(["artifact_fingerprint": .string(fingerprint),
            "center_hz": .double(frequency), "gain_db": .double(gain), "q": .double(q)])
        return result
    }

    static func validate(_ plan: SagaPlan) throws {
        guard contains(plan) else { return }
        guard plan.steps.count == 2,
              Set(plan.steps.compactMap { $0.params["parameter"]?.stringValue }) == ["frequency", "gain"],
              let first = plan.steps.first, let reference = first.targetRef, reference.rawValue.hasPrefix("ins_"),
              plan.steps.allSatisfy({ $0.operationID == .pluginsSetEQBandVerified && $0.targetRef == reference
                  && $0.params["recommendation"] == first.params["recommendation"]
                  && $0.expectedInverse.operationID == .pluginsSetEQBandVerified
                  && $0.expectedInverse.valueParameter == "value" }) else {
            throw SagaWireError.invalid("selected EQ requires exactly one Frequency and Gain pair on the same occupied insert and recommendation")
        }
        for step in plan.steps { _ = try canonicalParams(step.params) }
    }

    static func beforeMatches(_ state: ObservedState?, _ step: SagaStep) -> Bool {
        SagaValueComparator.ownershipEvidence(observed: state?.value, desired: step.params["expected_before"]).equal
    }

    static func binding(_ step: SagaStep, registry: TargetRegistry) async -> (TargetBinding, TargetDescriptor)? {
        guard FeatureFlags.adr002TargetRef, let reference = step.targetRef,
              let binding = await registry.resolve(reference), binding.kind == .pluginInsert,
              binding.pluginInsertIndex != nil, TargetRefResolver.pluginInsertIdentity(from: binding) == pluginID,
              let project = await registry.currentProjectIdentity, project.projectFilePath != nil else { return nil }
        return (binding, project)
    }

    static func read(_ step: SagaStep, router: ChannelRouter, cache: StateCache,
                     registry: TargetRegistry, now: Date) async -> ObservedState? {
        guard let (binding, project) = await binding(step, registry: registry),
              let parameter = step.params["parameter"]?.stringValue,
              let metadata = ChannelEQBandCatalog.parameter(bandName: "Peak 1", parameterName: parameter) else { return nil }
        let response = await CompressorParameterSaga.bounded(command: "get_channel_eq_state_verified") {
            await PluginsDispatcher.handle(command: "get_channel_eq_state_verified",
                params: ["target_ref": .string(binding.reference.rawValue)],
                router: router, cache: cache, targetRegistry: registry)
        }
        guard let body = decodedJSONObject(sharedText(response)), body["state"] as? String == "A",
              let complete = body["complete"], JSONInspector.isBoolean(complete), complete as? Bool == true,
              let write = body["write_attempted"], JSONInspector.isBoolean(write), write as? Bool == false,
              body["observation_scope"] as? String == "current_insert_eight_band_raw_and_host_display",
              body["editor_cleanup_unobserved"] as? Bool != true, body["plugin_view_left_changed"] as? Bool != true,
              let identity = body["target_identity"] as? [String: Any],
              identity["plugin_id"] as? String == pluginID,
              identity["track_index"].flatMap(JSONInspector.number) == Double(binding.descriptor.trackIndex),
              identity["insert"].flatMap(JSONInspector.number) == binding.pluginInsertIndex.map(Double.init),
              let bands = body["bands"] as? [[String: Any]],
              bands.filter({ $0["name"] as? String == "Peak 1" }).count == 1,
              let field = bands.first(where: { $0["name"] as? String == "Peak 1" })?[parameter] as? [String: Any],
              field["read_status"] as? String == "read", field["raw_unit"] as? String == metadata.rawUnit,
              field["display_read_status"] as? String == "read",
              let raw = field["observed_raw"].flatMap(JSONInspector.number), raw.isFinite, metadata.range.contains(raw),
              let display = field["observed_display"] as? String,
              let parsed = SliderIncrementWalk.leadingNumber(in: display), parsed.number.isFinite,
              parsed.suffix.trimmingCharacters(in: .whitespacesAndNewlines) == metadata.displayUnit,
              await registry.resolve(binding.reference) != nil,
              await registry.currentProjectIdentity == project else { return nil }
        return ObservedState(read: SagaReadEvidence(readSource: .axPluginParameter, provenance: .liveIndependent,
            trackIndex: binding.descriptor.trackIndex, field: metadata.id, observed: .double(raw),
            sampledAt: ISO8601DateFormatter().string(from: now), hostDisplay: display))
    }

    static func comparison(_ state: ObservedState?, desired: Value?, step: SagaStep) -> SagaComparisonEvidence {
        let unit = step.params["unit"]?.stringValue
        let observed: Value?
        if unit == "raw_ax_value" { observed = state?.value }
        else if let display = state?.read?.hostDisplay,
                let reading = SliderIncrementWalk.leadingNumber(in: display), reading.number.isFinite,
                reading.suffix.trimmingCharacters(in: .whitespacesAndNewlines) == unit {
            observed = .double(reading.number)
        } else { observed = nil }
        let comparison = SagaValueComparator.ownershipEvidence(observed: observed, desired: desired)
        return SagaComparisonEvidence(comparator: comparison.comparator, epsilon: comparison.epsilon,
            desired: desired, observed: observed, delta: comparison.delta, equal: comparison.equal, unit: unit)
    }

    private static func sharedText(_ result: CallTool.Result) -> String {
        guard case .text(let text, _, _) = result.content.first else { return "" }
        return text
    }
}
