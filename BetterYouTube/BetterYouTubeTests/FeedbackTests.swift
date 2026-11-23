import Foundation
import Testing
@testable import BetterYouTube

private func requestBody(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    let stream = try #require(request.httpBodyStream)
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
        if count == 0 { return data }
        data.append(contentsOf: buffer.prefix(count))
    }
}

private final class FeedbackURLProtocol: URLProtocol {
    // The suite is serialized, so the single handler is only ever touched from one test at a time.
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> Int)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let status = try Self.handler?(request) ?? 500
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Suite("Feedback", .serialized)
@MainActor
struct FeedbackTests {
    private let endpoint = URL(string: "https://formspree.io/f/testform")!

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeedbackURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test("Blank messages and missing or invalid endpoints cannot be submitted")
    func validation() async {
        let missing = FeedbackModel(endpoint: nil, session: session())
        missing.message = "Hello"
        #expect(!missing.isConfigured)
        #expect(!missing.canSend)
        await missing.send()
        #expect(missing.submissionState == .idle)

        for raw in ["http://formspree.io/f/test", "https://example.com/f/test", "https://formspree.io/f/"] {
            let model = FeedbackModel(endpoint: URL(string: raw), session: session())
            #expect(!model.isConfigured)
        }
        let model = FeedbackModel(endpoint: endpoint, session: session())
        model.message = " \n  "
        #expect(model.isConfigured)
        #expect(!model.canSend)
    }

    @Test("Only the message and optional email are sent on success")
    func success() async throws {
        let model = FeedbackModel(endpoint: endpoint, session: session())
        let sent = "Bonjour + café & help?\nSecond line"
        let expectedEndpoint = endpoint
        model.message = sent
        model.email = " person@example.com "
        FeedbackURLProtocol.handler = { request in
            #expect(request.url == expectedEndpoint)
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            let body = try requestBody(request)
            let fields = try JSONDecoder().decode([String: String].self, from: body)
            #expect(fields == ["message": sent, "email": "person@example.com"])
            return 200
        }
        await model.send()
        #expect(model.submissionState == .success)
        #expect(model.message.isEmpty)
        #expect(!model.isSending)

        model.message = "Anonymous feedback"
        model.email = " \n "
        FeedbackURLProtocol.handler = { request in
            let fields = try JSONDecoder().decode([String: String].self, from: requestBody(request))
            #expect(fields == ["message": "Anonymous feedback"])
            return 201
        }
        await model.send()
        #expect(model.submissionState == .success)
    }

    @Test("Network and service failures retain the message and allow a retry")
    func failuresAndRetry() async {
        let model = FeedbackModel(endpoint: endpoint, session: session())
        model.message = "Please keep this"
        model.email = "person@example.com"
        FeedbackURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await model.send()
        #expect(model.submissionState == .failure)
        #expect(model.message == "Please keep this")
        #expect(model.email == "person@example.com")
        #expect(model.canSend)

        FeedbackURLProtocol.handler = { _ in 429 }
        await model.send()
        #expect(model.submissionState == .failure)
        #expect(model.message == "Please keep this")
        #expect(model.canSend)

        FeedbackURLProtocol.handler = { _ in 200 }
        await model.send()
        #expect(model.submissionState == .success)
        #expect(model.message.isEmpty)
    }

    @Test("Links preserve special characters without introducing parameters")
    func links() throws {
        let message = "Plus + & = ? # café\nSecond line"
        let issueURL = try #require(FeedbackLinks.githubIssue(message: message))
        let issue = try #require(URLComponents(url: issueURL, resolvingAgainstBaseURL: false))
        #expect(issue.host == "github.com")
        #expect(issue.path == "/atomtoto/Better-YouTube/issues/new")
        #expect(issue.queryItems?.first(where: { $0.name == "body" })?.value == message)
        #expect(issue.queryItems?.count == 2)

        let mailURL = try #require(FeedbackLinks.email(message: message, address: "help@example.com"))
        let mail = try #require(URLComponents(url: mailURL, resolvingAgainstBaseURL: false))
        #expect(mail.scheme == "mailto")
        #expect(mail.path == "help@example.com")
        #expect(mail.queryItems?.first(where: { $0.name == "body" })?.value == message)
        #expect(mail.queryItems?.count == 2)
        #expect(FeedbackLinks.email(message: message, address: "") == nil)
    }
}
