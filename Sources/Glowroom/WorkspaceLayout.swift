import Combine
import Foundation

enum LibraryWorkspace: String, Equatable {
    case library, develop, aiDevelop
}

enum WorkspaceTool: String, CaseIterable, Codable, Identifiable {
    case edit, color, details, aiDevelopment, metadata, versions

    var id: String { rawValue }

    /// Supporting information lives to the left of the image; adjustments live to its right.
    var isNavigationTool: Bool { self == .metadata || self == .versions }

    var title: String {
        switch self {
        case .edit: "Licht"
        case .color: "Farbe"
        case .details: "Details"
        case .aiDevelopment: "KI-Korrektur"
        case .metadata: "Bildinformationen"
        case .versions: "Bildstände"
        }
    }

    var symbol: String {
        switch self {
        case .edit: "slider.horizontal.3"
        case .color: "paintpalette"
        case .details: "viewfinder"
        case .aiDevelopment: "sparkles"
        case .metadata: "info.circle"
        case .versions: "square.stack.3d.up"
        }
    }
}

private enum WorkspaceLayoutMetrics {
    static let libraryRange = 180.0...360.0
    // Develop navigation hosts the same forms as the adjustment inspector.
    // Keep its native button rows usable instead of inheriting folder-tree widths.
    static let navigationRange = 300.0...360.0
    static let toolsRange = 300.0...520.0
    static let filmstripRange = 80.0...220.0
    static let canvasWidth = 320.0
    static let canvasHeight = 240.0
}

struct WorkspacePanels: Codable, Equatable {
    var showsLibrary = true
    var showsTools = true
    var showsFilmstrip = true
    var libraryWidth = 300.0
    var toolsWidth = 320.0
    var filmstripHeight = 98.0
    var openGroups: Set<WorkspaceTool> = [.edit]
    var singleGroup = false
    var openAdjustmentGroups: Set<String> = ["tone", "sharpening", "noise"]
    // Persist the migration marker so deliberately closing Details remains closed.
    private var detailsGroupVersion = 1

    static var libraryDefault: Self {
        var panels = Self()
        panels.libraryWidth = 218
        panels.openGroups = [.metadata]
        return panels
    }

    static var developDefault: Self { Self() }

    static var focusDefault: Self {
        var panels = Self()
        panels.showsLibrary = false
        panels.showsTools = false
        panels.showsFilmstrip = false
        return panels
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case showsLibrary, showsTools, showsFilmstrip, libraryWidth, toolsWidth, filmstripHeight
        case openGroups, singleGroup, openAdjustmentGroups, detailsGroupVersion
    }

    init(from decoder: Decoder) throws {
        try self.init(from: decoder, defaults: .developDefault, navigation: true)
    }

    fileprivate init(from decoder: Decoder, defaults: Self, navigation: Bool) throws {
        self = defaults
        let values = try decoder.container(keyedBy: CodingKeys.self)
        showsLibrary = (try? values.decode(Bool.self, forKey: .showsLibrary)) ?? showsLibrary
        showsTools = (try? values.decode(Bool.self, forKey: .showsTools)) ?? showsTools
        showsFilmstrip = (try? values.decode(Bool.self, forKey: .showsFilmstrip)) ?? showsFilmstrip
        libraryWidth = (try? values.decode(Double.self, forKey: .libraryWidth)) ?? libraryWidth
        toolsWidth = (try? values.decode(Double.self, forKey: .toolsWidth)) ?? toolsWidth
        filmstripHeight = (try? values.decode(Double.self, forKey: .filmstripHeight)) ?? filmstripHeight
        if let names = try? values.decode([String].self, forKey: .openGroups) {
            // An unavailable/newer tool must not discard the rest of a saved layout.
            openGroups = Set(names.compactMap(WorkspaceTool.init(rawValue:)))
        }
        singleGroup = (try? values.decode(Bool.self, forKey: .singleGroup)) ?? singleGroup
        let savedAdjustmentGroups = try? values.decode(Set<String>.self, forKey: .openAdjustmentGroups)
        if let names = savedAdjustmentGroups {
            openAdjustmentGroups = names
        }
        if navigation, !values.contains(.detailsGroupVersion),
           openGroups.contains(.edit), savedAdjustmentGroups?.contains("noise") == true {
            if singleGroup { openGroups.remove(.edit) }
            openGroups.insert(.details)
        }
        normalize(navigation: navigation)
    }

    mutating func normalize(navigation: Bool = true) {
        let leftRange = navigation ? WorkspaceLayoutMetrics.navigationRange : WorkspaceLayoutMetrics.libraryRange
        libraryWidth = Self.bounded(libraryWidth, fallback: navigation ? 300 : 218, range: leftRange)
        toolsWidth = Self.bounded(toolsWidth, fallback: 320, range: WorkspaceLayoutMetrics.toolsRange)
        filmstripHeight = Self.bounded(filmstripHeight, fallback: 98, range: WorkspaceLayoutMetrics.filmstripRange)
        openAdjustmentGroups.formIntersection(["tone", "presence", "sharpening", "noise"])
        if singleGroup {
            let firstNavigation = WorkspaceTool.allCases.first { $0.isNavigationTool && openGroups.contains($0) }
            let firstAdjustment = WorkspaceTool.allCases.first { !$0.isNavigationTool && openGroups.contains($0) }
            openGroups = []
            if let firstNavigation { openGroups.insert(firstNavigation) }
            if let firstAdjustment { openGroups.insert(firstAdjustment) }
        }
    }

    private static func bounded(_ value: Double, fallback: Double, range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}

struct WorkspaceFocusOrigin: Codable, Equatable {
    var developing: Bool
    var showsDetail: Bool
    // Decoding only: WorkspaceLayoutModel removes this legacy workspace marker.
    var aiDeveloping: Bool? = nil

    init(developing: Bool, showsDetail: Bool, aiDeveloping: Bool? = nil) {
        self.developing = developing
        self.showsDetail = showsDetail
        self.aiDeveloping = aiDeveloping
    }

    private enum CodingKeys: String, CodingKey { case developing, showsDetail, aiDeveloping }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        developing = (try? values.decode(Bool.self, forKey: .developing)) ?? true
        showsDetail = (try? values.decode(Bool.self, forKey: .showsDetail)) ?? true
        aiDeveloping = try? values.decode(Bool.self, forKey: .aiDeveloping)
    }
}

@MainActor
final class WorkspaceLayoutModel: ObservableObject {
    static let preferencesKey = "workspace.layout.v1"
    static let minimumWindowWidth = 1_000.0
    static let minimumCanvasWidth = WorkspaceLayoutMetrics.canvasWidth
    static let minimumCanvasHeight = WorkspaceLayoutMetrics.canvasHeight

    @Published var library: WorkspacePanels {
        didSet {
            var normalized = library
            normalized.normalize(navigation: false)
            if normalized != library { library = normalized }
            persist()
        }
    }
    @Published var develop: WorkspacePanels {
        didSet {
            var normalized = develop
            normalized.normalize()
            if normalized != develop { develop = normalized }
            persist()
        }
    }
    @Published var focus: WorkspacePanels {
        didSet {
            var normalized = focus
            normalized.normalize()
            if normalized != focus { focus = normalized }
            persist()
        }
    }
    @Published private(set) var isFocused: Bool {
        didSet { persist() }
    }
    @Published private(set) var focusOrigin: WorkspaceFocusOrigin {
        didSet { persist() }
    }
    @Published private(set) var revealedTool: WorkspaceTool?
    @Published private(set) var revealRequest = UUID()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.preferencesKey).flatMap { data -> StoredLayout? in
            let decoder = JSONDecoder()
            decoder.nonConformingFloatDecodingStrategy = .convertFromString(
                positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
            guard let layout = try? decoder.decode(StoredLayout.self, from: data), layout.version == 1 else { return nil }
            return layout
        }
        library = saved?.library ?? .libraryDefault
        develop = saved?.develop ?? .developDefault
        focus = saved?.focus ?? .focusDefault
        isFocused = saved?.isFocused ?? false
        let origin = saved?.focusOrigin ?? WorkspaceFocusOrigin(developing: true, showsDetail: true)
        focusOrigin = WorkspaceFocusOrigin(developing: origin.developing || origin.aiDeveloping == true,
                                           showsDetail: origin.showsDetail)
        // The previous AI workspace used the same panel preferences. Keep those
        // dimensions and groups, but restore its task inside the common inspector.
        if origin.aiDeveloping == true {
            let restoreCorrection: (inout WorkspacePanels) -> Void = { panels in
                if panels.singleGroup {
                    panels.openGroups = panels.openGroups.filter(\.isNavigationTool)
                }
                panels.openGroups.insert(.aiDevelopment)
            }
            restoreCorrection(&focus)
            // Focus return restores the former AI task in the normal inspector too.
            restoreCorrection(&develop)
            persist()
        }
    }

    func panels(developing: Bool) -> WorkspacePanels {
        isFocused ? focus : (developing ? develop : library)
    }

    func update(developing: Bool, _ mutate: (inout WorkspacePanels) -> Void) {
        // These tiny preference changes remain ordered with UI state on MainActor.
        // Spawning parallel workers here would add synchronization without useful work.
        var panels = panels(developing: developing)
        mutate(&panels)
        panels.normalize(navigation: isFocused || developing)
        if isFocused { focus = panels }
        else if developing { develop = panels }
        else { library = panels }
    }

    func enterFocus(developing: Bool = true, showsDetail: Bool = true, aiDeveloping: Bool = false) {
        guard !isFocused else { return }
        // Accept the old entry argument defensively, but never persist a second
        // development context again.
        focusOrigin = WorkspaceFocusOrigin(developing: developing || aiDeveloping, showsDetail: showsDetail)
        isFocused = true
    }

    @discardableResult
    func leaveFocus() -> WorkspaceFocusOrigin {
        isFocused = false
        return focusOrigin
    }

    func toggleGroup(_ tool: WorkspaceTool, developing: Bool) {
        var opened = false
        update(developing: developing) { panels in
            if panels.openGroups.contains(tool) {
                panels.openGroups.remove(tool)
            } else {
                if panels.singleGroup {
                    panels.openGroups = panels.openGroups.filter { $0.isNavigationTool != tool.isNavigationTool }
                }
                panels.openGroups.insert(tool)
                opened = true
            }
        }
        if opened { requestReveal(tool) }
    }

    func reveal(_ tool: WorkspaceTool, developing: Bool) {
        update(developing: developing) { panels in
            if tool.isNavigationTool { panels.showsLibrary = true }
            else { panels.showsTools = true }
            if panels.singleGroup {
                panels.openGroups = panels.openGroups.filter { $0.isNavigationTool != tool.isNavigationTool }
            }
            panels.openGroups.insert(tool)
        }
        requestReveal(tool)
    }

    func reset(developing: Bool) {
        if isFocused { focus = .focusDefault }
        else if developing { develop = .developDefault }
        else { library = .libraryDefault }
        revealedTool = nil
    }

    func remember() { persist() }

    /// Returns geometry for the current window without replacing preferred sizes.
    /// Each visible side panel has a one-point divider beside the image.
    func boundedWidths(availableWidth: Double, developing: Bool) -> (library: Double, tools: Double) {
        let panels = panels(developing: developing)
        let width = availableWidth.isFinite ? max(0, availableWidth) : Self.minimumWindowWidth
        let desiredLibrary = panels.showsLibrary ? panels.libraryWidth : 0
        let desiredTools = panels.showsTools ? panels.toolsWidth : 0
        let dividers = Double((panels.showsLibrary ? 1 : 0) + (panels.showsTools ? 1 : 0))
        let budget = max(0, width - Self.minimumCanvasWidth - dividers)
        let desiredTotal = desiredLibrary + desiredTools
        guard desiredTotal > budget else { return (desiredLibrary, desiredTools) }

        let leftRange = isFocused || developing ? WorkspaceLayoutMetrics.navigationRange : WorkspaceLayoutMetrics.libraryRange
        let minimumLibrary = panels.showsLibrary ? leftRange.lowerBound : 0
        let minimumTools = panels.showsTools ? WorkspaceLayoutMetrics.toolsRange.lowerBound : 0
        let minimumTotal = minimumLibrary + minimumTools
        guard minimumTotal > 0 else { return (0, 0) }
        if budget < minimumTotal {
            // This fallback also keeps the canvas usable in transient pre-minimum
            // geometry during window creation and display changes.
            let scale = budget / minimumTotal
            return (minimumLibrary * scale, minimumTools * scale)
        }
        let extraTotal = desiredTotal - minimumTotal
        guard extraTotal > 0 else { return (minimumLibrary, minimumTools) }
        let scale = (budget - minimumTotal) / extraTotal
        return (minimumLibrary + (desiredLibrary - minimumLibrary) * scale,
                minimumTools + (desiredTools - minimumTools) * scale)
    }

    func boundedFilmstripHeight(availableHeight: Double, developing: Bool) -> Double {
        let panels = panels(developing: developing)
        guard panels.showsFilmstrip else { return 0 }
        let height = availableHeight.isFinite ? max(0, availableHeight) : Self.minimumCanvasHeight + 99
        return min(panels.filmstripHeight, max(0, height - Self.minimumCanvasHeight - 1))
    }

    private func requestReveal(_ tool: WorkspaceTool) {
        revealedTool = tool
        revealRequest = UUID()
    }

    private func persist() {
        let saved = StoredLayout(version: 1, library: library, develop: develop, focus: focus,
                                 isFocused: isFocused, focusOrigin: focusOrigin)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        defaults.set(data, forKey: Self.preferencesKey)
    }

    private struct StoredLayout: Codable {
        var version: Int
        var library: WorkspacePanels?
        var develop: WorkspacePanels?
        var focus: WorkspacePanels?
        var isFocused: Bool
        var focusOrigin: WorkspaceFocusOrigin?

        private enum CodingKeys: String, CodingKey { case version, library, develop, focus, isFocused, focusOrigin }

        init(version: Int, library: WorkspacePanels, develop: WorkspacePanels, focus: WorkspacePanels,
             isFocused: Bool, focusOrigin: WorkspaceFocusOrigin) {
            self.version = version
            self.library = library
            self.develop = develop
            self.focus = focus
            self.isFocused = isFocused
            self.focusOrigin = focusOrigin
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = (try? values.decode(Int.self, forKey: .version)) ?? 1
            library = (try? values.superDecoder(forKey: .library)).flatMap {
                try? WorkspacePanels(from: $0, defaults: .libraryDefault, navigation: false)
            }
            develop = (try? values.superDecoder(forKey: .develop)).flatMap {
                try? WorkspacePanels(from: $0, defaults: .developDefault, navigation: true)
            }
            focus = (try? values.superDecoder(forKey: .focus)).flatMap {
                try? WorkspacePanels(from: $0, defaults: .focusDefault, navigation: true)
            }
            isFocused = (try? values.decode(Bool.self, forKey: .isFocused)) ?? false
            focusOrigin = try? values.decode(WorkspaceFocusOrigin.self, forKey: .focusOrigin)
        }
    }
}
