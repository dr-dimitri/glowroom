import Foundation

/// A folder is referenced in place. Importing never moves or modifies its files.
public struct LibraryFolder: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var url: URL
    public var bookmarkData: Data?
    public var name: String
    public var addedAt: Date
    public var lastScannedAt: Date?
    /// Paths relative to `url`, including directories that contain no images.
    public var subdirectoryPaths: [String]

    public init(
        id: UUID = UUID(),
        url: URL,
        bookmarkData: Data? = nil,
        name: String? = nil,
        addedAt: Date = Date(),
        lastScannedAt: Date? = nil,
        subdirectoryPaths: [String] = []
    ) {
        self.id = id
        self.url = url.standardizedFileURL.resolvingSymlinksInPath()
        self.bookmarkData = bookmarkData
        self.name = name ?? url.lastPathComponent
        self.addedAt = addedAt
        self.lastScannedAt = lastScannedAt
        self.subdirectoryPaths = subdirectoryPaths
    }

    private enum CodingKeys: String, CodingKey {
        case id, url, bookmarkData, name, addedAt, lastScannedAt, subdirectoryPaths
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        url = try values.decode(URL.self, forKey: .url)
        bookmarkData = try values.decodeIfPresent(Data.self, forKey: .bookmarkData)
        name = try values.decode(String.self, forKey: .name)
        addedAt = try values.decode(Date.self, forKey: .addedAt)
        lastScannedAt = try values.decodeIfPresent(Date.self, forKey: .lastScannedAt)
        // Existing version-1 catalogs predate the directory tree and remain readable.
        subdirectoryPaths = try values.decodeIfPresent([String].self, forKey: .subdirectoryPaths) ?? []
    }
}

public struct PhotoAsset: Codable, Hashable, Identifiable, Sendable {
    /// A canonical file path gives repeated scans and overlapping imports a stable identity.
    public var id: String
    public var folderID: UUID
    public var fileURL: URL
    public var fileName: String
    public var fileSize: Int64
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var createdAt: Date
    public var modifiedAt: Date
    public var captureDate: Date?
    public var format: String
    public var cameraModel: String?
    public var lensModel: String?
    public var focalLength: String?
    public var aperture: String?
    public var shutterSpeed: String?
    public var iso: String?
    public var rating: Int
    public var isFavorite: Bool

    public init(
        id: String? = nil,
        folderID: UUID,
        fileURL: URL,
        fileName: String? = nil,
        fileSize: Int64 = 0,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        captureDate: Date? = nil,
        format: String? = nil,
        cameraModel: String? = nil,
        lensModel: String? = nil,
        focalLength: String? = nil,
        aperture: String? = nil,
        shutterSpeed: String? = nil,
        iso: String? = nil,
        rating: Int = 0,
        isFavorite: Bool = false
    ) {
        let canonicalURL = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        self.id = id ?? canonicalURL.path
        self.folderID = folderID
        self.fileURL = canonicalURL
        self.fileName = fileName ?? canonicalURL.lastPathComponent
        self.fileSize = fileSize
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.captureDate = captureDate
        self.format = format ?? canonicalURL.pathExtension.uppercased()
        self.cameraModel = cameraModel
        self.lensModel = lensModel
        self.focalLength = focalLength
        self.aperture = aperture
        self.shutterSpeed = shutterSpeed
        self.iso = iso
        self.rating = min(5, max(0, rating))
        self.isFavorite = isFavorite
    }
}

public struct LibraryCatalog: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var folders: [LibraryFolder]
    public var assets: [PhotoAsset]

    public init(
        version: Int = LibraryCatalog.currentVersion,
        folders: [LibraryFolder] = [],
        assets: [PhotoAsset] = []
    ) {
        self.version = version
        self.folders = folders
        self.assets = assets
    }
}

public struct ScanResult: Sendable {
    public let assets: [PhotoAsset]
    public let skippedFiles: Int
    public let skippedURLs: [URL]
    public let subdirectoryPaths: [String]

    public init(assets: [PhotoAsset], skippedFiles: Int, skippedURLs: [URL] = [], subdirectoryPaths: [String] = []) {
        self.assets = assets
        self.skippedFiles = skippedFiles
        self.skippedURLs = skippedURLs
        self.subdirectoryPaths = subdirectoryPaths
    }
}
