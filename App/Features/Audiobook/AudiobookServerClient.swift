import Foundation

struct AudiobookServerClient {
    let configuration: AudiobookPairingConfiguration
    var session: URLSession = .shared

    func health() async throws -> AudiobookServerHealth {
        let request = authorizedRequest(path: "v1/health")
        let (data, response) = try await session.data(for: request)
        return try decode(AudiobookServerHealth.self, data: data, response: response)
    }

    func submit(_ job: AudiobookJobRequest) async throws -> AudiobookJobStatus {
        var request = authorizedRequest(path: "v1/jobs")
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(job)
        let (data, response) = try await session.data(for: request)
        return try decode(AudiobookJobStatus.self, data: data, response: response)
    }

    func submit(_ jobs: [AudiobookJobRequest]) async throws -> AudiobookBatchSubmission {
        guard !jobs.isEmpty else {
            return AudiobookBatchSubmission(
                protocolVersion: AudiobookProtocol.version,
                acceptedCount: 0
            )
        }
        var request = authorizedRequest(path: "v1/jobs/batch")
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(AudiobookBatchJobRequest(jobs: jobs))
        let (data, response) = try await session.data(for: request)
        return try decode(AudiobookBatchSubmission.self, data: data, response: response)
    }

    func status(jobID: String) async throws -> AudiobookJobStatus {
        let request = authorizedRequest(path: "v1/jobs/\(jobID)")
        let (data, response) = try await session.data(for: request)
        return try decode(AudiobookJobStatus.self, data: data, response: response)
    }

    func bookStatus(bookID: String, voice: String, speed: Double) async throws -> AudiobookBookStatus {
        let request = authorizedBookRequest(
            path: "v1/books/status",
            bookID: bookID,
            voice: voice,
            speed: speed
        )
        let (data, response) = try await session.data(for: request)
        return try decode(AudiobookBookStatus.self, data: data, response: response)
    }

    func download(jobID: String, to destination: URL) async throws {
        let request = authorizedRequest(path: "v1/jobs/\(jobID)/audio")
        let (temporaryURL, response) = try await session.download(for: request)
        try validate(response: response, fallbackData: nil)
        let manager = FileManager.default
        try manager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.moveItem(at: temporaryURL, to: destination)
    }

    func downloadPackage(
        bookID: String,
        voice: String,
        speed: Double,
        to destination: URL
    ) async throws {
        var request = authorizedBookRequest(
            path: "v1/books/package",
            bookID: bookID,
            voice: voice,
            speed: speed
        )
        request.timeoutInterval = 30 * 60
        let (temporaryURL, response) = try await session.download(for: request)
        try validate(response: response, fallbackData: nil)
        let manager = FileManager.default
        try manager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.moveItem(at: temporaryURL, to: destination)
    }

    private func authorizedRequest(path: String) -> URLRequest {
        let url = configuration.baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func authorizedBookRequest(
        path: String,
        bookID: String,
        voice: String,
        speed: Double
    ) -> URLRequest {
        let base = configuration.baseURL.appending(path: path)
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "book_id", value: bookID),
            URLQueryItem(name: "voice", value: voice),
            URLQueryItem(name: "speed", value: String(format: "%.2f", speed))
        ]
        var request = URLRequest(url: components?.url ?? base)
        request.timeoutInterval = 30
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func decode<T: Decodable>(
        _ type: T.Type,
        data: Data,
        response: URLResponse
    ) throws -> T {
        try validate(response: response, fallbackData: data)
        let value = try JSONDecoder().decode(type, from: data)
        if let health = value as? AudiobookServerHealth,
           health.protocolVersion != AudiobookProtocol.version {
            throw AudiobookClientError.protocolMismatch
        }
        if let status = value as? AudiobookJobStatus,
           status.protocolVersion != AudiobookProtocol.version {
            throw AudiobookClientError.protocolMismatch
        }
        if let status = value as? AudiobookBookStatus,
           status.protocolVersion != AudiobookProtocol.version {
            throw AudiobookClientError.protocolMismatch
        }
        if let submission = value as? AudiobookBatchSubmission,
           submission.protocolVersion != AudiobookProtocol.version {
            throw AudiobookClientError.protocolMismatch
        }
        return value
    }

    private func validate(response: URLResponse, fallbackData: Data?) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AudiobookClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message: String
            if let fallbackData,
               let payload = try? JSONDecoder().decode(ServerErrorPayload.self, from: fallbackData) {
                message = payload.error
            } else {
                message = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            }
            throw AudiobookClientError.server(http.statusCode, message)
        }
    }
}

private struct ServerErrorPayload: Decodable {
    let error: String
}
