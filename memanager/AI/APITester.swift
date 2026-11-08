import Foundation

/// Result of an API validation test
struct APITestResult {
    let success: Bool
    let message: String
    let modelInfo: String?
    let responseTime: TimeInterval
}

/// Static API testing functions for validating credentials
enum APITester {
    
    /// Test Claude API key
    static func testClaude(apiKey: String, model: String) async -> APITestResult {
        let startTime = Date()
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 30
        
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 10,
            "messages": [["role": "user", "content": "Say OK"]]
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            let elapsed = Date().timeIntervalSince(startTime)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                return APITestResult(success: false, message: "Invalid response", modelInfo: nil, responseTime: elapsed)
            }
            
            if httpResponse.statusCode == 200 {
                return APITestResult(success: true, message: "API key valid", modelInfo: model, responseTime: elapsed)
            } else if httpResponse.statusCode == 401 {
                return APITestResult(success: false, message: "Invalid API key", modelInfo: nil, responseTime: elapsed)
            } else if httpResponse.statusCode == 400 {
                let errorText = String(data: data, encoding: .utf8) ?? ""
                if errorText.contains("model") {
                    return APITestResult(success: false, message: "Invalid model: \(model)", modelInfo: nil, responseTime: elapsed)
                }
                return APITestResult(success: false, message: "Bad request: \(errorText.prefix(100))", modelInfo: nil, responseTime: elapsed)
            } else {
                let errorText = String(data: data, encoding: .utf8) ?? "Unknown"
                return APITestResult(success: false, message: "HTTP \(httpResponse.statusCode): \(errorText.prefix(100))", modelInfo: nil, responseTime: elapsed)
            }
        } catch {
            let elapsed = Date().timeIntervalSince(startTime)
            return APITestResult(success: false, message: "Network error: \(error.localizedDescription)", modelInfo: nil, responseTime: elapsed)
        }
    }
    
    /// Test OpenAI API key
    static func testOpenAI(
        apiKey: String,
        model: String,
        reasoningEffort: OpenAIReasoningEffort = .high
    ) async -> APITestResult {
        let startTime = Date()
        let responsesURL = URL(string: "https://api.openai.com/v1/responses")!
        let chatURL = URL(string: "https://api.openai.com/v1/chat/completions")!

        func makeRequest(url: URL, body: [String: Any]) throws -> URLRequest {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 30
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            return request
        }

        func parseErrorMessage(_ data: Data) -> String {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String,
               !message.isEmpty {
                return message
            }
            return String(data: data, encoding: .utf8) ?? "Unknown"
        }

        func parseModelInfo(_ data: Data) -> String? {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            if let directModel = json["model"] as? String, !directModel.isEmpty {
                return directModel
            }
            if let response = json["response"] as? [String: Any],
               let nestedModel = response["model"] as? String,
               !nestedModel.isEmpty {
                return nestedModel
            }
            return nil
        }

        func shouldFallbackToChat(status: Int, errorMessage: String) -> Bool {
            guard [400, 404, 405, 415, 422].contains(status) else { return false }
            let lower = errorMessage.lowercased()
            return lower.contains("unsupported") ||
                lower.contains("not supported") ||
                lower.contains("unknown parameter") ||
                lower.contains("unrecognized") ||
                lower.contains("responses") ||
                lower.contains("input_text") ||
                lower.contains("input_image") ||
                lower.contains("reasoning")
        }

        let chatBody: [String: Any] = [
            "model": model,
            "max_completion_tokens": 10,
            "messages": [["role": "user", "content": "Say OK"]]
        ]

        do {
            guard OpenAIReasoningEffortResolver.prefersResponsesAPI(for: model) else {
                let chatRequest = try makeRequest(url: chatURL, body: chatBody)
                let (data, response) = try await URLSession.shared.data(for: chatRequest)
                let elapsed = Date().timeIntervalSince(startTime)

                guard let httpResponse = response as? HTTPURLResponse else {
                    return APITestResult(success: false, message: "Invalid response", modelInfo: nil, responseTime: elapsed)
                }

                if httpResponse.statusCode == 200 {
                    return APITestResult(
                        success: true,
                        message: "API key valid",
                        modelInfo: parseModelInfo(data) ?? model,
                        responseTime: elapsed
                    )
                }

                if httpResponse.statusCode == 401 {
                    return APITestResult(success: false, message: "Invalid API key", modelInfo: nil, responseTime: elapsed)
                }

                if httpResponse.statusCode == 404 {
                    return APITestResult(success: false, message: "Model not found: \(model)", modelInfo: nil, responseTime: elapsed)
                }

                let errorMessage = parseErrorMessage(data)
                return APITestResult(
                    success: false,
                    message: "HTTP \(httpResponse.statusCode): \(errorMessage.prefix(150))",
                    modelInfo: nil,
                    responseTime: elapsed
                )
            }

            let resolvedEffort = OpenAIReasoningEffortResolver.resolve(
                storedEffort: reasoningEffort,
                for: model,
                logContext: "api_tester"
            )
            let responsesBody: [String: Any] = [
                "model": model,
                "reasoning": ["effort": resolvedEffort.rawValue],
                "input": [
                    [
                        "role": "developer",
                        "content": [["type": "input_text", "text": "Reply with OK."]]
                    ],
                    [
                        "role": "user",
                        "content": [["type": "input_text", "text": "Say OK"]]
                    ]
                ]
            ]
            let responsesRequest = try makeRequest(url: responsesURL, body: responsesBody)
            let (data, response) = try await URLSession.shared.data(for: responsesRequest)
            let elapsed = Date().timeIntervalSince(startTime)

            guard let httpResponse = response as? HTTPURLResponse else {
                return APITestResult(success: false, message: "Invalid response", modelInfo: nil, responseTime: elapsed)
            }

            if httpResponse.statusCode == 200 {
                return APITestResult(
                    success: true,
                    message: "API key valid",
                    modelInfo: parseModelInfo(data) ?? model,
                    responseTime: elapsed
                )
            }

            if httpResponse.statusCode == 401 {
                return APITestResult(success: false, message: "Invalid API key", modelInfo: nil, responseTime: elapsed)
            }

            let errorMessage = parseErrorMessage(data)
            if shouldFallbackToChat(status: httpResponse.statusCode, errorMessage: errorMessage) {
                let chatRequest = try makeRequest(url: chatURL, body: chatBody)
                let (chatData, chatResponse) = try await URLSession.shared.data(for: chatRequest)
                let chatElapsed = Date().timeIntervalSince(startTime)

                guard let chatHTTP = chatResponse as? HTTPURLResponse else {
                    return APITestResult(success: false, message: "Invalid response", modelInfo: nil, responseTime: chatElapsed)
                }

                if chatHTTP.statusCode == 200 {
                    return APITestResult(
                        success: true,
                        message: "API key valid",
                        modelInfo: parseModelInfo(chatData) ?? model,
                        responseTime: chatElapsed
                    )
                }

                if chatHTTP.statusCode == 401 {
                    return APITestResult(success: false, message: "Invalid API key", modelInfo: nil, responseTime: chatElapsed)
                }

                let chatErrorMessage = parseErrorMessage(chatData)
                if chatHTTP.statusCode == 404 {
                    return APITestResult(
                        success: false,
                        message: "Model not found: \(model)",
                        modelInfo: nil,
                        responseTime: chatElapsed
                    )
                }

                return APITestResult(
                    success: false,
                    message: "HTTP \(chatHTTP.statusCode): \(chatErrorMessage.prefix(150))",
                    modelInfo: nil,
                    responseTime: chatElapsed
                )
            }

            if httpResponse.statusCode == 404 {
                return APITestResult(success: false, message: "Model not found: \(model)", modelInfo: nil, responseTime: elapsed)
            }

            return APITestResult(
                success: false,
                message: "HTTP \(httpResponse.statusCode): \(errorMessage.prefix(150))",
                modelInfo: nil,
                responseTime: elapsed
            )
        } catch {
            let elapsed = Date().timeIntervalSince(startTime)
            return APITestResult(success: false, message: "Network error: \(error.localizedDescription)", modelInfo: nil, responseTime: elapsed)
        }
    }
    
    /// Test Azure OpenAI API
    static func testAzureOpenAI(apiKey: String, endpoint: String, deployment: String, apiVersion: String) async -> APITestResult {
        let startTime = Date()
        
        // Clean endpoint
        var cleanEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanEndpoint.hasSuffix("/") {
            cleanEndpoint = String(cleanEndpoint.dropLast())
        }
        
        let urlString = "\(cleanEndpoint)/openai/deployments/\(deployment)/chat/completions?api-version=\(apiVersion)"
        guard let url = URL(string: urlString) else {
            return APITestResult(success: false, message: "Invalid endpoint URL", modelInfo: nil, responseTime: 0)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "api-key")
        request.timeoutInterval = 30
        
        // Use max_completion_tokens for newer models (GPT-5+, o1, etc.)
        let body: [String: Any] = [
            "max_completion_tokens": 10,
            "messages": [["role": "user", "content": "Say OK"]]
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            let elapsed = Date().timeIntervalSince(startTime)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                return APITestResult(success: false, message: "Invalid response", modelInfo: nil, responseTime: elapsed)
            }
            
            if httpResponse.statusCode == 200 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let actualModel = json["model"] as? String {
                    return APITestResult(success: true, message: "API key valid", modelInfo: "\(deployment) (\(actualModel))", responseTime: elapsed)
                }
                return APITestResult(success: true, message: "API key valid", modelInfo: deployment, responseTime: elapsed)
            } else if httpResponse.statusCode == 401 {
                return APITestResult(success: false, message: "Invalid API key", modelInfo: nil, responseTime: elapsed)
            } else if httpResponse.statusCode == 404 {
                return APITestResult(success: false, message: "Deployment '\(deployment)' not found", modelInfo: nil, responseTime: elapsed)
            } else {
                let errorText = String(data: data, encoding: .utf8) ?? "Unknown"
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let error = json["error"] as? [String: Any],
                   let msg = error["message"] as? String {
                    return APITestResult(success: false, message: "HTTP \(httpResponse.statusCode): \(msg.prefix(100))", modelInfo: nil, responseTime: elapsed)
                }
                return APITestResult(success: false, message: "HTTP \(httpResponse.statusCode): \(errorText.prefix(100))", modelInfo: nil, responseTime: elapsed)
            }
        } catch {
            let elapsed = Date().timeIntervalSince(startTime)
            return APITestResult(success: false, message: "Network error: \(error.localizedDescription)", modelInfo: nil, responseTime: elapsed)
        }
    }
}
