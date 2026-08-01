import Foundation
import XCTest
@testable import Tab

final class OpenRouterContextClientTests: XCTestCase {
    func testRequestUsesOneShotStructuredOutputAndMetadataBeforeJPEG() async throws {
        let imageData = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let transport = ClosureURLRequestTransport { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/v1/chat/completions")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer test-key"
            )
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)

            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody))
                    as? [String: Any]
            )
            XCTAssertEqual(body["model"] as? String, "openai/gpt-5.6-luna")
            XCTAssertEqual(body["stream"] as? Bool, false)
            XCTAssertEqual(body["max_tokens"] as? Int, 180)
            XCTAssertEqual(
                (body["reasoning"] as? [String: Any])?["effort"] as? String,
                "none"
            )
            let provider = try XCTUnwrap(body["provider"] as? [String: Any])
            XCTAssertEqual(provider["sort"] as? String, "latency")
            XCTAssertEqual(provider["require_parameters"] as? Bool, true)
            XCTAssertEqual(provider["data_collection"] as? String, "deny")
            XCTAssertEqual(provider["zdr"] as? Bool, true)

            let responseFormat = try XCTUnwrap(body["response_format"] as? [String: Any])
            XCTAssertEqual(responseFormat["type"] as? String, "json_schema")
            let jsonSchema = try XCTUnwrap(responseFormat["json_schema"] as? [String: Any])
            XCTAssertEqual(jsonSchema["strict"] as? Bool, true)
            let schema = try XCTUnwrap(jsonSchema["schema"] as? [String: Any])
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false)

            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            XCTAssertEqual(messages.count, 2)
            XCTAssertEqual(messages[0]["role"] as? String, "system")
            XCTAssertEqual(messages[1]["role"] as? String, "user")
            let parts = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
            XCTAssertEqual(parts.map { $0["type"] as? String }, ["text", "image_url"])
            XCTAssertTrue((parts[0]["text"] as? String)?.contains("Visual Studio Code") == true)
            let imageURL = try XCTUnwrap(parts[1]["image_url"] as? [String: Any])
            XCTAssertEqual(
                imageURL["url"] as? String,
                "data:image/jpeg;base64,\(imageData.base64EncodedString())"
            )
            XCTAssertEqual(imageURL["detail"] as? String, "low")

            return try Self.response(
                for: request,
                statusCode: 200,
                object: Self.successObject()
            )
        }
        let client = OpenRouterContextClient(
            apiKeyProvider: { "test-key" },
            transport: transport
        )

        let result = try await client.analyze(
            ScreenContextAnalysisRequest(
                metadata: Self.metadata,
                jpegImageData: imageData
            )
        )

        XCTAssertEqual(result.analysis.alignment, .productive)
        XCTAssertEqual(result.analysis.confidence, 0.91)
        XCTAssertEqual(result.analysis.summary, "Working in the project")
        XCTAssertEqual(result.usage, ContextModelUsage(
            inputTokens: 80,
            outputTokens: 18,
            totalTokens: 98,
            billedCredits: 0.00042
        ))
        XCTAssertEqual(result.providerResponseID, "generation-1")
        XCTAssertEqual(result.providerModel, "openai/gpt-5.6-luna")
    }

    func testMetadataOnlyRequestHasNoImagePart() async throws {
        let transport = ClosureURLRequestTransport { request in
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody))
                    as? [String: Any]
            )
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            let parts = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
            XCTAssertEqual(parts.count, 1)
            XCTAssertEqual(parts[0]["type"] as? String, "text")
            XCTAssertTrue(
                (parts[0]["text"] as? String)?.contains("Screen context source") == true
            )
            return try Self.response(
                for: request,
                statusCode: 200,
                object: Self.successObject()
            )
        }
        let client = OpenRouterContextClient(
            apiKeyProvider: { "test-key" },
            transport: transport
        )

        _ = try await client.analyze(ScreenContextAnalysisRequest(metadata: Self.metadata))
    }

    func testAPIErrorIsParsedWithoutIncludingRequestPayload() async {
        let transport = ClosureURLRequestTransport { request in
            try Self.response(
                for: request,
                statusCode: 429,
                object: [
                    "error": [
                        "message": "Rate limit reached",
                        "type": "rate_limit_error",
                        "code": "rate_limit"
                    ]
                ]
            )
        }
        let client = OpenRouterContextClient(
            apiKeyProvider: { "secret-that-must-not-appear" },
            transport: transport
        )

        do {
            _ = try await client.analyze(
                ScreenContextAnalysisRequest(metadata: Self.metadata)
            )
            XCTFail("Expected API error")
        } catch let error as OpenRouterContextClientError {
            XCTAssertEqual(
                error,
                .api(
                    statusCode: 429,
                    code: "rate_limit",
                    type: "rate_limit_error",
                    message: "Rate limit reached"
                )
            )
            XCTAssertFalse(String(describing: error).contains("secret-that-must-not-appear"))
            XCTAssertFalse(String(describing: error).contains("Visual Studio Code"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancellationStopsBeforeTransportCompletes() async {
        let transport = ClosureURLRequestTransport { _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            throw TestError.unexpectedCompletion
        }
        let client = OpenRouterContextClient(
            apiKeyProvider: { "test-key" },
            transport: transport
        )
        let task = Task {
            try await client.analyze(ScreenContextAnalysisRequest(metadata: Self.metadata))
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDefaultSessionIsEphemeralAndNonPersistent() {
        let session = OpenRouterContextClient.makeEphemeralSession()
        let configuration = session.configuration

        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.urlCredentialStorage)
        session.invalidateAndCancel()
    }

    private static let metadata = ScreenContextMetadata(
        observedAt: Date(timeIntervalSince1970: 1_700_000_000),
        applicationName: "Visual Studio Code",
        bundleIdentifier: "com.microsoft.VSCode",
        windowTitle: "ScreenContextModels.swift",
        focusGoal: "Implement the context probe",
        visibleTextExcerpt: "Screen context source",
        dwellTime: 20
    )

    private static func successObject() -> [String: Any] {
        let analysis: [String: Any] = [
            "alignment": "productive",
            "confidence": 0.91,
            "summary": "Working in the project",
            "evidence": ["The active editor matches the implementation goal"],
            "needs_screenshot": false
        ]
        let analysisData = try! JSONSerialization.data(withJSONObject: analysis)
        let analysisText = String(data: analysisData, encoding: .utf8)!
        return [
            "id": "generation-1",
            "model": "openai/gpt-5.6-luna",
            "choices": [[
                "finish_reason": "stop",
                "message": ["content": analysisText]
            ]],
            "usage": [
                "prompt_tokens": 80,
                "completion_tokens": 18,
                "total_tokens": 98,
                "cost": 0.00042
            ]
        ]
    }

    private static func response(
        for request: URLRequest,
        statusCode: Int,
        object: [String: Any]
    ) throws -> (Data, URLResponse) {
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )
        )
        return (try JSONSerialization.data(withJSONObject: object), response)
    }
}

private final class ClosureURLRequestTransport: URLRequestTransport {
    private let handler: (URLRequest) async throws -> (Data, URLResponse)

    init(handler: @escaping (URLRequest) async throws -> (Data, URLResponse)) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await handler(request)
    }
}

private enum TestError: Error {
    case unexpectedCompletion
}
