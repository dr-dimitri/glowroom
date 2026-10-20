import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

// Selection changes share AppKit's application focus state.
@Suite("Library multiple selection", .serialized)
@MainActor
final class LibrarySelectionTests {
    private let root: URL
    private let repository: CatalogRepository

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-Selection-\(UUID().uuidString)")
        repository = CatalogRepository(directory: root.appendingPathComponent("Catalog"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @Test
    func plainClickReplacesSelectionAndCommandClickTogglesMembership() async throws {
        let (model, photos) = try await fixture()
        model.select(photos[1])
        model.select(photos[4], toggling: true)
        #expect(model.selectedIDs == [photos[1].id, photos[4].id])
        #expect(model.selectedID == photos[4].id)

        model.select(photos[1], toggling: true)
        #expect(model.selectedIDs == [photos[4].id])
        #expect(model.selectedID == photos[4].id)

        model.select(photos[2], toggling: true)
        model.select(photos[0])
        #expect(model.selectedIDs == [photos[0].id])
        #expect(model.selectedAsset?.id == photos[0].id)
    }

    @Test
    func removingActiveImageUsesFirstRemainingVisibleSelection() async throws {
        let (model, photos) = try await fixture()
        model.select(photos[4])
        model.select(photos[1], toggling: true)
        model.select(photos[3], toggling: true)
        model.select(photos[3], toggling: true)
        #expect(model.selectedIDs == [photos[1].id, photos[4].id])
        #expect(model.selectedID == photos[1].id)
    }

    @Test
    func commandClickCanClearTheLastImageWithoutAutomaticReselection() async throws {
        let (model, photos) = try await fixture()
        model.select(photos[0])
        model.showsDetail = true
        model.select(photos[0], toggling: true)
        #expect(model.selectedIDs.isEmpty)
        #expect(model.selectedID == nil)
        #expect(model.selectedAssets.isEmpty)
        #expect(!model.showsDetail, "Clearing the last filmstrip selection must return to the grid")
        model.reconcileSelection()

        // Recomputing an unchanged view must retain an intentional empty selection.
        model.sort = .name
        await model.waitForProjection()
        #expect(model.selectedIDs.isEmpty)
        #expect(model.selectedAsset == nil)

        model.search = "bravo"
        await model.waitForProjection()
        #expect(model.selectedIDs == [photos[1].id])
        #expect(model.selectedID == photos[1].id)
    }

    @Test
    func shiftClickKeepsItsAnchorWhileGrowingShrinkingAndReversingTheRange() async throws {
        let (model, photos) = try await fixture()
        model.select(photos[1])
        model.select(photos[4], extending: true)
        #expect(model.selectedIDs == Set(photos[1...4].map(\.id)))
        #expect(model.selectedID == photos[4].id)

        model.select(photos[2], extending: true)
        #expect(model.selectedIDs == Set(photos[1...2].map(\.id)))
        #expect(model.selectedID == photos[2].id)

        model.select(photos[0], extending: true)
        #expect(model.selectedIDs == Set(photos[0...1].map(\.id)))
        #expect(model.selectedID == photos[0].id)
    }

    @Test
    func commandShiftClickAddsTheAnchoredRangeToSeparateSelections() async throws {
        let (model, photos) = try await fixture()
        model.select(photos[0])
        model.select(photos[5], toggling: true)
        model.select(photos[3], extending: true, toggling: true)
        #expect(model.selectedIDs == Set([photos[0].id] + photos[3...5].map(\.id)))
        #expect(model.selectedID == photos[3].id)
    }

    @Test
    func navigationReplacesMultipleSelectionAndShiftNavigationExtendsFromItsAnchor() async throws {
        let (model, photos) = try await fixture()
        model.select(photos[0])
        model.select(photos[4], toggling: true)
        model.navigate(-1)
        #expect(model.selectedIDs == [photos[3].id])
        #expect(model.selectedID == photos[3].id)

        model.navigate(-1, extending: true)
        model.navigate(-1, extending: true)
        #expect(model.selectedIDs == Set(photos[1...3].map(\.id)))
        #expect(model.selectedID == photos[1].id)

        model.navigate(1, extending: true)
        #expect(model.selectedIDs == Set(photos[2...3].map(\.id)))
        #expect(model.selectedID == photos[2].id)
    }

    @Test
    func navigationClampsAtViewBoundariesAndStartsAtFirstImageAfterDeselection() async throws {
        let (model, photos) = try await fixture()
        model.select(photos[0])
        model.navigate(-1, extending: true)
        #expect(model.selectedIDs == [photos[0].id])
        #expect(model.selectedID == photos[0].id)

        model.select(photos[5])
        model.navigate(4)
        #expect(model.selectedIDs == [photos[5].id])
        model.select(photos[5], toggling: true)
        model.navigate(-1)
        #expect(model.selectedIDs == [photos[0].id])
        #expect(model.selectedID == photos[0].id)

        model.select(photos[0], toggling: true)
        model.navigate(3, extending: true)
        #expect(model.selectedIDs == [photos[0].id])
    }

    @Test
    func selectAllUsesOnlyVisiblePhotosAndExportOrderFollowsTheView() async throws {
        let (model, photos) = try await fixture()
        model.select(photos[3])
        model.select(photos[0], toggling: true)
        model.select(photos[2], toggling: true)
        #expect(model.selectedAssets.map(\.id) == [photos[0].id, photos[2].id, photos[3].id])

        model.sort = .rating
        await model.waitForProjection()
        #expect(model.selectedAssets.map(\.id) == [photos[3].id, photos[2].id, photos[0].id])
        #expect(model.selectedID == photos[2].id)

        model.minimumRating = 3
        await model.waitForProjection()
        model.selectAll()
        #expect(model.selectedIDs == Set(photos[3...5].map(\.id)))
        #expect(model.selectedAssets.map(\.id) == [photos[5].id, photos[4].id, photos[3].id])
    }

    @Test
    func filtersDiscardHiddenSelectionsAndKeepAnExistingVisibleImageActive() async throws {
        let (model, photos) = try await fixture()
        model.select(photos[1])
        model.select(photos[3], toggling: true)
        model.search = "bravo"
        await model.waitForProjection()
        #expect(model.selectedIDs == [photos[1].id])
        #expect(model.selectedID == photos[1].id)

        model.search = ""
        await model.waitForProjection()
        #expect(model.selectedIDs == [photos[1].id], "Hidden selections must not reappear when the filter is cleared")
    }

    @Test
    func filtersChooseAVisibleReplacementAndHandleAnEmptyResult() async throws {
        let (model, photos) = try await fixture()
        model.select(photos[2])
        model.search = "echo"
        await model.waitForProjection()
        #expect(model.selectedIDs == [photos[4].id])
        #expect(model.selectedID == photos[4].id)

        model.search = "no matching photograph"
        await model.waitForProjection()
        #expect(model.selectedIDs.isEmpty)
        #expect(model.selectedID == nil)
        model.selectAll()
        model.navigate(1, extending: true)
        #expect(model.selectedAssets.isEmpty)

        model.search = ""
        await model.waitForProjection()
        #expect(model.selectedIDs == [photos[0].id])
        #expect(model.selectedID == photos[0].id)
    }

    @Test
    func folderChangesAndRemovalReconcileTheSelectionWithTheCurrentCatalog() async throws {
        let first = folder("First")
        let second = folder("Second")
        let photos = [photo("alpha.png", in: first, rating: 1), photo("bravo.png", in: second, rating: 2)]
        let model = try await load(LibraryCatalog(folders: [first, second], assets: photos))
        model.selectAll()
        model.selection = .folder(second.id)
        await model.waitForProjection()
        #expect(model.selectedIDs == [photos[1].id])
        #expect(model.selectedID == photos[1].id)

        model.selection = .all
        await model.waitForProjection()
        model.selectAll()
        model.select(photos[1], toggling: true)
        model.select(photos[1], toggling: true)
        #expect(model.selectedID == photos[1].id)
        model.removeFolder(second.id)
        await model.waitForProjection()
        #expect(model.selectedIDs == [photos[0].id])
        #expect(model.selectedAsset?.id == photos[0].id)
        #expect(await model.finishSaving())
    }

    @Test
    func directActiveImageAssignmentKeepsLegacySelectionConsistent() async throws {
        let (model, photos) = try await fixture()
        model.selectAll()
        model.selectedID = photos[2].id
        #expect(model.selectedIDs == [photos[2].id])
        #expect(model.selectedAssets.map(\.id) == [photos[2].id])
        model.selectedID = nil
        model.reconcileSelection()
        #expect(model.selectedIDs.isEmpty)
        #expect(model.selectedAsset == nil)
    }

    private func fixture() async throws -> (LibraryModel, [PhotoAsset]) {
        let photosFolder = folder("Photos")
        let photos = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot"].enumerated().map {
            photo("\($0.element).png", in: photosFolder, rating: $0.offset)
        }
        return (try await load(LibraryCatalog(folders: [photosFolder], assets: photos)), photos)
    }

    private func folder(_ name: String) -> LibraryFolder {
        LibraryFolder(url: root.appendingPathComponent(name), subdirectoryPaths: ["Empty"])
    }

    private func photo(_ name: String, in folder: LibraryFolder, rating: Int) -> PhotoAsset {
        PhotoAsset(folderID: folder.id, fileURL: folder.url.appendingPathComponent(name),
                   createdAt: Date(timeIntervalSince1970: TimeInterval(rating)), rating: rating)
    }

    private func load(_ catalog: LibraryCatalog) async throws -> LibraryModel {
        try repository.save(catalog)
        let model = LibraryModel(repository: repository)
        model.sort = .name
        let deadline = Date().addingTimeInterval(20)
        while model.isLoading || model.isProjecting {
            guard Date() < deadline else { throw LibrarySelectionTestError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
        await model.waitForProjection()
        return model
    }
}

private enum LibrarySelectionTestError: Error { case timeout }
