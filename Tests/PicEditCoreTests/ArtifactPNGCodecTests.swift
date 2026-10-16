import CoreGraphics
import Foundation
import Testing
@testable import PicEditCore

private actor BlockingArtifactResources: ArtifactResourceAdmitting {
    let base: ArtifactResourceOwner
    private var first = true
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var blocked = false
    init() throws { base = ArtifactResourceOwner(limits: try .init()) }
    func acquire(kind: ArtifactAdmissionKind, bytes: Int64, priority: ArtifactResourcePriority,
                 retaining: [ArtifactMemoryReservation]) async throws -> ArtifactResourceLease {
        if kind == .codec && first {
            first = false; blocked = true
            await withCheckedContinuation { waiter = $0 }
        }
        return try await base.acquire(kind: kind, bytes: bytes, priority: priority, retaining: retaining)
    }
    func retain(bytes: Int64, from lease: ArtifactResourceLease) async throws -> ArtifactMemoryReservation { try await base.retain(bytes: bytes, from: lease) }
    func validate(_ memory: ArtifactMemoryReservation, minimumBytes: Int64) async throws { try await base.validate(memory, minimumBytes: minimumBytes) }
    func release() { waiter?.resume(); waiter = nil }
}
private actor ArtifactCompletionFlag { private(set) var done = false; func finish() { done = true } }
struct ArtifactPNGCodecTests {
    private func wait(_ predicate: @escaping @Sendable () async -> Bool) async -> Bool {
        let until = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < until { if await predicate() { return true }; await Task.yield() }; return false
    }
    @Test func overBudgetRejectsBeforeEncodingAndPreservesOriginal() async throws {
        let fixture = try ArtifactTestFixture(); defer { fixture.remove() }
        let resources = ArtifactResourceOwner(limits: try .init(maximumBytes: 1_024))
        let store = try await GeneratedArtifactStore.open(in: fixture.directory, resources: resources)
        let image = fixture.image(); let original = fixture.directory.appendingPathComponent("original.bin")
        let before = try Data(contentsOf: original)
        await #expect(throws: ArtifactResourceError.capacityExceeded) {
            _ = try await store.stageRaster(.init(immutableImage: image), provenance: fixture.provenance(image), masks: [])
        }
        #expect(try Data(contentsOf: original) == before)
        #expect(await resources.state().runningCodecs == 0)
    }
    @Test func queuedInputsStayChargedAndCancelledWaiterReturnsPromptly() async throws {
        let fixture = try ArtifactTestFixture(); defer { fixture.remove() }
        let resources = try BlockingArtifactResources()
        let store = try await GeneratedArtifactStore.open(in: fixture.directory, resources: resources)
        let image = fixture.image(); let provenance = try fixture.provenance(image)
        let first = Task { try await store.stageRaster(.init(immutableImage: image), provenance: provenance, masks: []) }
        guard await wait({ await resources.blocked }) else {
            await resources.release(); first.cancel(); _ = await first.result
            Issue.record("First codec did not reach the controlled resource boundary"); return
        }
        let before = await resources.base.state().chargedBytes
        let flag = ArtifactCompletionFlag()
        let queued = Task {
            do { let result = try await store.stageRaster(.init(immutableImage: image), provenance: provenance, masks: []); await flag.finish(); return result }
            catch { await flag.finish(); throw error }
        }
        let inputBytes = Int64(image.bytesPerRow * image.height)
        let charged = await wait { await resources.base.state().chargedBytes >= before + inputBytes }
        #expect(charged, "Queued image owns its real input reservation")
        queued.cancel()
        let promptly = await wait { await flag.done }
        #expect(promptly, "Cancel removes only its queued observer without waiting for the first codec")
        await resources.release()
        _ = try await first.value
        await #expect(throws: CancellationError.self) { _ = try await queued.value }
    }
    @Test func wrongOwnerMemoryReservationIsRejected() async throws {
        let fixture = try ArtifactTestFixture(); defer { fixture.remove() }
        let image = fixture.image(); let foreign = ArtifactResourceOwner(limits: try .init())
        let lease = try await foreign.acquire(kind: .retainedMemory, bytes: 24, priority: .interactive, retaining: [])
        let memory = try await foreign.retain(bytes: 24, from: lease)
        let store = try await fixture.store()
        await #expect(throws: ArtifactResourceError.invalidOwnership) {
            _ = try await store.stageRaster(.init(immutableImage: image, memoryOwnership: memory), provenance: fixture.provenance(image), masks: [])
        }
    }
}

extension ArtifactPNGCodecTests {
    @Test func sharedMemoryCapMustCoverDistinctImagesButMayShareOneImage() async throws {
        let fixture = try ArtifactTestFixture(); defer { fixture.remove() }
        let store = try await fixture.store(); let image = fixture.image()
        let first = fixture.image(alpha: false, gray: true)
        let second = fixture.image(alpha: false, gray: true)
        let bytes = Int64(first.bytesPerRow * first.height)
        let operation = try await fixture.resources.acquire(kind: .retainedMemory, bytes: bytes, priority: .interactive, retaining: [])
        let memory = try await fixture.resources.retain(bytes: bytes, from: operation)
        let ids = [ArtifactResourceID(), ArtifactResourceID()]
        let provenance = try fixture.provenance(image, masks: ids)
        await #expect(throws: ArtifactResourceError.invalidOwnership) {
            _ = try await store.stageRaster(.init(immutableImage: image), provenance: provenance, masks: [
                .init(id: ids[0], coordinateSpace: .inputCanvas, immutableImage: first, memoryOwnership: memory),
                .init(id: ids[1], coordinateSpace: .inputCanvas, immutableImage: second, memoryOwnership: memory)
            ])
        }
        let draft = try await store.stageRaster(.init(immutableImage: image), provenance: provenance, masks: [
            .init(id: ids[0], coordinateSpace: .inputCanvas, immutableImage: first, memoryOwnership: memory),
            .init(id: ids[1], coordinateSpace: .inputCanvas, immutableImage: first, memoryOwnership: memory)
        ])
        #expect(draft.artifact.resources.count == 2)
        withExtendedLifetime(operation) {}
    }
}

private actor RecordingArtifactResources: ArtifactResourceAdmitting {
    let base: ArtifactResourceOwner
    private(set) var memoryRequests: [Int64] = []
    init() throws { base = ArtifactResourceOwner(limits: try .init()) }
    func acquire(kind: ArtifactAdmissionKind, bytes: Int64, priority: ArtifactResourcePriority,
                 retaining: [ArtifactMemoryReservation]) async throws -> ArtifactResourceLease {
        if kind == .retainedMemory { memoryRequests.append(bytes) }
        return try await base.acquire(kind: kind, bytes: bytes, priority: priority, retaining: retaining)
    }
    func retain(bytes: Int64, from lease: ArtifactResourceLease) async throws -> ArtifactMemoryReservation { try await base.retain(bytes: bytes, from: lease) }
    func validate(_ memory: ArtifactMemoryReservation, minimumBytes: Int64) async throws { try await base.validate(memory, minimumBytes: minimumBytes) }
}
extension ArtifactPNGCodecTests {
    @Test func rgbValidationChargesActualNativeRowsIncludingSkipLanes() async throws {
        let fixture = try ArtifactTestFixture(); defer { fixture.remove() }
        let store = try await fixture.store(); let image = fixture.image(alpha: false)
        let draft = try await store.stageRaster(.init(immutableImage: image), provenance: fixture.provenance(image), masks: [])
        _ = try await store.publish(draft, commitID: .init())
        let directory = try ArtifactFileIO.root(fixture.directory.appendingPathComponent("GeneratedArtifacts/\(draft.artifact.id.canonicalString)"), create: false)
        let file = try ArtifactFileIO.openFile(directory, "raster.png")
        let decoded = try ArtifactPNGCodec.decode(file)
        let actualRows = Int64(decoded.bytesPerRow * decoded.height)
        // Existing native evidence is RGB8 -> noneSkipLast32. The reservation
        // must follow the actual ImageIO row size, regardless of that layout.
        let resources = try RecordingArtifactResources()
        try await ArtifactPNGCodec.validate(file, raster: draft.artifact.raster, resources: resources)
        let requests = await resources.memoryRequests
        #expect(requests.count == 1)
        #expect((requests.first ?? 0) >= actualRows * 2 + 4_259_840)
    }
}
