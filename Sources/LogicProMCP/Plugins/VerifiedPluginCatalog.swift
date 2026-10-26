import Foundation

/// Identity + capability resolution for the verified-plugin surface
/// (`logic_plugins.*`). Kept separate from the large `StockPluginCatalog`
/// discovery layer so the verified path has a single, narrowly-scoped place to
/// answer three questions per requirements §5.2 / R5 / R6:
///
///   1. canonical plugin identity — map a caller alias (display name `"Gain"`,
///      bare catalog suffix `gain`, or a full `logic.stock.effect.*` id) to the
///      canonical catalog id, or refuse (`unknown_plugin_identity`, AC11).
///   2. canonical parameter key — map a parameter alias (`gain` → `gain_db`) to
///      the verified public key (R5: "구현 전에 `gain -> gain_db` alias를 명시").
///   3. write/readback capability — does the resolved plugin/param actually
///      have a write method AND a display-readback parser? (R6 step 5 preflight;
///      Compressor `threshold` uses direct `ax_slider_axvalue`; named Channel
///      EQ controls use the separately measured increment-walk metadata. Gain
///      has read-only metadata and no qualified parameter writer.)
///
/// This module is deterministic and contains NO live AX interaction.
enum VerifiedPluginCatalog {
    typealias EntryLookup = @Sendable (_ pluginID: String) -> StockPluginCatalogEntry?
    typealias ParamAliasLookup = @Sendable (_ pluginID: String, _ alias: String) -> String?

    static let productionEntryLookup: EntryLookup = { StockPluginCatalog.entry(id: $0) }


    /// Display-name / alias → canonical `logic.stock.*` id table.
    ///
    /// MVP scope (R5): the three allowlisted stock plugins. Compressor
    /// `threshold` and named Channel EQ parameters have distinct catalog write
    /// methods; Gain parameter access is read-only. Display
    /// names are accepted as user-facing aliases but never become the identity
    /// themselves (requirements §5.2 "display name은 identity가 아니라 alias").
    private static let pluginAliases: [String: String] = [
        "gain": "logic.stock.effect.gain",
        "logic.stock.effect.gain": "logic.stock.effect.gain",
        "channel eq": "logic.stock.effect.channel_eq",
        "channeleq": "logic.stock.effect.channel_eq",
        "logic.stock.effect.channel_eq": "logic.stock.effect.channel_eq",
        "compressor": "logic.stock.effect.compressor",
        "logic.stock.effect.compressor": "logic.stock.effect.compressor",
        "noise gate": "logic.stock.effect.noise_gate",
        "noisegate": "logic.stock.effect.noise_gate",
        "logic.stock.effect.noise_gate": "logic.stock.effect.noise_gate",
        "sample delay": "logic.stock.effect.sample_delay",
        "sampledelay": "logic.stock.effect.sample_delay",
        "smpledly": "logic.stock.effect.sample_delay",
        "logic.stock.effect.sample_delay": "logic.stock.effect.sample_delay",
        // Mix-prep FX returns: insertion only (no parameter is read or written through them).
        "chromaverb": "logic.stock.effect.chromaverb",
        "logic.stock.effect.chromaverb": "logic.stock.effect.chromaverb",
        "stereo delay": "logic.stock.effect.stereo_delay",
        "stereodelay": "logic.stock.effect.stereo_delay",
        "logic.stock.effect.stereo_delay": "logic.stock.effect.stereo_delay",
    ]

    /// Per-plugin parameter-key alias table: caller key → canonical catalog
    /// parameter id. The public verified API uses `gain_db` (unit-explicit)
    /// while the catalog entry's parameter id is still `gain` (R5); both resolve
    /// to the catalog id so the capability lookup can find the parameter.
    private static let paramAliases: [String: [String: String]] = [
        "logic.stock.effect.noise_gate": [
            "threshold": "threshold",
            "hysteresis": "hysteresis",
            "reduction": "reduction",
            "attack": "attack",
            "hold": "hold",
            "release": "release",
            "high_cutoff": "high_cutoff",
            "low_cutoff": "low_cutoff",
            "lookahead": "lookahead",
            "sidechain_filter_mode": "sidechain_filter_mode",
        ],
        "logic.stock.effect.sample_delay": [
            "delay": "delay",
            "left_delay": "left_delay",
            "right_delay": "right_delay",
        ],
        "logic.stock.effect.gain": [
            "gain": "gain",
            "gain_db": "gain",
            "phase_invert": "phase_invert",
            "phase_invert_left": "phase_invert_left",
            "phase_invert_right": "phase_invert_right",
            "swap_lr": "swap_lr",
            "mono": "mono",
        ],
        // Compressor `threshold` is the first verified-writable parameter (T5,
        // T0 spike). The public key and the catalog parameter id are both
        // `threshold` (normalized %, NOT dB) — see `StockPluginCatalog`.
        "logic.stock.effect.compressor": [
            "threshold": "threshold",
            "limiter_on": "limiter_on",
            "limiter on": "limiter_on",
            "auto_release": "auto_release",
            "auto release": "auto_release",
            // Negative Controls-view measurements have canonical aliases too,
            // so callers get their established refusal rather than an
            // addressability guess or a generic unknown-param response.
            "gain": "gain",
            "ratio": "ratio",
            "circuit_type": "circuit_type",
            "circuit type": "circuit_type",
        ],
    ]

    /// Resolve a caller-supplied plugin alias to its canonical catalog id, or
    /// nil when no explicit alias mapping exists (→ State C
    /// `unknown_plugin_identity`, AC11). Matching is case- and
    /// whitespace-insensitive; a full canonical id is accepted only if it is a
    /// known catalog id (so an unbacked `com.apple.logic.gain` still fails).
    static func canonicalPluginID(from alias: String) -> String? {
        let normalized = alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return pluginAliases[normalized] ?? catalogEffectAliases[normalized]
    }

    /// Every stock audio effect in the catalog (utilities and meters included) also resolves by its own display name and id. Resolving
    /// is not permission: insertion stays gated by `insertableAllowlist`.
    private static let catalogEffectAliases: [String: String] = {
        var table: [String: String] = [:]
        for entry in StockPluginCatalog.productionSnapshot.entries where entry.type != .instrument && entry.type != .midiEffect {
            table[entry.displayName.lowercased()] = entry.id
            table[entry.id] = entry.id
        }
        return table
    }()

    /// Resolve a caller-supplied parameter alias to the catalog parameter id for
    /// a (already-canonical) plugin id, or nil when the plugin declares no such
    /// parameter alias.
    static func canonicalParamKey(pluginID: String, alias: String) -> String? {
        let normalized = alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return paramAliases[pluginID]?[normalized]
    }

    static func canonicalParamKey(
        pluginID: String,
        alias: String,
        paramAliasLookup: ParamAliasLookup
    ) -> String? {
        paramAliasLookup(pluginID, alias)
    }

    /// Map a slot's observed display name (from AX readback) to a canonical
    /// catalog id for `get_inventory.plugins[].plugin_id`, or nil when the name
    /// does not match an allowlisted stock plugin. Reuses the same alias table
    /// as caller-input resolution so the two stay consistent.
    static func pluginID(forObservedName name: String) -> String? {
        canonicalPluginID(from: name)
            ?? measuredSlotLabels[name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }

    /// The names Logic 12.4 shows in an occupied insert slot where they differ from the plug-in's
    /// display name (abbreviated, or cut at 10 characters). Measured 2026-10-26 by inserting every
    /// stock effect on the test project and reading the slot back
    /// (`research/plugin-census-12.4.jsonl`). A Logic update can change them; an unknown label
    /// reads as no identity, so readback then fails closed.
    static let measuredSlotLabels: [String: String] = [
        "linear eq": "logic.stock.effect.linear_phase_eq",
        "single eq": "logic.stock.effect.single_band_eq",
        "cnsl eq": "logic.stock.effect.vintage_console_eq",
        "graph eq": "logic.stock.effect.vintage_graphic_eq",
        "tube eq": "logic.stock.effect.vintage_tube_eq",
        "adlimit": "logic.stock.effect.adaptive_limiter",
        "multipr": "logic.stock.effect.multipressor",
        "qrs": "logic.stock.effect.quantec_room_simulator",
        "space d": "logic.stock.effect.space_designer",
        "delay d": "logic.stock.effect.delay_designer",
        "smpledly": "logic.stock.effect.sample_delay",
        "st-delay": "logic.stock.effect.stereo_delay",
        "mcrphas": "logic.stock.effect.microphaser",
        "moddel": "logic.stock.effect.modulation_delay",
        "ringshift": "logic.stock.effect.ringshifter",
        "rotor": "logic.stock.effect.rotor_cabinet",
        "scanvib": "logic.stock.effect.scanner_vibrato",
        "clipdist": "logic.stock.effect.clip_distortion",
        "dist ii": "logic.stock.effect.distortion_ii",
        "phasedist": "logic.stock.effect.phase_distortion",
        "evoc fb": "logic.stock.effect.evoc_20_filterbank",
        "specgate": "logic.stock.effect.spectral_gate",
        "dirmix": "logic.stock.effect.direction_mixer",
        "spread": "logic.stock.effect.stereo_spread",
        "pitchcor": "logic.stock.effect.pitch_correction",
        "pshft": "logic.stock.effect.pitch_shifter",
        "vocaltrf": "logic.stock.effect.vocal_transformer",
        "testosc": "logic.stock.effect.test_oscillator",
        "correlatio": "logic.stock.effect.correlation_meter",
        "level mtr": "logic.stock.effect.level_meter",
        "loudness": "logic.stock.effect.loudness_meter",
        "beat break": "logic.stock.effect.beat_breaker",
        "amp": "logic.stock.effect.amp_designer",
        "bass amp": "logic.stock.effect.bass_amp_designer",
    ]

    /// Stock effects whose insertion and slot readback were measured on Logic 12.4 (same census).
    /// `Distortion` is not here: its name is also a category in the plug-in menu, and the exact
    /// leaf was not found.
    static let measuredInsertable: Set<String> = [
        "logic.stock.effect.adaptive_limiter",
        "logic.stock.effect.amp_designer",
        "logic.stock.effect.autofilter",
        "logic.stock.effect.bass_amp_designer",
        "logic.stock.effect.beat_breaker",
        "logic.stock.effect.bitcrusher",
        "logic.stock.effect.channel_eq",
        "logic.stock.effect.chorus",
        "logic.stock.effect.chromaglow",
        "logic.stock.effect.chromaverb",
        "logic.stock.effect.clip_distortion",
        "logic.stock.effect.compressor",
        "logic.stock.effect.correlation_meter",
        "logic.stock.effect.deesser_2",
        "logic.stock.effect.delay_designer",
        "logic.stock.effect.direction_mixer",
        "logic.stock.effect.distortion_ii",
        "logic.stock.effect.echo",
        "logic.stock.effect.ensemble",
        "logic.stock.effect.enveloper",
        "logic.stock.effect.evoc_20_filterbank",
        "logic.stock.effect.exciter",
        "logic.stock.effect.expander",
        "logic.stock.effect.flanger",
        "logic.stock.effect.fuzz_wah",
        "logic.stock.effect.gain",
        "logic.stock.effect.io",
        "logic.stock.effect.level_meter",
        "logic.stock.effect.limiter",
        "logic.stock.effect.linear_phase_eq",
        "logic.stock.effect.loudness_meter",
        "logic.stock.effect.match_eq",
        "logic.stock.effect.microphaser",
        "logic.stock.effect.modulation_delay",
        "logic.stock.effect.multimeter",
        "logic.stock.effect.multipressor",
        "logic.stock.effect.noise_gate",
        "logic.stock.effect.overdrive",
        "logic.stock.effect.pedalboard",
        "logic.stock.effect.phase_distortion",
        "logic.stock.effect.phaser",
        "logic.stock.effect.phat_fx",
        "logic.stock.effect.pitch_correction",
        "logic.stock.effect.pitch_shifter",
        "logic.stock.effect.quantec_room_simulator",
        "logic.stock.effect.remix_fx",
        "logic.stock.effect.ringshifter",
        "logic.stock.effect.rotor_cabinet",
        "logic.stock.effect.sample_delay",
        "logic.stock.effect.scanner_vibrato",
        "logic.stock.effect.silververb",
        "logic.stock.effect.single_band_eq",
        "logic.stock.effect.space_designer",
        "logic.stock.effect.spectral_gate",
        "logic.stock.effect.spreader",
        "logic.stock.effect.step_fx",
        "logic.stock.effect.stereo_delay",
        "logic.stock.effect.stereo_spread",
        "logic.stock.effect.subbass",
        "logic.stock.effect.tape_delay",
        "logic.stock.effect.test_oscillator",
        "logic.stock.effect.tremolo",
        "logic.stock.effect.tuner",
        "logic.stock.effect.vintage_console_eq",
        "logic.stock.effect.vintage_graphic_eq",
        "logic.stock.effect.vintage_tube_eq",
        "logic.stock.effect.vocal_transformer",
    ]

    /// Result of the R6 step-5 capability preflight.
    enum ParamCapability: Equatable {
        /// Plugin or parameter is not in the verified allowlist at all.
        case unknownParameter
        /// Parameter exists but lacks a write method and/or a display-readback
        /// parser — writing it could never be confirmed, so it is State C
        /// `unsupported_param_readback` BEFORE any write (R6, AC10).
        case unsupported
        /// Parameter has both a write method and a readback parser. Eligible for
        /// a verified State A write. The entry's provenance still determines
        /// what live evidence has actually been established; Gain does not.)
        case writeReadback
    }

    /// Look up whether a (canonical) plugin/param can be written AND read back.
    /// Drives R6 step 5: only `.writeReadback` may proceed past preflight; every
    /// other result is a write-blocking State C.
    ///
    /// `unit` is validated against the catalog parameter's declared unit (R2/R8:
    /// "param map이 선언하지 않은 unit은 State C `invalid_params`"); a mismatch is
    /// reported by the caller as `invalid_params`, so this returns the capability
    /// independent of unit and exposes the expected unit separately.
    static func paramCapability(
        pluginID: String,
        paramKey: String,
        entryLookup: EntryLookup = productionEntryLookup
    ) -> ParamCapability {
        guard let entry = entryLookup(pluginID),
              let param = entry.parameters.first(where: { $0.id == paramKey }) else {
            return .unknownParameter
        }
        let hasWrite = !(param.writeMethod?.isEmpty ?? true)
        let hasReadback = !(param.readbackMethod?.isEmpty ?? true)
        return (hasWrite && hasReadback) ? .writeReadback : .unsupported
    }

    /// The canonical unit a (canonical) plugin parameter declares, or nil when
    /// the parameter is unknown. Used to enforce unit honesty (R8) before a
    /// write: a caller `unit` that disagrees is `invalid_params`.
    static func paramUnit(
        pluginID: String,
        paramKey: String,
        entryLookup: EntryLookup = productionEntryLookup
    ) -> String? {
        entryLookup(pluginID)?
            .parameters.first(where: { $0.id == paramKey })?.unit
    }

    /// The valid display-value range a (canonical) plugin parameter declares, or
    /// nil when unknown. Used for range validation (R6 step 1).
    static func paramRange(
        pluginID: String,
        paramKey: String,
        entryLookup: EntryLookup = productionEntryLookup
    ) -> StockPluginValueRange? {
        entryLookup(pluginID)?
            .parameters.first(where: { $0.id == paramKey })?.valueRange
    }

    /// The live `AXDescription` string that identifies a (canonical) plugin
    /// parameter's `AXSlider` inside the plugin window (T0 evidence), or nil when
    /// the parameter has no stable description matcher. The verified write path
    /// (R6 step 9) matches a window slider by this description; a parameter
    /// without one cannot reach a verified write (it stays `.unsupported`).
    static func paramAXDescription(
        pluginID: String,
        paramKey: String,
        entryLookup: EntryLookup = productionEntryLookup
    ) -> String? {
        entryLookup(pluginID)?
            .parameters.first(where: { $0.id == paramKey })?.axDescription
    }

    /// A Controls-view parameter's row label. This is distinct from
    /// `paramAXDescription`: Controls-view names live in AXRows while the
    /// controls themselves are unnamed.
    static func controlsViewRowLabel(
        pluginID: String,
        paramKey: String,
        entryLookup: EntryLookup = productionEntryLookup
    ) -> String? {
        entryLookup(pluginID)?
            .parameters.first(where: { $0.id == paramKey })?.controlsViewRowLabel
    }

    /// The parameter role observed on its Controls-view row. A value here is
    /// not an actuation claim; consult the paired actuation state before any
    /// Controls-view write is considered.
    static func controlsViewControlRole(
        pluginID: String,
        paramKey: String,
        entryLookup: EntryLookup = productionEntryLookup
    ) -> String? {
        entryLookup(pluginID)?
            .parameters.first(where: { $0.id == paramKey })?.controlsViewControlRole
    }

    /// An editor-view control used only to acquire a known plug-in window
    /// before switching it to Controls view. It must never be mistaken for the
    /// requested parameter's locator.
    static func editorWindowAnchorAXDescription(
        pluginID: String,
        paramKey: String,
        entryLookup: EntryLookup = productionEntryLookup
    ) -> String? {
        entryLookup(pluginID)?
            .parameters.first(where: { $0.id == paramKey })?.editorWindowAnchorAXDescription
    }

    /// The verified write/readback tolerance (in the parameter's own unit) for a
    /// (canonical) plugin parameter, or nil when unknown / not verified-writable.
    /// R6 step 13: |observed - requested| <= tolerance ⇒ State A.
    static func paramTolerance(
        pluginID: String,
        paramKey: String,
        entryLookup: EntryLookup = productionEntryLookup
    ) -> Double? {
        entryLookup(pluginID)?
            .parameters.first(where: { $0.id == paramKey })?.tolerance
    }
}
