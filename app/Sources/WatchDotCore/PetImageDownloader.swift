import Foundation
import ImageIO

public enum PetImageFormat: String, Codable, Sendable {
    case png, webP

    public var mimeType: String { self == .png ? "image/png" : "image/webp" }
    var typeIdentifier: String { self == .png ? "public.png" : "org.webmproject.webp" }
}

public struct PetImagePayload: Sendable {
    public let data: Data
    public let format: PetImageFormat
    public let width: Int
    public let height: Int
    public var rowCount: Int { height / 208 }
    public var mimeType: String { format.mimeType }

    public init(data: Data, format: PetImageFormat, width: Int, height: Int) {
        self.data = data
        self.format = format
        self.width = width
        self.height = height
    }
}

public enum PetImageDownloadError: Error, Equatable, Sendable {
    case invalidURL, unavailable, tls, tooLarge, invalidImage, unsupportedFormat, dimensions, animatedImage
    case httpStatus(Int)
}

public protocol PetImageDownloading: Sendable {
    func download(from url: URL) async throws -> PetImagePayload
}

final class PetImageNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public final class PetImageDownloader: PetImageDownloading {
    public static let maximumBytes = 8 * 1024 * 1024
    private let session: URLSession

    public convenience init() { self.init(protocolClasses: []) }

    init(protocolClasses: [AnyClass]) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        if !protocolClasses.isEmpty { configuration.protocolClasses = protocolClasses }
        session = URLSession(configuration: configuration, delegate: PetImageNoRedirects(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public static func validateURL(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == "cdn.openai.com",
              url.port == nil || url.port == 443, url.user == nil, url.password == nil,
              url.fragment == nil else { throw PetImageDownloadError.invalidURL }
    }

    public func download(from url: URL) async throws -> PetImagePayload {
        try Self.validateURL(url)
        try Task.checkCancellation()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpShouldHandleCookies = false
        request.setValue("image/png, image/webp", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse, response.url == url else {
                throw PetImageDownloadError.invalidURL
            }
            guard response.statusCode == 200 else { throw PetImageDownloadError.httpStatus(response.statusCode) }
            guard response.value(forHTTPHeaderField: "cf-mitigated") != "challenge" else {
                throw PetImageDownloadError.unsupportedFormat
            }
            guard response.expectedContentLength <= Int64(Self.maximumBytes) else {
                throw PetImageDownloadError.tooLarge
            }
            let mime = response.value(forHTTPHeaderField: "Content-Type") ?? ""
            guard Self.format(mimeType: mime) != nil else { throw PetImageDownloadError.unsupportedFormat }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < Self.maximumBytes else { throw PetImageDownloadError.tooLarge }
                data.append(byte)
            }
            try Task.checkCancellation()
            return try await PetImageValidator.shared.validate(data: data, mimeType: mime)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if let safe = error as? PetImageDownloadError { throw safe }
            if let network = error as? URLError,
               [.serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                .serverCertificateNotYetValid, .secureConnectionFailed].contains(network.code) {
                throw PetImageDownloadError.tls
            }
            throw PetImageDownloadError.unavailable
        }
    }

    public static func validate(data: Data, mimeType: String) throws -> PetImagePayload {
        let format = try validateEnvelope(data: data, mimeType: mimeType)
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        let imageSource = CGImageSourceCreateWithData(data as CFData, options)
        guard let source = imageSource,
              CGImageSourceGetType(source) as String? == format.typeIdentifier else {
            throw PetImageDownloadError.unsupportedFormat
        }
        guard CGImageSourceGetCount(source) == 1 else { throw PetImageDownloadError.animatedImage }
        guard CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw PetImageDownloadError.invalidImage
        }
        guard width == 1536, height == 1872 || height == 2288 else { throw PetImageDownloadError.dimensions }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options),
              image.width == width, image.height == height else { throw PetImageDownloadError.invalidImage }
        return PetImagePayload(data: data, format: format, width: width, height: height)
    }

    static func validateEnvelope(data: Data, mimeType: String) throws -> PetImageFormat {
        guard data.count <= maximumBytes else { throw PetImageDownloadError.tooLarge }
        guard let format = format(mimeType: mimeType), magicMatches(data, format: format) else {
            throw PetImageDownloadError.unsupportedFormat
        }
        return format
    }

    private static func format(mimeType: String) -> PetImageFormat? {
        let mime = mimeType.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return PetImageFormat.all.first { $0.mimeType == mime }
    }

    private static func magicMatches(_ data: Data, format: PetImageFormat) -> Bool {
        switch format {
        case .png: data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
        case .webP:
            data.count >= 12 && data.prefix(4) == Data("RIFF".utf8)
                && data.dropFirst(8).prefix(4) == Data("WEBP".utf8)
        }
    }
}

private extension PetImageFormat {
    static let all: [Self] = [.png, .webP]
}
