import ApplicationServices
import Foundation

/// `mixer.create_send`: one new send from a named strip to Bus N, optionally letting Logic create
/// the receiving aux, read back from the strip's own send census and the Mixer's strip census.
///
/// Measured on Logic 12.4 (2026-10-26): a strip shows an empty `send button`; pressing
/// it opens a popup whose Bus submenu lists `Bus n`; choosing an unused bus makes Logic add one
/// aux strip whose input is that bus, and the strip then shows an assigned send group described
/// `Bus n` beside a new empty slot. The level of the new send starts at -∞; set it afterwards with
/// `set_send_level_verified`.
extension AccessibilityChannel {
    static func defaultCreateSend(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ChannelResult {
        var evidence: [String: Any] = ["operation": "mixer.create_send", "write_attempted": false]
        func refuse(_ error: HonestContract.FailureError, _ reason: String, _ hint: String) -> ChannelResult {
            evidence["reason"] = reason
            return .error(HonestContract.encodeStateC(error: error, hint: hint, extras: evidence))
        }
        guard let stripName = params["strip"], !stripName.isEmpty,
              let bus = params["bus"].flatMap(Int.init), (1...256).contains(bus) else {
            return refuse(.invalidParams, "params_invalid", "create_send requires 'strip' (a Mixer strip name) and 'bus' (1-256)")
        }
        let createReceiver = params["create_receiver"] == "true"
        evidence["strip"] = stripName
        evidence["bus"] = bus

        guard let mixer = AXLogicProElements.getMixerArea(runtime: runtime),
              let census = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: mixer, runtime: runtime.ax)?.strips else {
            return refuse(.elementNotFound, "mixer_not_visible", "The Mixer is not shown or its strips did not read; nothing was pressed.")
        }
        let names = census.map { AXHelpers.getDescription($0, runtime: runtime.ax) ?? "" }
        let matches = names.indices.filter { names[$0].utf8.elementsEqual(stripName.utf8) }
        guard matches.count == 1 else {
            return refuse(matches.isEmpty ? .elementNotFound : .ambiguousTargetName,
                          matches.isEmpty ? "strip_not_found" : "strip_ambiguous",
                          matches.isEmpty ? "No Mixer strip is named '\(stripName)'." : "More than one Mixer strip is named '\(stripName)'.")
        }
        let strip = census[matches[0]]

        // Receivers of the bus among the OTHER strips; an unread input could be one.
        var receivers: [Int] = []
        var unreadInputs: [Int] = []
        for (ordinal, other) in census.enumerated() where ordinal != matches[0] {
            let reading = AXLogicProElements.inputSlotReading(in: other, runtime: runtime.ax)
            if reading == .unreadable { unreadInputs.append(ordinal); continue }
            if case .source(let label) = reading,
               RoutingGraphPublication.classifyOutputLabel(label) == (.bus, bus) { receivers.append(ordinal) }
        }
        evidence["bus_receivers"] = receivers
        if receivers.isEmpty {
            guard createReceiver else {
                return refuse(.busHasNoReceiver, "bus_has_no_receiver",
                    "No other strip reads Bus \(bus) as its input; pass create_receiver:true to let Logic create the aux. Nothing was pressed.")
            }
            guard unreadInputs.isEmpty else {
                evidence["strips_with_input_not_read"] = unreadInputs
                return refuse(.routingDependencyUnknown, "inputs_unreadable",
                    "Some strips' inputs did not read, so Bus \(bus) may already have a receiver; nothing was pressed.")
            }
        }

        // The strip's sends before, and its empty slots. Measured: once any strip has a send, Logic
        // gives every strip another send row, so a strip can show several empty slots; an empty
        // slot carries no state, so the top one is used. What is checked is the result below.
        var empties: [AXLogicProElements.EmptySendMenuControl] = []
        guard let sendsBefore = AXLogicProElements.sendSlotObservations(in: strip, runtime: runtime.ax,
                                                                         observingEmptySlot: { empties.append($0) }),
              let topEmpty = empties.min(by: {
                  (AXHelpers.getPosition($0.control, runtime: runtime.ax)?.y ?? .infinity)
                      < (AXHelpers.getPosition($1.control, runtime: runtime.ax)?.y ?? .infinity)
              }) else {
            return refuse(.unsupportedState, "no_empty_slot",
                "The strip shows no readable empty send slot; nothing was pressed.")
        }
        evidence["empty_slots_before"] = empties.count
        let occupiedBefore = sendsBefore.filter { $0.state != .observedEmpty }.count
        evidence["occupied_sends_before"] = occupiedBefore

        let front = FrontmostGate.prepareObserved(
            observe: runtime.observeFrontmost,
            activate: { ProcessUtils.activateLogicPro() },
            sleepMicros: { usleep($0) }
        )
        guard front.preparation.isReady else {
            return refuse(.unsupportedState, "logic_not_frontmost", "Logic Pro could not be brought to the front; nothing was pressed.")
        }

        // Open the popup and find Bus > Bus N in it.
        _ = AXHelpers.performAction(topEmpty.control, kAXPressAction as String, runtime: runtime.ax)
        var leaf: AXUIElement?
        for _ in 0..<10 {
            usleep(100_000)
            leaf = createSendBusLeaf(bus, runtime: runtime)
            if leaf != nil { break }
        }
        guard let leaf else {
            AXMouseHelper.pressEscape()
            return refuse(.elementNotFound, "bus_leaf_not_found", "The send popup's Bus submenu did not offer exactly one Bus \(bus); it was closed.")
        }
        _ = AXHelpers.performAction(leaf, kAXPressAction as String, runtime: runtime.ax)
        evidence["write_attempted"] = true

        // Read back: one more occupied send on that strip, to Bus N; and the receiver if created.
        var verdict: (send: Bool, receiver: Bool?) = (false, createReceiver && receivers.isEmpty ? false : nil)
        for _ in 0..<15 {
            usleep(100_000)
            guard let mixerNow = AXLogicProElements.getMixerArea(runtime: runtime),
                  let now = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: mixerNow, runtime: runtime.ax)?.strips else { continue }
            let namesNow = now.map { AXHelpers.getDescription($0, runtime: runtime.ax) ?? "" }
            guard let index = namesNow.firstIndex(where: { $0.utf8.elementsEqual(stripName.utf8) }),
                  let sendsAfter = AXLogicProElements.sendSlotObservations(in: now[index], runtime: runtime.ax) else { continue }
            let occupied = sendsAfter.filter { $0.state != .observedEmpty }
            let toBus = occupied.filter { slot in
                slot.destinationDisplay.map { RoutingGraphPublication.classifyOutputLabel($0) == (.bus, bus) } ?? false
            }
            verdict.send = occupied.count == occupiedBefore + 1 && !toBus.isEmpty
            evidence["occupied_sends_after"] = occupied.count
            evidence["send_ordinal"] = toBus.last?.ordinal ?? NSNull()
            if verdict.receiver != nil {
                if case .created(let name, let position) = CreateAuxVerifier.verdict(before: names, after: namesNow) {
                    let input = AXLogicProElements.inputSlotReading(in: now[position], runtime: runtime.ax)
                    if case .source(let label) = input, RoutingGraphPublication.classifyOutputLabel(label) == (.bus, bus) {
                        verdict.receiver = true
                        evidence["created_receiver"] = ["strip_index": position, "name": name, "input_bus": bus] as [String: Any]
                    }
                }
            } else if now.count != census.count {
                evidence["unexpected_side_effect"] = now.count > census.count ? "strip_created" : "strip_removed"
            }
            if verdict.send, verdict.receiver != false { break }
        }
        if verdict.send, verdict.receiver != false, evidence["unexpected_side_effect"] == nil {
            return .success(HonestContract.encodeStateA(extras: evidence))
        }
        evidence["hint"] = verdict.send
            ? "The send reads back, but the expected receiver (or an unchanged strip count) did not."
            : "The press landed, but no new send to Bus \(bus) read back on the strip."
        return .success(HonestContract.encodeStateB(reason: .readbackMismatch, extras: evidence))
    }

    /// The open popup's `Bus n` leaf under its Bus submenu: exactly one, or nil.
    private static func createSendBusLeaf(_ bus: Int, runtime: AXLogicProElements.Runtime) -> AXUIElement? {
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else { return nil }
        let menus = AXHelpers.findAllDescendants(of: app, role: kAXMenuRole as String, maxDepth: 14, runtime: runtime.ax)
        var leaves: [AXUIElement] = []
        for menu in menus {
            for parent in AXHelpers.getChildren(menu, runtime: runtime.ax)
            where AXLocalePolicy.outputPopupBusSubmenuTitle.matches(AXHelpers.getTitle(parent, runtime: runtime.ax), mode: .exact) {
                leaves += AXHelpers.findAllDescendants(of: parent, role: kAXMenuItemRole as String, maxDepth: 4, runtime: runtime.ax)
                    .filter { item in
                        // Measured: a bus already feeding an aux is listed as `Bus 6 \u{2192} Aux 1`.
                        AXHelpers.getTitle(item, runtime: runtime.ax).map {
                            let label = $0.components(separatedBy: " \u{2192}").first ?? $0
                            return RoutingGraphPublication.classifyOutputLabel(label) == (.bus, bus)
                        } ?? false
                    }
            }
        }
        return leaves.count == 1 ? leaves[0] : nil
    }
}
