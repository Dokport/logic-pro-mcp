@preconcurrency import ApplicationServices
import Foundation

/// Connects the existing request-owned population reader to the shared file
/// flow. The capture's physical bindings are mandatory; wire rows cannot
/// recreate them. One instance of this runtime belongs to one operation.
@MainActor
enum MIDITrackExportProvider {
    private final class Session {
        var baseline: MIDITrackFileExport.Observation?
        var hold: MIDITrackNativeHold?
        var binding: AXTrackBinding.Binding?
        var exported = false
        var ended = false
    }

    static func makeRuntime(
        projectReference: String,
        acquire: @escaping @MainActor (SessionPopulationObservation.Request) async throws -> SessionPopulationObservation.Capture,
        nativeRuntime: AXLogicProElements.Runtime = .production
    ) -> MIDITrackFileExport.Runtime {
        let session = Session()
        let request = SessionPopulationObservation.Request(scope: .wholeProject, domains: [.tracks],
            allowUINavigation: false, projectRef: projectReference)
        return .init(observe: {
            do {
                try SessionPopulationObservation.requireOwnedAcquisition()
                guard !session.ended else { throw MIDITrackFileExport.Failure.staleTarget }
                let capture = try await acquire(request)
                try SessionPopulationObservation.requireOwnedAcquisition()
                let report = SessionPopulationObservation.build(request: request, capture: capture)
                guard capture.requestedProjectMatches == true, report.project.status == .issued,
                      report.project.projectRef == projectReference else { throw MIDITrackFileExport.Failure.unboundProject }
                guard capture.freshPopulation?.stable == true, report.tracks.coverage == .complete,
                      report.tracks.rows.count == capture.tracks.count else {
                    throw MIDITrackFileExport.Failure.incompleteTrackPopulation
                }
                let observation = MIDITrackFileExport.Observation(projectReference: report.project.projectRef,
                    projectPath: report.project.filePath, coverage: report.tracks.coverage,
                    tracks: report.tracks.rows.map { .init(reference: $0.trackRef, name: $0.name) })
                let bindings = capture.tracks.compactMap(\.physicalBinding)
                guard bindings.count == capture.tracks.count,
                      let candidate = MIDITrackNativeHold(observation: observation, bindings: bindings, runtime: nativeRuntime) else {
                    throw MIDITrackFileExport.Failure.staleTarget
                }
                if let baseline = session.baseline {
                    guard baseline == observation, session.hold?.isCurrent() == true else {
                        throw MIDITrackFileExport.Failure.staleTarget
                    }
                } else {
                    session.baseline = observation; session.hold = candidate; session.binding = bindings.first
                }
                return observation
            } catch { session.ended = true; throw error }
        }, stillCurrent: { observation in
            guard !session.ended, session.baseline == observation, session.hold?.isCurrent() == true else {
                session.ended = true
                return false
            }
            return true
        }, exportAll: { destination, projectPath in
            try SessionPopulationObservation.requireOwnedAcquisition()
            guard !session.ended, !session.exported, let binding = session.binding,
                  session.baseline?.projectPath == projectPath, session.hold?.isCurrent() == true else {
                throw MIDITrackFileExport.Failure.staleTarget
            }
            session.exported = true
            let panel = MIDITrackExportPanel(window: binding.window, document: binding.document,
                runtime: nativeRuntime, permittingAction: {
                    (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil
                })
            do { try await panel.exportAll(to: destination) }
            catch { session.ended = true; throw error }
        })
    }
}
