import Foundation

protocol GenerationHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionGenerationTransport: GenerationHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw GenerationError.invalidResponse
        }
        return (data, response)
    }
}

enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var outputURL: URL? {
        switch self {
        case .string(let value): URL(string: value)
        case .array(let values): values.count == 1 ? values[0].outputURL : nil
        default: nil
        }
    }
}

struct ReplicatePrediction: Codable, Sendable {
    struct Links: Codable, Sendable {
        let get: URL?
        let web: URL?
    }

    let id: String
    let status: String
    let output: JSONValue?
    let error: String?
    let urls: Links
}

struct ReplicateClient: Sendable {
    let token: String
    let transport: any GenerationHTTPTransport
    let retryDelaysNanoseconds: [UInt64]

    init(
        token: String,
        transport: any GenerationHTTPTransport = URLSessionGenerationTransport(),
        retryDelaysNanoseconds: [UInt64] = [500_000_000, 1_000_000_000, 2_000_000_000, 4_000_000_000]
    ) {
        self.token = token
        self.transport = transport
        self.retryDelaysNanoseconds = retryDelaysNanoseconds
    }

    func submit(modelID: String, input: [String: JSONValue]) async throws -> ReplicatePrediction {
        guard let url = URL(string: "https://api.replicate.com/v1/models/\(modelID)/predictions") else {
            throw GenerationError.invalidResponse
        }
        var request = authorizedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["input": JSONValue.object(input)])

        let response: (Data, HTTPURLResponse)
        do {
            response = try await transport.data(for: request)
        } catch {
            throw GenerationError.submissionOutcomeUnknown
        }
        return try decodePrediction(data: response.0, response: response.1)
    }

    func fetchPrediction(url: URL) async throws -> ReplicatePrediction {
        var attempt = 0
        while true {
            do {
                let (data, response) = try await transport.data(for: authorizedRequest(url: url))
                if response.statusCode == 429 || (500...599).contains(response.statusCode) {
                    throw RetryableResponse(data: data, status: response.statusCode)
                }
                return try decodePrediction(data: data, response: response)
            } catch let error as GenerationError {
                throw error
            } catch {
                guard attempt < retryDelaysNanoseconds.count else {
                    if let response = error as? RetryableResponse {
                        throw apiError(status: response.status, data: response.data)
                    }
                    throw error
                }
                let delay = retryDelaysNanoseconds[attempt]
                attempt += 1
                if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            }
        }
    }

    private func authorizedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("paperwall/1", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func decodePrediction(data: Data, response: HTTPURLResponse) throws -> ReplicatePrediction {
        guard (200...299).contains(response.statusCode) else {
            throw apiError(status: response.statusCode, data: data)
        }
        do {
            return try JSONDecoder().decode(ReplicatePrediction.self, from: data)
        } catch {
            throw GenerationError.invalidResponse
        }
    }

    private func apiError(status: Int, data: Data) -> GenerationError {
        let detail = String(data: data.prefix(1_000), encoding: .utf8) ?? "No response detail"
        return .api(status: status, detail: detail)
    }
}

private struct RetryableResponse: Error {
    let data: Data
    let status: Int
}
