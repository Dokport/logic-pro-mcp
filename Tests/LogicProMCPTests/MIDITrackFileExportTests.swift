import Foundation
import Testing
@testable import LogicProMCP

@MainActor
private final class MIDIFileExportFixture {
    var observations = 0
    var exports = 0
    var exportedURL: URL?
    var fault = ""
    var raceDestination: URL?
    var artifactSymlinkSource: URL?
    let bytes: Data

    init() {
        func chunk(_ owner: String?, pitch: UInt8?) -> [UInt8] {
            var events: [UInt8] = []
            if let owner {
                events += [0, 0xFF, 4, UInt8(owner.utf8.count)] + owner.utf8
            }
            if let pitch { events += [0, 0x90, pitch, 100, 1, 0x80, pitch, 0] }
            events += [0, 0xFF, 0x2F, 0]
            return [0x4D, 0x54, 0x72, 0x6B, 0, 0, 0, UInt8(events.count)] + events
        }
        let header: [UInt8] = [0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 1, 0, 3, 1, 0xE0]
        bytes = Data(header + chunk(nil, pitch: nil) + chunk("Target", pitch: 60) + chunk("Peer", pitch: 72))
    }

    var runtime: MIDITrackFileExport.Runtime {
        .init(observe: {
            self.observations += 1
            if self.fault == "cancel_after_read" && self.observations == 2 {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            var rows = [MIDITrackFileExport.Track(reference: "trk_target", name: "Target"),
                        .init(reference: "trk_peer", name: "Peer")]
            if self.fault == "duplicate_name" { rows[1] = .init(reference: "trk_peer", name: "Target") }
            if self.fault == "changed_target" && self.observations > 1 {
                rows[0] = .init(reference: "trk_replacement", name: "Target")
            }
            return .init(projectReference: self.fault == "wrong_project" ? "prj_other" : "prj_current",
                projectPath: "/fixture.logicx", coverage: self.fault == "partial" ? .partial : .complete,
                tracks: rows)
        }, stillCurrent: { _ in self.fault != "custody_lost" || self.exports == 0 }, exportAll: { url, _ in
            self.exports += 1
            self.exportedURL = url
            if let source = self.artifactSymlinkSource {
                try FileManager.default.createSymbolicLink(at: url, withDestinationURL: source)
                return
            }
            if let destination = self.raceDestination {
                try Data([0xCE, 0xFA]).write(to: destination, options: .withoutOverwriting)
            }
            if self.fault == "cancel" { throw MIDITrackFileExport.Failure.exportCancelled }
            if self.fault != "no_artifact" {
                try (self.fault == "bad_artifact" ? Data([1, 2, 3]) : self.bytes).write(to: url, options: .withoutOverwriting)
            }
        })
    }
}

@MainActor @Test func midiTrackFileReadReusesExportAndCleansOnlyItsManagedTemporaryFile() async throws {
    let fixture = MIDIFileExportFixture()
    let result = try await MIDITrackFileExport.run(projectReference: "prj_current", targetReference: "trk_target",
        destination: nil, runtime: fixture.runtime)
    #expect(fixture.exports == 1 && fixture.observations == 2)
    #expect(result.document.notes.map(\.pitch) == [60])
    #expect(result.document.ticksPerQuarter == 480 && result.document.trackCount == 2)
    let temporary = try #require(fixture.exportedURL)
    #expect(!FileManager.default.fileExists(atPath: temporary.deletingLastPathComponent().path))
}

@Test func midiTrackFileReadCanReturnToANonUIActorCaller() async throws {
    let fixture = await MIDIFileExportFixture()
    let runtime = await fixture.runtime
    let result = try await MIDITrackFileExport.run(projectReference: "prj_current", targetReference: "trk_target",
        destination: nil, runtime: runtime)
    #expect(result.document.notes.map(\.pitch) == [60])
}

@MainActor @Test func midiTrackFileExportPublishesOnlyTheBoundTrackWithoutReplacingFiles() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("target.mid").path
    let fixture = MIDIFileExportFixture()
    _ = try await MIDITrackFileExport.run(projectReference: "prj_current", targetReference: "trk_target",
        destination: path, runtime: fixture.runtime)
    #expect(try SMFReader.parseDocument(Data(contentsOf: URL(fileURLWithPath: path))).notes.map(\.pitch) == [60])
    let preserved = try Data(contentsOf: URL(fileURLWithPath: path))
    do {
        _ = try await MIDITrackFileExport.run(projectReference: "prj_current", targetReference: "trk_target",
            destination: path, runtime: fixture.runtime)
        Issue.record("An existing destination was replaced")
    } catch { #expect(error as? MIDITrackFileExport.Failure == .destinationExists) }
    #expect(fixture.exports == 1)
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == preserved)
}

@MainActor @Test(arguments: ["wrong_project", "partial", "duplicate_name", "changed_target", "custody_lost", "cancel", "no_artifact", "bad_artifact"])
func midiTrackFileExportRefusesIdentityAndArtifactFailuresWithoutPublishing(fault: String) async throws {
    let fixture = MIDIFileExportFixture()
    fixture.fault = fault
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("must-not-exist.mid").path
    await #expect(throws: (any Error).self) {
        try await MIDITrackFileExport.run(projectReference: "prj_current", targetReference: "trk_target",
            destination: output, runtime: fixture.runtime)
    }
    #expect(!FileManager.default.fileExists(atPath: output))
    #expect(fixture.exports == (["wrong_project", "partial", "duplicate_name"].contains(fault) ? 0 : 1))
    if let temporary = fixture.exportedURL {
        #expect(!FileManager.default.fileExists(atPath: temporary.deletingLastPathComponent().path))
    }
}

@MainActor @Test(arguments: ["relative.mid", "/missing-parent/target.mid", "/fixture.txt"])
func midiTrackFileExportRefusesInvalidPathsBeforeReadingLogic(path: String) async {
    let fixture = MIDIFileExportFixture()
    await #expect(throws: (any Error).self) {
        try await MIDITrackFileExport.run(projectReference: "prj_current", targetReference: "trk_target",
            destination: path, runtime: fixture.runtime)
    }
    #expect(fixture.observations == 0 && fixture.exports == 0)
}

@MainActor @Test func midiTrackFileExportDoesNotOverwriteADestinationCreatedDuringNativeExport() async throws {
    let fixture = MIDIFileExportFixture()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("raced.mid")
    fixture.raceDestination = output
    await #expect(throws: (any Error).self) {
        try await MIDITrackFileExport.run(projectReference: "prj_current", targetReference: "trk_target",
            destination: output.path, runtime: fixture.runtime)
    }
    #expect(try Data(contentsOf: output) == Data([0xCE, 0xFA]))
}

@MainActor @Test func midiTrackFileExportStopsCancellationDuringTheFinalObservation() async throws {
    let fixture = MIDIFileExportFixture()
    fixture.fault = "cancel_after_read"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("cancelled.mid")
    let result = await Task { @MainActor in
        try await MIDITrackFileExport.run(projectReference: "prj_current", targetReference: "trk_target",
            destination: output.path, runtime: fixture.runtime)
    }.result
    switch result {
    case .success: Issue.record("Cancelled final observation still published an artifact")
    case .failure(let error): #expect(error is CancellationError)
    }
    #expect(!FileManager.default.fileExists(atPath: output.path))
    let temporary = try #require(fixture.exportedURL)
    #expect(!FileManager.default.fileExists(atPath: temporary.deletingLastPathComponent().path))
}

@MainActor @Test func midiTrackFileExportRefusesASymlinkArtifactAndLeavesItsTargetUntouched() async throws {
    let fixture = MIDIFileExportFixture()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let unrelated = directory.appendingPathComponent("unrelated.mid")
    try fixture.bytes.write(to: unrelated, options: .withoutOverwriting)
    fixture.artifactSymlinkSource = unrelated
    let output = directory.appendingPathComponent("must-not-exist.mid")
    await #expect(throws: (any Error).self) {
        try await MIDITrackFileExport.run(projectReference: "prj_current", targetReference: "trk_target",
            destination: output.path, runtime: fixture.runtime)
    }
    #expect(!FileManager.default.fileExists(atPath: output.path))
    #expect(try Data(contentsOf: unrelated) == fixture.bytes)
}
