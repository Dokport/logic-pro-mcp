@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// Injected native elements only. The English CUA discovery is not CF qualification.
@Suite("#967 one issued aux creation and exact-object inverse", .serialized)
struct Issue967OwnedAuxLifecycleTests {
    enum MenuFault: CaseIterable, Sendable { case unread, malformed, absent }
    enum MenuField: CaseIterable, Sendable { case semantic, enabled, children }
    struct MenuCase: Sendable {
        let creator: Bool
        let field: MenuField
        let fault: MenuFault
        static var allCases: [Self] {
            [false, true].flatMap { creator in
                MenuField.allCases.flatMap { field in
                    MenuFault.allCases.map { Self(creator: creator, field: field, fault: $0) }
                }
            }
        }
    }
    enum LateLoss: CaseIterable, Sendable { case cancellation, project }
    enum LateMoment: CaseIterable, Sendable { case beforeOptions, beforeCreator }
    enum ChildStatus: CaseIterable, Sendable {
        case noValue, unsupported, cannotComplete, invalid, disabled, failure, malformed
        var error: AXHelpers.AXStatusError {
            switch self {
            case .noValue: .init(raw: AXError.noValue.rawValue)
            case .unsupported: .init(raw: AXError.attributeUnsupported.rawValue)
            case .cannotComplete: .init(raw: AXError.cannotComplete.rawValue)
            case .invalid: .init(raw: AXError.invalidUIElement.rawValue)
            case .disabled: .init(raw: AXError.apiDisabled.rawValue)
            case .failure: .init(raw: AXError.failure.rawValue)
            case .malformed: .malformedChildren
            }
        }
        var definitiveAbsence: Bool { self == .noValue || self == .unsupported }
    }
    enum ScrollMetadata: CaseIterable, Sendable {
        case title, description, help, identifier
        var attribute: String {
            switch self {
            case .title: kAXTitleAttribute
            case .description: kAXDescriptionAttribute
            case .help: kAXHelpAttribute
            case .identifier: kAXIdentifierAttribute
            }
        }
    }
    final class Fixture: @unchecked Sendable {
        let b = FakeAXRuntimeBuilder()
        let window: AXUIElement
        let mixer: AXUIElement
        let options: AXUIElement
        let edit: AXUIElement
        let create: AXUIElement
        let delete: AXUIElement
        let original: [AXUIElement]
        let created: AXUIElement
        let app: AXUIElement
        let controls: [OwnedAuxLifecycle.Field: AXUIElement]
        let auxFilter: AXUIElement
        let optionMenu: AXUIElement
        let editMenu: AXUIElement
        var createPresses = 0
        var deletePresses = 0
        var delay = 0
        var issued = false
        var removed = false
        var additional = false
        var selected: [AXUIElement] = []
        var expandSelectionOnEdit = false
        var optionOpen = false
        var editOpen = false
        var replaceOriginal = false
        var removalDelay = 0
        var cancelOnOptions = false
        var cancelled = false
        var invalidatesDeletedCF = true
        var optionPresses = 0
        var menuFault: MenuFault?
        var menuField: MenuField = .semantic
        var faultCreator = true
        var extraMenuItem: AXUIElement?
        var childFaultReady = false
        var childFaultDelivered = false
        var focusMenuOnEdit = false
        var expandDuringFocusFootprint = false
        var focusReadAfterEdit = false
        var replacementCreated: AXUIElement?
        var lateLoss: LateLoss?
        var lateMoment: LateMoment = .beforeCreator
        var creatorLeafReady = false
        var lateFaultDelivered = false
        var footprintRootRead = false
        var footprintChildStatus: ChildStatus?
        var footprintChildReads = 0
        var optionalSubroleFault = false
        var optionalSubroleFaultReads = 0
        var unreadPreservedValue: AXUIElement?
        var currentlyReadingFootprint = false
        var structuralScroll: AXUIElement?
        var scrollMetadataFault: ScrollMetadata?
        var scrollMetadataFaultReads = 0
        var scrollMetadataError = AXHelpers.AXStatusError(raw: AXError.failure.rawValue)
        var unreadScrollChildren = false
        var unreadPreservedDescription: AXUIElement?
        var siblingMenus = false
        var afterOptionsChange: String?
        var extraMenuGroupNode: AXUIElement?
        var replacementOptionMenu: AXUIElement?
        var replaceMenuAfterLeaf = false
        var unreadMenuGroupWhenOpen = false
        var cancelHasNoEffect = false
        var optionCancelPresses = 0
        var editCancelPresses = 0
        var parentOnlyMenuBeforePress = false
        var alternateMenuOwner: AXUIElement?
        var alternateOwnerChildren: [AXUIElement] = []
        var alternateOwnerReordered = false
        var alternateOwnerUnread = false
        var creatorRequiresPick = false
        var creatorEffectUnknown = false
        var creatorActions: [String] = []
        var creatorActionNamesUnread = false
        var replaceCreatorBeforeDispatch = false
        var replacementCreator: AXUIElement?
        var creatorRequiresMouse = false
        var mouseFault: String?
        var mouseEvents: [String] = []
        var mousePreparations = 0
        var hitReads = 0
        var betweenClickHalves = false
        var readsBetweenClickHalves = 0
        var foregroundOwned = true
        var windowServerOwnerIsLogic = true
        var windowServerOwnerReadable = true
        var windowServerProbeAvailable = true
        var retiredPeerCopies: [AXUIElement]?
        var selectCreatedOnCreation = false

        init(delay: Int = 0) {
            self.delay = delay
            app = b.element(967_000); window = b.element(967_001)
            mixer = b.element(967_002); options = b.element(967_003); edit = b.element(967_004)
            create = b.element(967_005); delete = b.element(967_006)
            auxFilter = b.element(967_203)
            optionMenu = b.element(967_020); editMenu = b.element(967_021)
            original = [b.element(967_010), b.element(967_011)]
            created = b.element(967_012)
            var fields: [OwnedAuxLifecycle.Field: AXUIElement] = [:]
            for (offset, field) in OwnedAuxLifecycle.Field.allCases.enumerated() {
                let element = b.element(967_100 + offset)
                b.setRole(element, field.role)
                if let value = Self.defaults[field] {
                    switch value {
                    case .text(let text): b.setAttribute(element, field.attribute, text)
                    case .number(let number): b.setAttribute(element, field.attribute, number)
                    }
                }
                b.setChildren(element, [])
                fields[field] = element
            }
            controls = fields
            for (field, label) in [(OwnedAuxLifecycle.Field.format, "channel mode"), (.mute, "mute"),
                                  (.solo, "solo"), (.eqEnabled, "EQ"), (.gainReductionEnabled, "gain reduction meter"),
                                  (.volume, AXLocalePolicy.sliderVolumeHint.canonical),
                                  (.pan, AXLocalePolicy.sliderPanHint.canonical), (.automationEnabled, "automation")] {
                b.setAttribute(fields[field]!, kAXDescriptionAttribute as String, label)
            }
            b.setAttribute(fields[.input]!, kAXHelpAttribute as String, AXLocalePolicy.inputSlotHelpKeyword.canonical)
            b.setAttribute(fields[.output]!, kAXHelpAttribute as String, AXLocalePolicy.outputSlotHelpKeyword.canonical)
            let automationList = b.element(967_120)
            b.setRole(automationList, kAXButtonRole as String); b.setChildren(automationList, [])
            b.setAttribute(automationList, kAXDescriptionAttribute as String, "list")
            b.setChildren(fields[.automationMode]!, [fields[.automationEnabled]!, automationList])
            for strip in original + [created] { b.setRole(strip, kAXLayoutItemRole as String) }
            b.setChildren(original[0], []); b.setChildren(original[1], [])
            let fx = b.element(967_130); let send1 = b.element(967_131); let send2 = b.element(967_132)
            for button in [fx, send1, send2] { b.setRole(button, kAXButtonRole as String); b.setChildren(button, []) }
            b.setAttribute(fx, kAXDescriptionAttribute as String, AXLocalePolicy.audioPluginSlotLabel.canonical)
            for send in [send1, send2] { b.setAttribute(send, kAXHelpAttribute as String, AXLocalePolicy.sendSlotHelpKeyword.canonical) }
            b.setChildren(created, fields.filter { $0.key != .automationEnabled }.map(\.value)
                .sorted { b.elementID($0) < b.elementID($1) } + [fx, send1, send2])
            b.setRole(app, kAXApplicationRole as String); b.setRole(window, kAXWindowRole as String)
            b.setAttribute(window, kAXDocumentAttribute as String, "file:///tmp/967-owned.logicx")
            b.setAttribute(app, kAXFocusedUIElementAttribute as String, original[0])
            b.setAttribute(app, kAXWindowsAttribute as String, [window])
            b.setAttribute(app, kAXMainWindowAttribute, window)
            b.setAttribute(app, kAXFocusedWindowAttribute, window)
            let bar = b.element(967_140); let play = b.element(967_141); let record = b.element(967_142)
            b.setRole(bar, kAXGroupRole as String)
            b.setAttribute(bar, kAXDescriptionAttribute as String, AXLocalePolicy.controlBarGroupLabel.canonical)
            for (control, label) in [(play, AXLocalePolicy.transportPlayControl), (record, AXLocalePolicy.transportRecordControl)] {
                b.setRole(control, kAXCheckBoxRole as String); b.setChildren(control, [])
                b.setAttribute(control, kAXDescriptionAttribute as String, label.canonical)
                b.setAttribute(control, kAXValueAttribute as String, 0)
            }
            b.setChildren(bar, [play, record])
            let host = b.element(967_150); let toolbar = b.element(967_151)
            let modes = b.element(967_152); let filters = b.element(967_153)
            for group in [host, toolbar, filters] { b.setRole(group, kAXGroupRole as String) }
            b.setAttribute(host, kAXDescriptionAttribute as String, AXLocalePolicy.mixerNamedElement.canonical)
            b.setAttribute(toolbar, kAXDescriptionAttribute as String, AXLocalePolicy.mixerNamedElement.canonical)
            b.setRole(modes, kAXRadioGroupRole as String)
            var radios: [AXUIElement] = []
            for (offset, label) in [AXLocalePolicy.mixerPresentationSingle, AXLocalePolicy.mixerPresentationTracks, AXLocalePolicy.mixerPresentationAll].enumerated() {
                let radio = b.element(967_160 + offset); b.setRole(radio, kAXRadioButtonRole as String)
                b.setAttribute(radio, kAXDescriptionAttribute as String, label.canonical)
                b.setAttribute(radio, kAXValueAttribute as String, offset == 2 ? 1 : 0)
                b.setChildren(radio, []); radios.append(radio)
            }
            var filterControls: [AXUIElement] = []
            for (offset, label) in [AXLocalePolicy.mixerTypeFilterAudio, AXLocalePolicy.mixerTypeFilterInstrument,
                                   AXLocalePolicy.mixerTypeFilterBus, AXLocalePolicy.mixerTypeFilterAux, AXLocalePolicy.mixerTypeFilterInput,
                                   AXLocalePolicy.mixerTypeFilterOutput, AXLocalePolicy.mixerTypeFilterMasterVCA, AXLocalePolicy.mixerTypeFilterMIDI].enumerated() {
                let control = b.element(967_200 + offset); b.setRole(control, kAXCheckBoxRole as String)
                b.setAttribute(control, kAXDescriptionAttribute as String, label.canonical)
                b.setAttribute(control, kAXValueAttribute as String, 1)
                b.setChildren(control, []); filterControls.append(control)
            }
            b.setChildren(modes, radios); b.setChildren(filters, filterControls)
            let menus = b.element(967_154); b.setRole(menus, kAXGroupRole as String)
            b.setChildren(menus, [edit, options])
            b.setChildren(toolbar, [modes, filters, menus]); b.setChildren(host, [mixer, toolbar])
            b.setChildren(window, [host, bar]); b.setRole(mixer, "AXLayoutArea")
            b.setAttribute(mixer, kAXDescriptionAttribute as String, AXLocalePolicy.mixerNamedElement.canonical)
            b.setChildren(mixer, original)
            b.setRole(options, kAXMenuButtonRole as String); b.setRole(edit, kAXMenuButtonRole as String)
            b.setAttribute(options, kAXDescriptionAttribute as String, "Options")
            b.setAttribute(edit, kAXDescriptionAttribute as String, "Edit")
            b.setRole(optionMenu, kAXMenuRole as String); b.setRole(editMenu, kAXMenuRole as String)
            b.setRole(create, kAXMenuItemRole as String); b.setRole(delete, kAXMenuItemRole as String)
            b.setAttribute(create, kAXTitleAttribute as String, "Create New Auxiliary Channel Strip")
            b.setAttribute(delete, kAXIdentifierAttribute as String, "delete:")
            b.setAttribute(create, kAXEnabledAttribute as String, true)
            b.setAttribute(delete, kAXEnabledAttribute as String, true)
            b.setChildren(options, [optionMenu]); b.setChildren(optionMenu, [create]); b.setChildren(create, [])
            b.setChildren(edit, [editMenu]); b.setChildren(editMenu, [delete]); b.setChildren(delete, [])
            b.setActionNames(optionMenu, [kAXCancelAction as String])
            b.setActionNames(editMenu, [kAXCancelAction as String])
            b.setActionNames(create, [kAXPressAction as String, kAXPickAction as String, kAXCancelAction as String])
            setCreatorFrame()
            selected = [original[0]]
        }

        func setCreatorFrame(point: CGPoint = CGPoint(x: 100, y: 200), size: CGSize = CGSize(width: 180, height: 20)) {
            var point = point, size = size
            b.setAttribute(create, kAXPositionAttribute, AXValueCreate(.cgPoint, &point)!)
            b.setAttribute(create, kAXSizeAttribute, AXValueCreate(.cgSize, &size)!)
        }

        private func noteRead() {
            if betweenClickHalves { readsBetweenClickHalves += 1 }
        }

        var mouse: AXMouseHelper.Runtime {
            .init(postMouseEvent: { _, _, _ in Issue.record("Unprepared mouse event forbidden"); return false },
                  postKeyEvent: { _ in Issue.record("Keyboard fallback forbidden"); return false },
                  postUnicodeScalar: { _ in Issue.record("Typing forbidden"); return false },
                  sleepMicros: { _ in Issue.record("Sleep between input halves forbidden") },
                  prepareMouseClick: { [self] point, count in
                      mousePreparations += 1
                      #expect(point == CGPoint(x: 190, y: 210) && count == 1)
                      if mouseFault == "prepare_failed" { return nil }
                      return .init(postDown: { [self] in
                          mouseEvents.append("down"); betweenClickHalves = true
                          if mouseFault == "down_failed" { betweenClickHalves = false; return false }
                          return true
                      }, postUp: { [self] in
                          mouseEvents.append("up"); betweenClickHalves = false
                          createPresses += 1
                          if !creatorEffectUnknown { issued = true }
                          if issued && selectCreatedOnCreation {
                              selected = [created]
                              b.setAttribute(app, kAXFocusedUIElementAttribute, created)
                          }
                          optionOpen = false
                          return mouseFault != "up_failed"
                      })
                  })
        }

        private func creatorHit(_ root: AXUIElement, _ point: CGPoint) -> Result<AXUIElement?, AXHelpers.AXStatusError> {
            noteRead(); hitReads += 1
            #expect(CFEqual(root, app) && point == CGPoint(x: 190, y: 210))
            if mouseFault == "foreign_hit" || (mouseFault == "late_foreign_hit" && hitReads >= 2) {
                return .success(original[0])
            }
            if mouseFault == "missing_hit" { return .success(nil) }
            if mouseFault == "unread_hit" { return .failure(.init(raw: AXError.cannotComplete.rawValue)) }
            if hitReads == 1 {
                switch mouseFault {
                case "changed_frame": setCreatorFrame(point: CGPoint(x: 101, y: 200))
                case "peer_drift": b.setAttribute(original[0], kAXValueAttribute, 1)
                default: break
                }
            }
            if hitReads == 2 {
                switch mouseFault {
                case "lost_foreground": foregroundOwned = false
                case "foreign_window_server": windowServerOwnerIsLogic = false
                case "changed_document": b.setAttribute(window, kAXDocumentAttribute, "file:///tmp/967-foreign.logicx")
                case "changed_window": b.setAttribute(app, kAXFocusedWindowAttribute, b.element(967_499))
                case "changed_focus": b.setAttribute(app, kAXFocusedUIElementAttribute, original[1])
                case "changed_menu": optionOpen = false
                case "cancelled": cancelled = true
                default: break
                }
            }
            return .success(create)
        }

        static let defaults: [OwnedAuxLifecycle.Field: OwnedAuxLifecycle.Value] = [
            .format: .text("Stereo"), .input: .text("Input 1-2"), .output: .text("Stereo Output"),
            .volume: .number(0), .pan: .number(0), .mute: .text("off"), .solo: .text("off"),
            .automationMode: .text("Read, automation enabled"), .automationEnabled: .number(1),
            .eqEnabled: .text("off"), .gainReductionEnabled: .text("off"),
        ]

        var runtime: AXLogicProElements.Runtime {
            let base = b.makeLogicRuntime(appElement: app, attributeValueHandler: { [self] element, attribute in
                noteRead()
                if CFEqual(element, mixer), attribute == kAXSelectedChildrenAttribute as String {
                    return .some(selected as AnyObject)
                }
                return nil
            }, attributeValueResultHandler: { [self] element, attribute in
                attributeResult(element, attribute)
            }, childrenHandler: { [self] element in currentChildren(element) },
               childrenResultHandler: { [self] element in
                   noteRead()
                   if optionOpen, alternateOwnerUnread, let owner = alternateMenuOwner, CFEqual(element, owner) {
                       return .failure(.init(raw: AXError.cannotComplete.rawValue))
                   }
                   if siblingMenus, optionOpen, unreadMenuGroupWhenOpen, CFEqual(element, b.element(967_154)) {
                       return .failure(.init(raw: AXError.cannotComplete.rawValue))
                   }
                   if currentlyReadingFootprint, unreadScrollChildren,
                      let scroll = structuralScroll, CFEqual(element, scroll) {
                       return .failure(.init(raw: AXError.cannotComplete.rawValue))
                   }
                   if footprintRootRead, CFEqual(element, b.element(967_141)), let status = footprintChildStatus {
                       footprintChildReads += 1
                       return .failure(status.error)
                   }
                   if let item = extraMenuItem, CFEqual(element, item), menuField == .children,
                      let fault = menuFault, childFaultReady, !childFaultDelivered {
                       childFaultDelivered = true
                       switch fault {
                       case .unread: return .failure(.init(raw: AXError.cannotComplete.rawValue))
                       case .malformed: return .failure(.malformedChildren)
                       case .absent: return .failure(.init(raw: AXError.noValue.rawValue))
                       }
                   }
                   return currentChildren(element).map { .success($0) }
               },
               setAttributeHandler: nil, performActionHandler: { [self] element, action in
                if action == kAXCancelAction as String {
                    if CFEqual(element, optionMenu) {
                        optionCancelPresses += 1
                        if !cancelHasNoEffect { optionOpen = false }
                    } else if CFEqual(element, editMenu) {
                        editCancelPresses += 1; editOpen = false
                    } else { Issue.record("A foreign menu must never be cancelled") }
                    return true
                }
                if CFEqual(element, create) {
                    creatorActions.append(action); createPresses += 1
                    if !creatorRequiresMouse && !creatorEffectUnknown && (!creatorRequiresPick || action == kAXPickAction as String) { issued = true }
                }
                if let replacementCreator, CFEqual(element, replacementCreator) {
                    Issue.record("A replacement creator cannot inherit retained-leaf authority")
                }
                if CFEqual(element, options) { optionOpen = true; optionPresses += 1 }
                if CFEqual(element, options), let change = afterOptionsChange {
                    switch change {
                    case "disabled": b.setAttribute(create, kAXEnabledAttribute, 0)
                    case "extra_node", "unrelated_menu":
                        let extra = b.element(967_470)
                        b.setRole(extra, change == "unrelated_menu" ? kAXMenuRole as String : kAXGroupRole as String)
                        b.setChildren(extra, []); extraMenuGroupNode = extra
                    case "control_drift": b.setAttribute(b.element(967_472), kAXValueAttribute, 0.5)
                    case "original_drift": b.setAttribute(original[0], kAXValueAttribute, 1)
                    case "foreign_parent":
                        let foreign = b.element(967_480); b.setRole(foreign, kAXGroupRole as String)
                        b.setChildren(foreign, [optionMenu])
                    case "reparented":
                        b.setChildren(b.element(967_151), [b.element(967_152), b.element(967_153)])
                    case "replaced_intermediate":
                        let replacement = b.element(967_490); b.setRole(replacement, kAXGroupRole as String)
                        b.setChildren(replacement, [edit, options])
                        b.setChildren(b.element(967_151), [b.element(967_152), b.element(967_153), replacement])
                    case "intermediate_role": b.setRole(b.element(967_154), kAXButtonRole as String)
                    case "ancestor_peers":
                        let extra = b.element(967_491); b.setRole(extra, kAXGroupRole as String); b.setChildren(extra, [])
                        let toolbar = b.element(967_151)
                        b.setChildren(toolbar, b.makeAXRuntime().children(toolbar) + [extra])
                    default: break
                    }
                }
                if CFEqual(element, options), cancelOnOptions { cancelled = true }
                if CFEqual(element, create) { optionOpen = false }
                if CFEqual(element, edit) { editOpen = true }
                if CFEqual(element, edit), focusMenuOnEdit {
                    b.setAttribute(app, kAXFocusedUIElementAttribute as String, delete)
                }
                if CFEqual(element, edit), expandSelectionOnEdit { selected = [created, original[0]] }
                if CFEqual(element, delete) { deletePresses += 1; removed = true; editOpen = false }
                return true
            }, executeAppleScript: { _ in Issue.record("AppleScript forbidden"); return .error("forbidden") })
            let hit: (@Sendable (AXUIElement, CGPoint) -> Result<AXUIElement?, AXHelpers.AXStatusError>)?
            if mouseFault == "missing_hit_seam" { hit = nil }
            else { hit = { [self] root, point in creatorHit(root, point) } }
            let ax = AXHelpers.Runtime(axApp: base.ax.axApp, attributeValue: base.ax.attributeValue,
                attributeIsSettable: base.ax.attributeIsSettable, setAttributeValue: base.ax.setAttributeValue,
                children: base.ax.children, performAction: base.ax.performAction, childCount: base.ax.childCount,
                actionNames: base.ax.actionNames, actionNamesResult: { [self] element in
                    noteRead()
                    if CFEqual(element, create), creatorActionNamesUnread {
                        return .failure(.init(raw: AXError.cannotComplete.rawValue))
                    }
                    return .success(base.ax.actionNames(element))
                }, childrenResult: base.ax.childrenResult, attributeValueResult: base.ax.attributeValueResult,
                performActionResult: base.ax.performActionResult, elementAtPosition: hit,
                attributeValuesResult: base.ax.attributeValuesResult)
            let observe: @Sendable () -> ProcessUtils.KeyboardOwnershipObservation = { [self] in
                ProcessUtils.KeyboardOwnershipObservation(reason: !windowServerOwnerReadable ? .windowListUnavailable
                    : windowServerOwnerIsLogic ? .logicOwnsKeyboard : .keyboardOwnerNotLogic,
                    keyboardOwnerPID: windowServerOwnerReadable ? (windowServerOwnerIsLogic ? base.logicProPID() : pid_t(999_999)) : nil,
                    keyboardOwnerBundleID: windowServerOwnerReadable ? (windowServerOwnerIsLogic ? "com.apple.logic10" : "com.example.foreign") : nil,
                    keyboardWindowLayer: windowServerOwnerReadable ? 8 : nil,
                    focusedApplicationPID: foregroundOwned ? base.logicProPID() : nil,
                    focusRead: foregroundOwned ? .read : .unavailable)
            }
            return .init(logicProPID: base.logicProPID, ax: ax, executeAppleScript: base.executeAppleScript,
                         onScreenWindowList: { nil }, postPopupMenuEscape: { Issue.record("Escape forbidden") },
                         focusedApplicationPID: { [self] in foregroundOwned ? base.logicProPID() : nil },
                         observeFrontmost: windowServerProbeAvailable ? observe : nil)
        }

        private func attributeResult(_ element: AXUIElement, _ attribute: String) -> Result<AnyObject?, AXHelpers.AXStatusError>? {
            noteRead()
            if CFEqual(element, app) { currentlyReadingFootprint = false }
            if CFEqual(element, window), attribute == kAXEnabledAttribute {
                footprintRootRead = true; currentlyReadingFootprint = true
            }
            if currentlyReadingFootprint, let scroll = structuralScroll, CFEqual(element, scroll),
               let fault = scrollMetadataFault, attribute == fault.attribute {
                scrollMetadataFaultReads += 1
                return .failure(scrollMetadataError)
            }
            if let unreadPreservedDescription, CFEqual(element, unreadPreservedDescription), attribute == kAXDescriptionAttribute {
                return .failure(.init(raw: AXError.failure.rawValue))
            }
            if footprintRootRead, optionalSubroleFault, CFEqual(element, b.element(967_141)), attribute == kAXSubroleAttribute {
                optionalSubroleFaultReads += 1
                return .failure(.init(raw: AXError.failure.rawValue))
            }
            if let unreadPreservedValue, CFEqual(element, unreadPreservedValue), attribute == kAXValueAttribute {
                return .failure(.init(raw: AXError.failure.rawValue))
            }
            if CFEqual(element, app), attribute == kAXFocusedUIElementAttribute, editOpen {
                focusReadAfterEdit = true
            }
            if CFEqual(element, delete), attribute == kAXEnabledAttribute,
               focusReadAfterEdit, expandDuringFocusFootprint { selected = [created, original[0]] }
            if CFEqual(element, create), attribute == kAXEnabledAttribute, optionOpen { creatorLeafReady = true }
            if replaceCreatorBeforeDispatch, creatorLeafReady, replacementCreator == nil,
               CFEqual(element, original[1]), attribute == kAXEnabledAttribute {
                let replacement = b.element(967_492)
                b.setRole(replacement, kAXMenuItemRole as String); b.setChildren(replacement, [])
                b.setAttribute(replacement, kAXTitleAttribute, "Create New Auxiliary Channel Strip")
                b.setAttribute(replacement, kAXEnabledAttribute, 1)
                b.setActionNames(replacement, [kAXPressAction as String, kAXPickAction as String, kAXCancelAction as String])
                b.setChildren(optionMenu, [replacement]); replacementCreator = replacement
            }
            if CFEqual(element, create), attribute == kAXEnabledAttribute, optionOpen, replaceMenuAfterLeaf,
               replacementOptionMenu == nil {
                let replacement = b.element(967_481)
                b.setRole(replacement, kAXMenuRole as String); b.setChildren(replacement, [create])
                b.setAttribute(replacement, kAXParentAttribute, b.element(967_154))
                b.setActionNames(replacement, [kAXCancelAction as String]); replacementOptionMenu = replacement
            }
            if let loss = lateLoss, !lateFaultDelivered, CFEqual(element, original[1]),
               attribute == kAXEnabledAttribute,
               lateMoment == .beforeOptions ? !optionOpen : creatorLeafReady {
                lateFaultDelivered = true
                switch loss {
                case .cancellation: cancelled = true
                case .project: b.setAttribute(window, kAXDocumentAttribute as String, "file:///tmp/967-other.logicx")
                }
            }
            if let item = extraMenuItem, CFEqual(element, item), let fault = menuFault {
                if attribute == kAXEnabledAttribute, menuField == .children { childFaultReady = true }
                let target = menuField == .semantic ? (faultCreator ? kAXTitleAttribute : kAXIdentifierAttribute) : kAXEnabledAttribute
                if menuField != .children, attribute == target {
                    switch fault {
                    case .unread: return .failure(.init(raw: AXError.cannotComplete.rawValue))
                    case .malformed: return .success(menuField == .enabled ? "malformed" as NSString : NSNumber(value: 42))
                    case .absent: return .success(nil)
                    }
                }
            }
            if CFEqual(element, created), removed, removalDelay == 0, invalidatesDeletedCF {
                return .failure(.init(raw: AXError.invalidUIElement.rawValue))
            }
            return nil
        }

        func addFaultedMenuCandidate(creator: Bool, field: MenuField, fault: MenuFault) {
            let item = b.element(967_350)
            b.setRole(item, kAXMenuItemRole as String); b.setChildren(item, [])
            b.setAttribute(item, kAXTitleAttribute as String, "Create New Auxiliary Channel Strip")
            b.setAttribute(item, kAXIdentifierAttribute as String, "delete:")
            b.setAttribute(item, kAXEnabledAttribute as String, 1)
            b.setChildren(creator ? optionMenu : editMenu, [creator ? create : delete, item])
            extraMenuItem = item; faultCreator = creator; menuField = field; menuFault = fault
        }

        func addStructuralScroll(role: String = kAXScrollAreaRole as String) -> (scroll: AXUIElement, viewport: AXUIElement) {
            let scroll = b.element(967_450), viewport = b.element(967_451)
            b.setRole(scroll, role)
            b.setAttribute(scroll, kAXTitleAttribute, "Viewport")
            b.setAttribute(scroll, kAXDescriptionAttribute, "Unrelated view")
            b.setAttribute(scroll, kAXHelpAttribute, "Viewport container")
            b.setAttribute(scroll, kAXIdentifierAttribute, "fixture.viewport")
            b.setAttribute(scroll, kAXValueAttribute, 0.25)
            b.setRole(viewport, kAXScrollBarRole as String); b.setAttribute(viewport, kAXValueAttribute, 0.25)
            b.setChildren(viewport, []); b.setChildren(scroll, [viewport])
            b.setChildren(window, b.makeAXRuntime().children(window) + [scroll])
            structuralScroll = scroll
            return (scroll, viewport)
        }

        private func currentChildren(_ element: AXUIElement) -> [AXUIElement]? {
            if let owner = alternateMenuOwner, CFEqual(element, owner) {
                var children = alternateOwnerChildren
                if alternateOwnerReordered, optionOpen { children.reverse() }
                if optionOpen { children.append(replacementOptionMenu ?? optionMenu) }
                if editOpen { children.append(editMenu) }
                return children
            }
            if siblingMenus, CFEqual(element, b.element(967_154)) {
                var children = [edit, options]
                if alternateMenuOwner == nil, optionOpen || (parentOnlyMenuBeforePress && optionCancelPresses == 0) {
                    children.append(replacementOptionMenu ?? optionMenu)
                }
                if alternateMenuOwner == nil, editOpen { children.append(editMenu) }
                if let extraMenuGroupNode { children.append(extraMenuGroupNode) }
                return children
            }
            if CFEqual(element, options) { return optionOpen ? [replacementOptionMenu ?? optionMenu] : [] }
            if CFEqual(element, edit) { return editOpen ? [editMenu] : [] }
            guard CFEqual(element, mixer) else { return nil }
            if issued && delay > 0 { delay -= 1; return original }
            var removalPending = false
            if removed && removalDelay > 0 { removalDelay -= 1; removalPending = true }
            let originals = issued && retiredPeerCopies != nil ? retiredPeerCopies!
                : replaceOriginal ? [b.element(967_098), original[1]] : original
            return originals + (issued && (!removed || removalPending) ? [replacementCreated ?? created] : [])
                + (additional ? [b.element(967_099)] : [])
        }

        func modelWholePeerRetirement() {
            let control = b.element(967_800)
            b.setRole(control, kAXSliderRole as String)
            b.setAttribute(control, kAXValueAttribute, 0.75)
            b.setChildren(control, []); b.setChildren(original[0], [control])
            let copiedControl = b.element(967_801)
            b.setRole(copiedControl, kAXSliderRole as String)
            b.setAttribute(copiedControl, kAXValueAttribute, 0.75)
            b.setChildren(copiedControl, [])
            let copies = [b.element(967_802), b.element(967_803)]
            for copy in copies { b.setRole(copy, kAXLayoutItemRole as String) }
            b.setChildren(copies[0], [copiedControl]); b.setChildren(copies[1], [])
            retiredPeerCopies = copies
            selectCreatedOnCreation = true
        }

        func useNativeSiblingMenuAttachment() {
            siblingMenus = true
            // Native Options exposes its menu through AXChildren, while the same
            // menu CF is also an actual sibling under the button's held group.
            b.setAttribute(optionMenu, kAXParentAttribute, b.element(967_154))
            b.setAttribute(editMenu, kAXParentAttribute, b.element(967_154))
            let protected = b.element(967_472)
            b.setRole(protected, kAXSliderRole as String); b.setAttribute(protected, kAXValueAttribute, 0.25)
            b.setChildren(protected, [])
            let bar = b.element(967_140)
            b.setChildren(bar, b.makeAXRuntime().children(bar) + [protected])
        }

        func useDistinctHeldMenuOwner(containsControl: Bool = true, heldBefore: Bool = true) {
            useNativeSiblingMenuAttachment()
            let owner = b.element(967_485)
            b.setRole(owner, kAXGroupRole as String)
            alternateOwnerChildren = containsControl ? [edit, options] : []
            b.setChildren(owner, alternateOwnerChildren)
            // The reported control AXParent remains unchanged. The window's
            // held child graph independently exposes the popup's actual owner.
            for control in [edit, options] { b.setAttribute(control, kAXParentAttribute, b.element(967_154)) }
            for menu in [editMenu, optionMenu] { b.setAttribute(menu, kAXParentAttribute, owner) }
            if heldBefore { b.setChildren(window, b.makeAXRuntime().children(window) + [owner]) }
            alternateMenuOwner = owner
        }

        func useNativeAncestorPopupParent() {
            useNativeSiblingMenuAttachment()
            // Measured native shape: popup AXParent is the held toolbar ancestor,
            // while its actual new AXChildren edge is on the held button group.
            for menu in [optionMenu, editMenu] { b.setAttribute(menu, kAXParentAttribute, b.element(967_151)) }
        }

        func context(nativeControls: Bool = false) throws -> OwnedAuxLifecycle.Context {
            let bindings = original.map { AXMixerStripBinding.Binding(window: window, mixer: mixer, strip: $0,
                document: "file:///tmp/967-owned.logicx") }
            var population = SessionPopulationObservation.FreshPopulation(
                project: ProjectInfo(name: "967-owned", filePath: "/tmp/967-owned.logicx"), tracks: nil,
                strips: bindings.enumerated().map { index, binding in
                    var row = ChannelStripState(trackIndex: index); row.physicalBinding = binding; return row
                }, fileTrackCount: nil, beganAt: .now, endedAt: .now, stable: true)
            population.ownedMixerSelectedPopulation = bindings
            population.hiddenTracksShown = true
            population.uiEffects.restoration = "restored"
            population.mixerPresentation = .init(mode: "all", typeFilters: Dictionary(uniqueKeysWithValues:
                ["audio", "instrument", "aux", "bus", "input", "output", "master_vca", "midi"].map { ($0, Optional(true)) }))
            population.presentationObservation = .init(mixerVisible: true, isPlaying: false, isRecording: false, uiLocale: "en-US")
            let provider: @Sendable (AXUIElement) -> [OwnedAuxLifecycle.Field: AXUIElement]? = { [self] strip in
                CFEqual(strip, created) ? controls : nil
            }
            let prepared = OwnedAuxLifecycle.prepare(population: population, options: options, edit: edit,
                acceptedDefaults: Self.defaults, runtime: runtime, mouse: mouse,
                initialControls: nativeControls ? nil : provider, settleSamples: 3, waitForNextSample: {})
            return try #require(prepared)
        }
    }

    private func owned<T>(_ fixture: Fixture? = nil, _ body: () async throws -> T) async throws -> T {
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "967-owned-aux"))
        defer { gate.release(claim) }
        return try await OperationTraceContext.$current.withValue(
            OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) },
                                  cancellationRequested: { fixture?.cancelled == true })) {
                try await body()
            }
    }

    @Test func delayedCreationIssuesOnceAndRetainsActualInputDefaults() async throws {
        try await owned {
            let f = Fixture(delay: 2); let context = try f.context()
            let receipt = await context.create()
            #expect(receipt.status == .created)
            #expect(receipt.defaults == Fixture.defaults)
            #expect(f.createPresses == 1)
            let created = try #require(receipt.created)
            #expect(CFEqual(created, f.created))
            let reconciled = await context.create()
            #expect(reconciled.status == .created)
            #expect(f.createPresses == 1)
        }
    }

    @Test func wholePeerRedrawKeepsOneActuallySelectedCreatedObject() async throws {
        try await owned {
            let f = Fixture(); f.modelWholePeerRetirement()
            let context = try f.context(nativeControls: true)
            let created = await context.create()
            #expect(created.status == .created)
            #expect(created.created.map { CFEqual($0, f.created) } == true)
            #expect(created.inverse != nil)
            #expect(f.createPresses == 1)
            #expect(await context.create().status == .created)
            #expect(f.createPresses == 1)
            let inverse = try #require(created.inverse)
            #expect(await context.remove(inverse).status == .removed)
            #expect(f.deletePresses == 1)
        }
    }

    @Test func wholeRedrawInversePreservesANewerPeerEdit() async throws {
        try await owned {
            let f = Fixture(); f.modelWholePeerRetirement()
            let context = try f.context(nativeControls: true)
            let inverse = try #require(await context.create().inverse)
            f.b.setAttribute(f.b.element(967_801), kAXValueAttribute, 0.5)
            #expect(await context.remove(inverse).status == .residual)
            #expect(f.deletePresses == 0)
        }
    }

    @Test(arguments: ["changed_peer", "partial_retirement", "wrong_selected", "created_replaced"])
    func redrawNeverAdoptsChangedPeersOrAnotherCreatedObject(fault: String) async throws {
        try await owned {
            let f = Fixture(); f.modelWholePeerRetirement()
            switch fault {
            case "changed_peer": f.b.setAttribute(f.b.element(967_801), kAXValueAttribute, 0.5)
            case "partial_retirement": f.retiredPeerCopies = [f.original[0], f.b.element(967_803)]
            case "wrong_selected": f.selectCreatedOnCreation = false
            default: break
            }
            let context = try f.context(nativeControls: true)
            let created = await context.create()
            if fault == "created_replaced" {
                #expect(created.status == .created)
                let replacement = f.b.element(967_804)
                f.b.setRole(replacement, kAXLayoutItemRole as String); f.b.setChildren(replacement, [])
                f.replacementCreated = replacement
                #expect(await context.create().status == .residual)
            } else {
                #expect(created.inverse == nil)
                #expect(created.status != .created)
            }
            #expect(f.createPresses == 1)
            #expect(f.deletePresses == 0)
        }
    }

    @Test func preparedCreatorClickSelectsWithoutTryingAcknowledgedNoEffectAXActions() async throws {
        try await owned {
            let f = Fixture(); f.useNativeAncestorPopupParent(); f.creatorRequiresMouse = true
            let context = try f.context(nativeControls: true)
            #expect(await context.create().status == .created)
            #expect(f.creatorActions.isEmpty)
            #expect(f.mouseEvents == ["down", "up"])
            #expect(f.hitReads >= 2 && f.mousePreparations == 1)
            #expect(f.readsBetweenClickHalves == 0)
            #expect(await context.create().status == .created)
            #expect(f.mouseEvents == ["down", "up"] && f.createPresses == 1)
        }
    }

    @Test(arguments: ["missing_position", "unread_position", "replaced_leaf"])
    func unlocatedOrRetiredCreatorLeafCannotAuthorizeDispatch(change: String) async throws {
        try await owned {
            let f = Fixture(); f.useNativeAncestorPopupParent()
            switch change {
            case "missing_position": f.b.removeAttribute(f.create, kAXPositionAttribute)
            case "unread_position": f.b.setAttribute(f.create, kAXPositionAttribute, "unreadable fixture")
            case "replaced_leaf": f.replaceCreatorBeforeDispatch = true
            default: Issue.record("Unknown registered creator case")
            }
            let context = try f.context(nativeControls: true)
            #expect(await context.create().status == .rejectedBeforeWrite)
            #expect(f.creatorActions.isEmpty)
            #expect(f.createPresses == 0 && f.deletePresses == 0)
            if change == "replaced_leaf" { #expect(f.replacementCreator != nil) }
        }
    }

    @Test(arguments: ["unknown_effect", "down_failed", "up_failed"])
    func uncertainCreatorClickNeverFallsBackOrReissuesOnTheSameContext(change: String) async throws {
        try await owned {
            let f = Fixture(); f.useNativeAncestorPopupParent(); f.creatorRequiresMouse = true; f.creatorEffectUnknown = true
            f.mouseFault = change
            let context = try f.context(nativeControls: true)
            #expect(await context.create().status == .pending)
            #expect(await context.create().status == .pending)
            #expect(f.creatorActions.isEmpty && f.deletePresses == 0)
            #expect(f.mousePreparations == 1)
            #expect(f.mouseEvents == (change == "down_failed" ? ["down"] : ["down", "up"]))
            #expect(f.readsBetweenClickHalves == 0)
        }
    }

    @Test(arguments: ["missing_position", "malformed_position", "missing_size", "nonfinite_position", "nonfinite_size", "zero_size", "overflow_center",
                      "foreign_hit", "missing_hit", "unread_hit", "missing_hit_seam", "prepare_failed", "changed_frame", "late_foreign_hit",
                      "lost_foreground", "foreign_window_server", "changed_document", "changed_window", "changed_focus", "changed_menu", "peer_drift", "cancelled"])
    func unprovedCreatorClickTargetOrCustodyRefusesBeforeInput(change: String) async throws {
        let f = Fixture(); f.useNativeAncestorPopupParent(); f.creatorRequiresMouse = true; f.mouseFault = change
        switch change {
        case "missing_position": f.b.removeAttribute(f.create, kAXPositionAttribute)
        case "malformed_position": f.b.setAttribute(f.create, kAXPositionAttribute, "not a point")
        case "missing_size": f.b.removeAttribute(f.create, kAXSizeAttribute)
        case "nonfinite_position": f.setCreatorFrame(point: CGPoint(x: CGFloat.nan, y: 200))
        case "nonfinite_size": f.setCreatorFrame(size: CGSize(width: CGFloat.infinity, height: 20))
        case "zero_size": f.setCreatorFrame(size: .zero)
        case "overflow_center": f.setCreatorFrame(point: CGPoint(x: CGFloat.greatestFiniteMagnitude, y: 200), size: CGSize(width: CGFloat.greatestFiniteMagnitude, height: 20))
        default: break
        }
        try await owned(f) {
            let context = try f.context(nativeControls: true)
            #expect(await context.create().status == .rejectedBeforeWrite)
            #expect(f.mouseEvents.isEmpty && f.creatorActions.isEmpty)
            #expect(f.createPresses == 0 && f.deletePresses == 0)
        }
    }

    @Test(arguments: ["foreign_modal", "unread_owner", "missing_probe"])
    func windowServerOwnerIsRequiredEvenWhenAXFocusStillNamesLogic(fault: String) async throws {
        try await owned {
            let f = Fixture()
            if fault == "foreign_modal" { f.windowServerOwnerIsLogic = false }
            if fault == "unread_owner" { f.windowServerOwnerReadable = false }
            if fault == "missing_probe" { f.windowServerProbeAvailable = false }
            let context = try f.context()
            #expect(await context.create().status == .rejectedBeforeWrite)
            #expect(f.optionPresses == 0 && f.createPresses == 0 && f.deletePresses == 0)
        }
    }

    @Test func foreignWindowServerOwnerCannotAuthorizeOwnedDeletion() async throws {
        try await owned {
            let f = Fixture(); let context = try f.context()
            let proof = try #require(await context.create().inverse)
            f.selected = [f.created]
            f.b.setAttribute(f.app, kAXFocusedUIElementAttribute, f.created)
            f.windowServerOwnerIsLogic = false
            #expect(await context.remove(proof).status == .residual)
            #expect(f.deletePresses == 0)
        }
    }

    @Test func ownedSiblingMenusPreserveOriginalControlsAndPermitExactLifecycle() async throws {
        try await owned {
            let f = Fixture(); f.useNativeSiblingMenuAttachment()
            let context = try f.context(nativeControls: true)
            let receipt = await context.create()
            #expect(receipt.status == .created)
            let proof = try #require(receipt.inverse)
            f.selected = [f.created]; f.b.setAttribute(f.app, kAXFocusedUIElementAttribute, f.created)
            #expect(await context.remove(proof).status == .removed)
            #expect(f.createPresses == 1 && f.deletePresses == 1)
            #expect(f.optionCancelPresses == 0 && f.editCancelPresses == 0)
        }
    }

    @Test(arguments: ["disabled", "extra_node", "unrelated_menu", "control_drift", "original_drift"])
    func preCreatorRefusalCancelsOnlyItsRetainedSiblingMenu(change: String) async throws {
        try await owned {
            let f = Fixture(); f.useNativeSiblingMenuAttachment(); f.afterOptionsChange = change
            let context = try f.context(nativeControls: true)
            let receipt = await context.create()
            #expect(receipt.status == .rejectedBeforeWrite)
            #expect(f.createPresses == 0 && f.deletePresses == 0)
            #expect(f.optionCancelPresses == 1 && f.editCancelPresses == 0)
            #expect(!f.optionOpen)
            if change == "unrelated_menu" { #expect(f.extraMenuGroupNode != nil) }
        }
    }

    @Test(arguments: ["preexisting", "replacement", "foreign_parent", "unread_group", "missing_cancel", "cancel_no_effect"])
    func siblingMenuCustodyLossNeverCancelsAForeignMenu(change: String) async throws {
        try await owned {
            let f = Fixture(); f.useNativeSiblingMenuAttachment()
            switch change {
            case "preexisting": f.optionOpen = true
            case "replacement": f.replaceMenuAfterLeaf = true
            case "foreign_parent": f.afterOptionsChange = change
            case "unread_group": f.unreadMenuGroupWhenOpen = true
            case "missing_cancel": f.afterOptionsChange = "disabled"; f.b.setActionNames(f.optionMenu, [])
            case "cancel_no_effect": f.afterOptionsChange = "disabled"; f.cancelHasNoEffect = true
            default: Issue.record("Unknown registered menu case")
            }
            let context = try f.context(nativeControls: true)
            let receipt = await context.create()
            #expect(receipt.status == .rejectedBeforeWrite)
            #expect(f.createPresses == 0 && f.deletePresses == 0)
            #expect(f.optionCancelPresses == (change == "cancel_no_effect" ? 1 : 0))
            #expect(f.editCancelPresses == 0)
            if change == "preexisting" { #expect(f.optionPresses == 0) }
            if change == "cancel_no_effect" {
                #expect(f.optionOpen)
                #expect(receipt.diagnostic == "owned_menu_restoration_unverified")
            }
        }
    }

    @Test func unretainedEditMenuDoesNotReuseClosedOptionsCustody() async throws {
        try await owned {
            let f = Fixture(); f.useNativeSiblingMenuAttachment()
            let context = try f.context(nativeControls: true)
            let proof = try #require(await context.create().inverse)
            let foreign = f.b.element(967_480); f.b.setRole(foreign, kAXGroupRole as String)
            f.b.setChildren(foreign, [f.editMenu])
            f.selected = [f.created]; f.b.setAttribute(f.app, kAXFocusedUIElementAttribute, f.created)
            let receipt = await context.remove(proof)
            #expect(receipt.status == .residual)
            #expect(receipt.diagnostic == "owned_menu_ownership_unavailable")
            #expect(f.deletePresses == 0 && f.editCancelPresses == 0 && f.optionCancelPresses == 0)
        }
    }

    @Test func parentOnlyPreexistingMenuNeverBecomesOwnedAfterButtonExposure() async throws {
        try await owned {
            let f = Fixture(); f.useNativeSiblingMenuAttachment(); f.parentOnlyMenuBeforePress = true
            let context = try f.context(nativeControls: true)
            #expect(await context.create().status == .rejectedBeforeWrite)
            #expect(f.createPresses == 0 && f.deletePresses == 0)
            #expect(f.optionCancelPresses == 0 && f.editCancelPresses == 0)
            let remaining = AXHelpers.getChildren(f.b.element(967_154), runtime: f.runtime.ax)
            #expect(remaining.filter({ CFEqual($0, f.optionMenu) }).count == 1)
        }
    }

    @Test func distinctAlreadyHeldChildGraphOwnerSupportsExactMenuLifecycle() async throws {
        try await owned {
            let f = Fixture(); f.useDistinctHeldMenuOwner()
            let context = try f.context(nativeControls: true)
            let receipt = await context.create()
            #expect(receipt.status == .created)
            let proof = try #require(receipt.inverse)
            f.selected = [f.created]; f.b.setAttribute(f.app, kAXFocusedUIElementAttribute, f.created)
            #expect(await context.remove(proof).status == .removed)
            #expect(f.createPresses == 1 && f.deletePresses == 1)
        }
    }

    @Test(arguments: ["no_control_edge", "new_owner", "reordered_peers", "unread_owner"])
    func unknownOrChangedChildGraphOwnerCannotAcquireMenuCustody(change: String) async throws {
        try await owned {
            let f = Fixture(); f.useDistinctHeldMenuOwner(containsControl: change != "no_control_edge",
                heldBefore: change != "new_owner")
            f.alternateOwnerReordered = change == "reordered_peers"
            f.alternateOwnerUnread = change == "unread_owner"
            let context = try f.context(nativeControls: true)
            #expect(await context.create().status == .rejectedBeforeWrite)
            #expect(f.createPresses == 0 && f.deletePresses == 0)
            #expect(f.optionCancelPresses == 0 && f.editCancelPresses == 0)
        }
    }

    @Test func measuredAncestorParentAndDistinctInsertionOwnerSupportExactLifecycle() async throws {
        try await owned {
            let f = Fixture(); f.useNativeAncestorPopupParent()
            let context = try f.context(nativeControls: true)
            let receipt = await context.create()
            #expect(receipt.status == .created)
            let proof = try #require(receipt.inverse)
            f.selected = [f.created]; f.b.setAttribute(f.app, kAXFocusedUIElementAttribute, f.created)
            #expect(await context.remove(proof).status == .removed)
            #expect(f.createPresses == 1 && f.deletePresses == 1)
        }
    }

    @Test(arguments: ["wrong_ancestor", "sibling", "reparented", "replaced_intermediate", "intermediate_role", "ancestor_peers", "foreign_preexisting"])
    func unrelatedOrChangedAncestorPathNeverAcquiresPopupCustody(change: String) async throws {
        try await owned {
            let f = Fixture(); f.useNativeAncestorPopupParent()
            switch change {
            case "wrong_ancestor":
                let foreign = f.b.element(967_480); f.b.setRole(foreign, kAXGroupRole as String); f.b.setChildren(foreign, [])
                f.b.setChildren(f.window, f.b.makeAXRuntime().children(f.window) + [foreign])
                f.b.setAttribute(f.optionMenu, kAXParentAttribute, foreign)
            case "sibling": f.b.setAttribute(f.optionMenu, kAXParentAttribute, f.b.element(967_153))
            case "foreign_preexisting": f.parentOnlyMenuBeforePress = true
            default: f.afterOptionsChange = change
            }
            let context = try f.context(nativeControls: true)
            #expect(await context.create().status == .rejectedBeforeWrite)
            #expect(f.createPresses == 0 && f.deletePresses == 0)
            #expect(f.optionCancelPresses == 0 && f.editCancelPresses == 0)
        }
    }

    @Test func unobservedCreationRemainsPendingAndReconciliationNeverReissues() async throws {
        try await owned {
            let f = Fixture(delay: 100); let context = try f.context()
            let pending = await context.create()
            #expect(pending.status == .pending)
            #expect(pending.created == nil)
            f.delay = 0
            #expect(await context.create().status == .created)
            #expect(f.createPresses == 1)
        }
    }

    @Test func focusedCreatedStripDoesNotAuthorizeDeletingSeveralSelectedStrips() async throws {
        try await owned {
            let f = Fixture(); let context = try f.context()
            let receipt = await context.create()
            let proof = try #require(receipt.inverse)
            f.selected = [f.created, f.original[0]]
            f.b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.created)
            #expect(await context.remove(proof).status == .residual)
            #expect(f.deletePresses == 0)
            f.selected = [f.created]
            #expect(await context.remove(proof).status == .removed)
            #expect(f.deletePresses == 1)
        }
    }

    @Test func nativeFieldDiscoveryDoesNotRequireInjectedControlMap() async throws {
        try await owned {
            let f = Fixture(); let context = try f.context(nativeControls: true)
            let receipt = await context.create()
            #expect(receipt.status == .created)
            #expect(receipt.defaults == Fixture.defaults)
            #expect(receipt.inverse != nil)
            #expect(f.createPresses == 1)
        }
    }

    @Test func defaultMismatchRetainsCreatedButNeverIssuesInverse() async throws {
        try await owned {
            let f = Fixture()
            f.b.setAttribute(f.controls[.input]!, kAXDescriptionAttribute as String, "Bus 7")
            let context = try f.context()
            let receipt = await context.create()
            #expect(receipt.status == .configurationPartial)
            let created = try #require(receipt.created)
            #expect(CFEqual(created, f.created))
            #expect(receipt.inverse == nil)
            #expect(f.createPresses == 1)
            #expect(f.deletePresses == 0)
        }
    }

    @Test(arguments: [OwnedAuxLifecycle.Field.volume, .pan])
    func booleanSliderValueNeverAuthorizesOwnedInverse(field: OwnedAuxLifecycle.Field) async throws {
        try await owned {
            let f = Fixture()
            f.b.setAttribute(f.controls[field]!, kAXValueAttribute, NSNumber(value: false))
            let context = try f.context()
            let receipt = await context.create()
            #expect(receipt.status == .configurationPartial)
            let created = try #require(receipt.created)
            #expect(CFEqual(created, f.created))
            #expect(receipt.inverse == nil)
            #expect(f.createPresses == 1)
            #expect(f.deletePresses == 0)
        }
    }

    @Test func changedAuxFilterAfterCaptureRejectsCreator() async throws {
        try await owned {
            let f = Fixture(); let context = try f.context(nativeControls: true)
            f.b.setAttribute(f.auxFilter, kAXValueAttribute as String, 0)
            #expect(await context.create().status == .rejectedBeforeWrite)
            #expect(f.createPresses == 0)
        }
    }

    @Test func removalReceiptDoesNotTurnBackIntoCreatedOnReconciliation() async throws {
        try await owned {
            let f = Fixture(); let context = try f.context(nativeControls: true)
            let proof = try #require(await context.create().inverse)
            f.selected = [f.created]
            f.b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.created)
            #expect(await context.remove(proof).status == .removed)
            #expect(await context.create().status == .removed)
            #expect(await context.remove(proof).status == .removed)
            #expect(f.createPresses == 1)
            #expect(f.deletePresses == 1)
        }
    }

    @Test func selectionExpandedWhileOpeningEditRefusesDelete() async throws {
        try await owned {
            let f = Fixture(); let context = try f.context(nativeControls: true)
            let proof = try #require(await context.create().inverse)
            f.selected = [f.created]; f.expandSelectionOnEdit = true
            f.b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.created)
            #expect(await context.remove(proof).status == .residual)
            #expect(f.deletePresses == 0)
        }
    }

    @Test func detachedOptionsControlCannotAuthorizeCreation() async throws {
        try await owned {
            let f = Fixture(); let context = try f.context(nativeControls: true)
            let unrelated = f.b.element(967_300); f.b.setRole(unrelated, kAXGroupRole as String)
            f.b.setChildren(unrelated, [f.options])
            #expect(await context.create().status == .rejectedBeforeWrite)
            #expect(f.createPresses == 0)
        }
    }

    @Test func stripSelectionWithArrangeFocusDoesNotAuthorizeDelete() async throws {
        try await owned {
            let f = Fixture(); let context = try f.context(nativeControls: true)
            let proof = try #require(await context.create().inverse)
            f.selected = [f.created]
            #expect(await context.remove(proof).status == .residual)
            #expect(f.deletePresses == 0)
        }
    }

    @Test func replacedOriginalStripRefusesOwnedInverseEvenIfOldCFStillReads() async throws {
        try await owned {
            let f = Fixture(); let context = try f.context(nativeControls: true)
            let proof = try #require(await context.create().inverse)
            let replacement = f.b.element(967_098)
            f.b.setRole(replacement, kAXLayoutItemRole as String); f.b.setChildren(replacement, [])
            f.replaceOriginal = true; f.selected = [f.created]
            f.b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.created)
            #expect(await context.remove(proof).status == .residual)
            #expect(f.deletePresses == 0)
        }
    }

    @Test func delayedRemovalReconcilesWithoutSendingDeleteAgain() async throws {
        try await owned {
            let f = Fixture(); let context = try f.context(nativeControls: true)
            let proof = try #require(await context.create().inverse)
            f.selected = [f.created]; f.removalDelay = 100
            f.b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.created)
            #expect(await context.remove(proof).status == .residual)
            #expect(f.deletePresses == 1)
            f.removalDelay = 0
            #expect(await context.remove(proof).status == .removed)
            #expect(f.deletePresses == 1)
        }
    }

    @Test func rememberedCancellationAfterOptionsOpeningStopsCreator() async throws {
        let f = Fixture(); f.cancelOnOptions = true
        try await owned(f) {
            let context = try f.context(nativeControls: true)
            #expect(await context.create().status == .rejectedBeforeWrite)
            #expect(f.createPresses == 0)
        }
    }

    @Test func transientBaselineCensusWithLiveCreatedCFDoesNotCertifyRemoval() async throws {
        try await owned {
            let f = Fixture(); let context = try f.context(nativeControls: true)
            let proof = try #require(await context.create().inverse)
            f.selected = [f.created]; f.invalidatesDeletedCF = false
            f.b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.created)
            #expect(await context.remove(proof).status == .residual)
            #expect(f.deletePresses == 1)
            #expect(await context.remove(proof).status == .residual)
            #expect(f.deletePresses == 1)
            f.invalidatesDeletedCF = true
            #expect(await context.remove(proof).status == .removed)
            #expect(f.deletePresses == 1)
        }
    }

    @Test(arguments: MenuCase.allCases)
    func incompleteMenuCandidateCannotAuthorizeSemanticPress(scenario: MenuCase) async throws {
        let creator = scenario.creator; let field = scenario.field; let fault = scenario.fault
        try await owned {
            let f = Fixture(); let context = try f.context(nativeControls: true)
            if creator {
                f.addFaultedMenuCandidate(creator: true, field: field, fault: fault)
                #expect(await context.create().status == .rejectedBeforeWrite)
                #expect(f.createPresses == 0)
            } else {
                let proof = try #require(await context.create().inverse)
                f.selected = [f.created]; f.b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.created)
                f.addFaultedMenuCandidate(creator: false, field: field, fault: fault)
                #expect(await context.remove(proof).status == .residual)
                #expect(f.deletePresses == 0)
            }
        }
    }

    @Test func selectionChangedDuringFinalMenuFocusFootprintRefusesDelete() async throws {
        try await owned {
            let f = Fixture(); let context = try f.context(nativeControls: true)
            let proof = try #require(await context.create().inverse)
            f.selected = [f.created]; f.b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.created)
            f.focusMenuOnEdit = true; f.expandDuringFocusFootprint = true
            #expect(await context.remove(proof).status == .residual)
            #expect(f.focusReadAfterEdit)
            #expect(f.selected.count == 2)
            #expect(f.deletePresses == 0)
        }
    }

    @Test func partialCreatedObjectCannotBeReplacedAndAdoptedOnRetry() async throws {
        try await owned {
            let f = Fixture(); let context = try f.context(nativeControls: true)
            f.b.setAttribute(f.controls[.input]!, kAXDescriptionAttribute, "Bus 7")
            let partial = await context.create()
            #expect(partial.status == .configurationPartial)
            let first = try #require(partial.created); #expect(CFEqual(first, f.created))
            let other = f.b.element(967_360); f.b.setRole(other, kAXLayoutItemRole as String)
            f.b.setChildren(other, f.b.makeAXRuntime().children(f.created))
            f.b.setAttribute(f.controls[.input]!, kAXDescriptionAttribute, "Input 1-2")
            f.replacementCreated = other
            let retry = await context.create()
            #expect(retry.status == .residual)
            let retained = try #require(retry.created); #expect(CFEqual(retained, first))
            #expect(retry.inverse == nil)
            if let unsafe = retry.inverse {
                f.selected = [other]; f.b.setAttribute(f.app, kAXFocusedUIElementAttribute, other)
                _ = await context.remove(unsafe)
            }
            #expect(f.deletePresses == 0)
            #expect(f.createPresses == 1)
        }
    }

    @Test(arguments: LateMoment.allCases, LateLoss.allCases)
    func lateContextLossAfterPreservationStopsNewActions(moment: LateMoment, loss: LateLoss) async throws {
        let f = Fixture(); f.lateMoment = moment; f.lateLoss = loss
        try await owned(f) {
            let context = try f.context(nativeControls: true)
            #expect(await context.create().status == .rejectedBeforeWrite)
            #expect(f.lateFaultDelivered)
            #expect(f.createPresses == 0)
            if moment == .beforeOptions { #expect(f.optionPresses == 0) }
        }
    }

    @Test(arguments: ChildStatus.allCases)
    func footprintAcceptsOnlyDefinitiveNativeChildAbsence(status: ChildStatus) async throws {
        try await owned {
            let f = Fixture(); f.footprintChildStatus = status
            let context = try f.context(nativeControls: true)
            let created = await context.create()
            #expect(f.footprintChildReads > 0)
            if status.definitiveAbsence {
                #expect(created.status == .created)
                let proof = try #require(created.inverse)
                #expect(f.createPresses == 1)
                f.selected = [f.created]; f.b.setAttribute(f.app, kAXFocusedUIElementAttribute, f.created)
                #expect(await context.remove(proof).status == .removed)
                #expect(f.deletePresses == 1)
            } else {
                #expect(created.status == .rejectedBeforeWrite)
                #expect(created.inverse == nil)
                #expect(f.createPresses == 0)
                #expect(f.optionPresses == 0)
            }
        }
    }

    @Test func optionalOpaqueSubroleFailureIsNotALifecyclePreservationRequirement() async throws {
        try await owned {
            let f = Fixture(); f.optionalSubroleFault = true
            let context = try f.context(nativeControls: true)
            let created = await context.create()
            #expect(created.status == .created)
            let proof = try #require(created.inverse)
            #expect(f.optionalSubroleFaultReads == 0)
            #expect(f.createPresses == 1)
            f.selected = [f.created]; f.b.setAttribute(f.app, kAXFocusedUIElementAttribute, f.created)
            #expect(await context.remove(proof).status == .removed)
            #expect(f.deletePresses == 1)
            #expect(f.optionalSubroleFaultReads == 0)
        }
    }

    @Test(arguments: ["routing", "plugin", "automation", "unrequested", "unread_value"])
    func relevantOriginalControlChangesStillRefuseOwnedInverse(change: String) async throws {
        try await owned {
            let f = Fixture()
            let routing = f.b.element(967_401), plugin = f.b.element(967_402)
            let automation = f.b.element(967_403), unrequested = f.b.element(967_404)
            f.b.setRole(routing, kAXButtonRole as String); f.b.setAttribute(routing, kAXDescriptionAttribute, "Stereo Output")
            f.b.setRole(plugin, kAXButtonRole as String); f.b.setAttribute(plugin, kAXValueAttribute, "Compressor")
            f.b.setRole(automation, kAXGroupRole as String); f.b.setAttribute(automation, kAXDescriptionAttribute, "Read, automation enabled")
            f.b.setRole(unrequested, kAXCheckBoxRole as String); f.b.setAttribute(unrequested, kAXValueAttribute, 0)
            for control in [routing, plugin, automation, unrequested] { f.b.setChildren(control, []) }
            f.b.setChildren(f.original[0], [routing, plugin, automation, unrequested])
            let context = try f.context(nativeControls: true)
            let proof = try #require(await context.create().inverse)
            f.selected = [f.created]; f.b.setAttribute(f.app, kAXFocusedUIElementAttribute, f.created)
            switch change {
            case "routing": f.b.setAttribute(routing, kAXDescriptionAttribute, "Bus 7")
            case "plugin": f.b.setAttribute(plugin, kAXValueAttribute, "Limiter")
            case "automation": f.b.setAttribute(automation, kAXDescriptionAttribute, "Write, automation enabled")
            case "unrequested": f.b.setAttribute(unrequested, kAXValueAttribute, 1)
            default: f.unreadPreservedValue = plugin
            }
            #expect(await context.remove(proof).status == .residual)
            #expect(f.deletePresses == 0)
            #expect(f.createPresses == 1)
        }
    }

    @Test(arguments: [kAXScrollAreaRole as String, kAXLayoutAreaRole as String], ScrollMetadata.allCases)
    func structuralScrollMetadataIsNotMusicalState(role: String, metadata: ScrollMetadata) async throws {
        try await owned {
            let f = Fixture(); _ = f.addStructuralScroll(role: role); f.scrollMetadataFault = metadata
            if role == kAXLayoutAreaRole as String { f.scrollMetadataError = .init(raw: AXError.illegalArgument.rawValue) }
            let context = try f.context(nativeControls: true)
            let created = await context.create()
            #expect(created.status == .created)
            let proof = try #require(created.inverse)
            #expect(f.scrollMetadataFaultReads == 0)
            #expect(f.createPresses == 1)
            f.selected = [f.created]; f.b.setAttribute(f.app, kAXFocusedUIElementAttribute, f.created)
            #expect(await context.remove(proof).status == .removed)
            #expect(f.deletePresses == 1)
            #expect(f.scrollMetadataFaultReads == 0)
        }
    }

    @Test(arguments: [kAXScrollAreaRole as String, kAXLayoutAreaRole as String],
          ["child_replaced", "children_unread", "viewport_changed", "viewport_unread", "role_changed", "protected_description_unread"])
    func structuralScrollScopeRetainsIdentityViewportAndProtectedControls(role: String, change: String) async throws {
        try await owned {
            let f = Fixture(); let view = f.addStructuralScroll(role: role)
            let protectedOutput = f.b.element(967_452)
            f.b.setRole(protectedOutput, kAXButtonRole as String)
            f.b.setAttribute(protectedOutput, kAXDescriptionAttribute, "Stereo Output")
            f.b.setChildren(protectedOutput, []); f.b.setChildren(f.original[0], [protectedOutput])
            let context = try f.context(nativeControls: true)
            let proof = try #require(await context.create().inverse)
            f.selected = [f.created]; f.b.setAttribute(f.app, kAXFocusedUIElementAttribute, f.created)
            switch change {
            case "child_replaced":
                let replacement = f.b.element(967_453)
                f.b.setRole(replacement, kAXScrollBarRole as String); f.b.setAttribute(replacement, kAXValueAttribute, 0.25)
                f.b.setChildren(replacement, []); f.b.setChildren(view.scroll, [replacement])
            case "children_unread": f.unreadScrollChildren = true
            case "viewport_changed": f.b.setAttribute(view.viewport, kAXValueAttribute, 0.75)
            case "viewport_unread": f.unreadPreservedValue = view.viewport
            case "role_changed": f.b.setRole(view.scroll, kAXGroupRole as String)
            default: f.unreadPreservedDescription = protectedOutput
            }
            #expect(await context.remove(proof).status == .residual)
            #expect(f.deletePresses == 0)
            #expect(f.createPresses == 1)
        }
    }
}
