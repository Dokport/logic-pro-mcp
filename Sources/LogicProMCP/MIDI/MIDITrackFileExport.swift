import Foundation
import Darwin

/// Shared file flow for a native whole-project MIDI export and a target-only
/// artifact/read. Native acquisition supplies completeness and held-object
/// continuity; file names alone never supply that authority. Not a public API.
@MainActor
enum MIDITrackFileExport {
    struct Track: Equatable, Sendable {
        let reference: String?
        let name: String
    }

    struct Observation: Equatable, Sendable {
        let projectReference: String?
        let projectPath: String?
        let coverage: SessionPopulationObservation.Coverage
        let tracks: [Track]
    }

    struct Runtime {
        var observe: @MainActor () async throws -> Observation
        /// Checks the actual retained native window/headers, not just row text.
        var stillCurrent: @MainActor (Observation) async -> Bool
        /// Writes only to the new process-owned private destination. It must
        /// throw on cancellation or an unresolved export dialog, never retry.
        var exportAll: @MainActor (URL, String) async throws -> Void
    }

    enum Failure: Error, Equatable {
        case invalidDestination, destinationExists, unboundProject
        case incompleteTrackPopulation, ambiguousTarget, staleTarget
        case exportCancelled, unreadableArtifact
    }

    struct Result {
        let document: SMFReader.Document
    }

    static func run(projectReference: String, targetReference: String, destination: String?,
                    runtime: Runtime) async throws -> Result {
        let output = try destination.map(validateDestination)
        let before = try await runtime.observe()
        let name = try boundName(before, projectReference: projectReference, targetReference: targetReference)
        guard await runtime.stillCurrent(before) else { throw Failure.staleTarget }
        try Task.checkCancellation()

        let temporary = try ExportTemporaryFiles.temporaryExportFile()
        defer { ExportTemporaryFiles.cleanupTemporaryExportFile(temporary) }
        guard let projectPath = before.projectPath else { throw Failure.unboundProject }
        try await runtime.exportAll(temporary.fileURL, projectPath)
        try Task.checkCancellation()
        guard await runtime.stillCurrent(before) else { throw Failure.staleTarget }

        let after = try await runtime.observe()
        _ = try boundName(after, projectReference: projectReference, targetReference: targetReference)
        guard before == after, await runtime.stillCurrent(before), await runtime.stillCurrent(after) else {
            throw Failure.staleTarget
        }
        try Task.checkCancellation()
        let exported = try readRegularArtifact(temporary.fileURL)
        let selected = try SMFReader.extractTracks(namedInstrument: name, from: exported)
        let document = try SMFReader.parseDocument(selected)
        // The output is copied from the validated private artifact, not handed
        // to the native Save panel. A raced file or symlink is never replaced.
        try Task.checkCancellation()
        if let output { try selected.write(to: output, options: .withoutOverwriting) }
        return Result(document: document)
    }

    private static func readRegularArtifact(_ url: URL) throws -> Data {
        // Bind the read to the opened regular file; a metadata check followed
        // by Data(contentsOf:) would still follow a raced symlink.
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw Failure.unreadableArtifact }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw Failure.unreadableArtifact
        }
        do { return try handle.readToEnd() ?? Data() }
        catch { throw Failure.unreadableArtifact }
    }

    private static func boundName(_ observation: Observation, projectReference: String,
                                  targetReference: String) throws -> String {
        guard !projectReference.isEmpty, observation.projectReference == projectReference,
              let path = observation.projectPath, path.hasPrefix("/"), !path.contains("\0") else {
            throw Failure.unboundProject
        }
        guard observation.coverage == .complete else { throw Failure.incompleteTrackPopulation }
        let matches = observation.tracks.filter { $0.reference == targetReference }
        guard !targetReference.isEmpty, matches.count == 1, let target = matches.first,
              !target.name.isEmpty else { throw Failure.staleTarget }
        guard observation.tracks.filter({ $0.name.utf8.elementsEqual(target.name.utf8) }).count == 1 else {
            throw Failure.ambiguousTarget
        }
        return target.name
    }

    private static func validateDestination(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw Failure.invalidDestination }
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension.lowercased() == "mid" else { throw Failure.invalidDestination }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &directory),
              directory.boolValue else { throw Failure.invalidDestination }
        do {
            _ = try FileManager.default.attributesOfItem(atPath: path)
            throw Failure.destinationExists
        } catch let error as Failure { throw error }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { }
        catch { throw Failure.invalidDestination }
        return url
    }
}
