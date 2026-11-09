import Foundation

private struct HTTPFailure: Decodable { let message: String }

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor URLSessionTransport: BridgeTransport {
    private let server: ServerConfiguration
    private let token: String
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?

    init(server: ServerConfiguration, token: String, configuration: URLSessionConfiguration = .ephemeral) {
        self.server = server; self.token = token
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    nonisolated static func makeRequest(server: ServerConfiguration, token: String, path: String,
                                        method: String = "GET", body: Data? = nil) throws -> URLRequest {
        guard !token.isEmpty else { throw ConnectionError.missingCredential }
        guard path.hasPrefix("/v1/"), !path.contains("\\"),
              let url = URL(string: path, relativeTo: server.baseURL)?.absoluteURL,
              url.host == server.baseURL.host, url.scheme == server.baseURL.scheme,
              url.port == server.baseURL.port, url.user == nil, url.password == nil,
              url.fragment == nil, url.standardized.path.hasPrefix("/v1/") else {
            throw ConnectionError.invalidPath
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    func get<T: Decodable & Sendable>(_ path: String, as: T.Type) async throws -> T {
        try await send(Self.makeRequest(server: server, token: token, path: path), as: T.self)
    }

    func command(_ command: Command) async throws -> Operation {
        try await send(Self.makeRequest(server: server, token: token, path: "/v1/commands",
                                        method: "POST", body: JSONEncoder().encode(command)), as: Operation.self)
    }

    private func send<T: Decodable>(_ request: URLRequest, as: T.Type) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ConnectionError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(HTTPFailure.self, from: data).message) ?? "连接请求未成功，请检查服务地址和配对令牌。"
            throw ConnectionError.server(response.statusCode, message)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    nonisolated func events(after: Cursor?) -> AsyncThrowingStream<EventFrame, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.receiveEvents(after: after, continuation: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func receiveEvents(after: Cursor?, continuation: AsyncThrowingStream<EventFrame, Error>.Continuation) async {
        var activeSocket: URLSessionWebSocketTask?
        do {
            var components = URLComponents()
            components.path = "/v1/events"
            if let after { components.queryItems = [URLQueryItem(name: "epoch", value: after.epoch), URLQueryItem(name: "after", value: String(after.seq))] }
            var request = try Self.makeRequest(server: server, token: token, path: components.string!)
            var url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            url.scheme = server.baseURL.scheme == "https" ? "wss" : "ws"
            request.url = url.url
            let ws = session.webSocketTask(with: request)
            activeSocket = ws
            socket?.cancel(with: .goingAway, reason: nil)
            socket = ws; ws.resume()
            while !Task.isCancelled {
                let message = try await ws.receive()
                let data: Data
                switch message {
                case .data(let bytes): data = bytes
                case .string(let text): data = Data(text.utf8)
                @unknown default: throw ConnectionError.invalidResponse
                }
                struct Control: Decodable { let type: String }
                if (try? JSONDecoder().decode(Control.self, from: data).type) == "resync_required" {
                    continuation.yield(.resyncRequired)
                } else { continuation.yield(.event(try JSONDecoder().decode(Envelope.self, from: data))) }
            }
            continuation.finish()
        } catch { continuation.finish(throwing: error) }
        activeSocket?.cancel(with: .goingAway, reason: nil)
    }

    func close() async {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session.invalidateAndCancel()
    }
}
