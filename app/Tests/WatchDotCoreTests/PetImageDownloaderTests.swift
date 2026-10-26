import CoreGraphics
import ImageIO
import XCTest
@testable import WatchDotCore

private final class PetImageProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        let status: Int
        let headers: [String: String]
        let data: Data
        let error: URLError?
    }
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var response = Response(status: 200, headers: [:], data: Data(), error: nil)
        var requests: [URLRequest] = []
    }
    private static let state = State()
    static func configure(status: Int = 200, headers: [String: String] = ["Content-Type": "image/png"],
                          data: Data = Data(), error: URLError? = nil) {
        state.lock.lock(); defer { state.lock.unlock() }
        state.response = Response(status: status, headers: headers, data: data, error: error)
        state.requests = []
    }
    static var requests: [URLRequest] {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.requests
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.state.lock.lock()
        let response = Self.state.response
        Self.state.requests = Self.state.requests + [request]
        Self.state.lock.unlock()
        if let error = response.error { client?.urlProtocol(self, didFailWithError: error); return }
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status,
                                   httpVersion: "HTTP/1.1", headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class PetImageDownloaderTests: XCTestCase {
    private let url = URL(string: "https://cdn.openai.com/fixture.png")!
    private func downloader() -> PetImageDownloader { PetImageDownloader(protocolClasses: [PetImageProtocol.self]) }

    func testURLAllowlistRejectsAlternativeOriginsAndCredentials() throws {
        for value in ["https://cdn.openai.com/a", "https://CDN.OPENAI.COM:443/a?version=2"] {
            XCTAssertNoThrow(try PetImageDownloader.validateURL(URL(string: value)!))
        }
        for value in ["http://cdn.openai.com/a", "https://cdn.openai.com.evil.test/a",
                      "https://other.openai.com/a", "https://cdn.openai.com:444/a",
                      "https://cdn.openai.com/a#fragment", "file:///a", "https://cdn.openai.com./a"] {
            XCTAssertThrowsError(try PetImageDownloader.validateURL(URL(string: value)!)) {
                XCTAssertEqual($0 as? PetImageDownloadError, .invalidURL)
            }
        }
    }

    func testURLAllowlistRejectsUserInformation() throws {
        for password in [nil, "fixture-password"] {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.user = "fixture-user"
            components.password = password
            XCTAssertThrowsError(try PetImageDownloader.validateURL(try XCTUnwrap(components.url))) {
                XCTAssertEqual($0 as? PetImageDownloadError, .invalidURL)
            }
        }
    }

    func testBothKnownPNGContractsAndMIMENormalization() throws {
        for height in [1872, 2288] {
            let data = try png(height: height)
            let payload = try PetImageDownloader.validate(data: data, mimeType: " IMAGE/PNG; charset=binary ")
            XCTAssertEqual(payload.data, data)
            XCTAssertEqual(payload.width, 1536)
            XCTAssertEqual(payload.height, height)
            XCTAssertEqual(payload.rowCount, height / 208)
            XCTAssertEqual(payload.format, .png)
        }
    }

    func testSyntheticWebPAndAnimatedWebP() throws {
        // Original solid-color fixtures generated with libwebp, no service artwork.
        let still = Data(base64Encoded: "UklGRpwAAABXRUJQVlA4TI8AAAAv/8XTAQdQwAIVuP8BAEX6/58i+p/63//+97///e9///vf//73v//973//+9///ve///3vf//73//+97///e9///vf//73v//973//+9///ve///3vf//73//+97///e9///vf//73v//973//+9///ve///3vf//73//+97///e9///vf//73v//97/8qAAA=")!
        let payload = try PetImageDownloader.validate(data: still, mimeType: "image/webp")
        XCTAssertEqual(payload.format, .webP)
        XCTAssertEqual(payload.rowCount, 9)
        let animation = Data(base64Encoded: "UklGRogAAABXRUJQVlA4WAoAAAACAAAABwAABwAAQU5JTQYAAAD/////AABBTk1GKgAAAAAAAAAAAAcAAAcAAGQAAABWUDhMEQAAAC8HwAEAB1DAAhW4/4GI6H8AAEFOTUYqAAAAAAAAAAAABwAABwAAZAAAAFZQOEwRAAAALwfAAQAHUMACF6j/gYjofwAA")!
        XCTAssertThrowsError(try PetImageDownloader.validate(data: animation, mimeType: "image/webp")) {
            XCTAssertEqual($0 as? PetImageDownloadError, .animatedImage)
        }
    }

    func testWrongDimensionsMIMEMagicTruncationAndSizeAreRejected() throws {
        let good = try png()
        let cases: [(Data, String, PetImageDownloadError?)] = [
            (try png(width: 1, height: 1), "image/png", .dimensions),
            (good, "image/webp", .unsupportedFormat), (good, "text/html", .unsupportedFormat),
            (Data("not an image".utf8), "image/png", .unsupportedFormat),
            (good.prefix(40), "image/png", nil),
            (Data(repeating: 0, count: PetImageDownloader.maximumBytes + 1), "image/png", .tooLarge)
        ]
        for (data, mime, expected) in cases {
            XCTAssertThrowsError(try PetImageDownloader.validate(data: data, mimeType: mime)) {
                XCTAssertNotNil($0 as? PetImageDownloadError)
                if let expected { XCTAssertEqual($0 as? PetImageDownloadError, expected) }
            }
        }
    }

    func testDownloadNeverSendsCredentialsAndReturnsValidatedImage() async throws {
        PetImageProtocol.configure(data: try png())
        let payload = try await downloader().download(from: url)
        XCTAssertEqual(payload.rowCount, 9)
        let request = try XCTUnwrap(PetImageProtocol.requests.first)
        for header in ["Authorization", "Cookie", "ChatGPT-Account-Id"] {
            XCTAssertNil(request.value(forHTTPHeaderField: header))
        }
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.timeoutInterval, 30)
        XCTAssertEqual(PetImageProtocol.requests.count, 1)
    }

    func testHTTPFailuresPreserveStatusWithoutRetry() async throws {
        for status in [302, 403, 404, 410, 500] {
            PetImageProtocol.configure(status: status, headers: ["Location": "https://elsewhere.test/secret"],
                                       data: Data("private response body".utf8))
            await expect(.httpStatus(status)) { try await self.downloader().download(from: self.url) }
            XCTAssertEqual(PetImageProtocol.requests.count, 1)
        }
    }

    func testRedirectDelegateRefusesDestination() async {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let result = await withCheckedContinuation { continuation in
            PetImageNoRedirects().urlSession(session, task: session.dataTask(with: url),
                willPerformHTTPRedirection: HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil,
                                                            headerFields: nil)!,
                newRequest: URLRequest(url: URL(string: "https://elsewhere.test/")!)) {
                    continuation.resume(returning: $0)
                }
        }
        XCTAssertNil(result)
    }

    func testKnownAndUnknownOversizeResponsesAreBounded() async {
        PetImageProtocol.configure(headers: ["Content-Type": "image/png", "Content-Length": "8388609"])
        await expect(.tooLarge) { try await self.downloader().download(from: self.url) }
        PetImageProtocol.configure(data: Data(repeating: 0, count: PetImageDownloader.maximumBytes + 1))
        await expect(.tooLarge) { try await self.downloader().download(from: self.url) }
    }

    func testChallengeUnsupportedContentAndNetworkErrorsStaySafe() async {
        PetImageProtocol.configure(headers: ["Content-Type": "image/png", "cf-mitigated": "challenge"])
        await expect(.unsupportedFormat) { try await self.downloader().download(from: self.url) }
        PetImageProtocol.configure(headers: ["Content-Type": "text/html"])
        await expect(.unsupportedFormat) { try await self.downloader().download(from: self.url) }
        PetImageProtocol.configure(error: URLError(.serverCertificateUntrusted))
        await expect(.tls) { try await self.downloader().download(from: self.url) }
        PetImageProtocol.configure(error: URLError(.timedOut))
        await expect(.unavailable) { try await self.downloader().download(from: self.url) }
    }

    func testCancellationRemainsCancellation() async {
        PetImageProtocol.configure(error: URLError(.cancelled))
        do { _ = try await downloader().download(from: url); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testInvalidURLAndPriorCancellationNeverMakeRequests() async {
        PetImageProtocol.configure()
        await expect(.invalidURL) {
            try await self.downloader().download(from: URL(string: "https://example.test/private")!)
        }
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await downloader().download(from: url)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(PetImageProtocol.requests.isEmpty)
    }

    func testAnimatedPNGIsRejected() throws {
        let still = try png(width: 8, height: 8)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(still as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 2, nil))
        let properties = [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.1]] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        CGImageDestinationAddImage(destination, image, properties)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertThrowsError(try PetImageDownloader.validate(data: data as Data, mimeType: "image/png")) {
            XCTAssertEqual($0 as? PetImageDownloadError, .animatedImage)
        }
    }

    private func expect(_ expected: PetImageDownloadError,
                        operation: () async throws -> PetImagePayload) async {
        do { _ = try await operation(); XCTFail("Expected failure") }
        catch { XCTAssertEqual(error as? PetImageDownloadError, expected) }
    }

    private func png(width: Int = 1536, height: Int = 1872) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
