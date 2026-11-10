import Foundation
import Combine

@MainActor
final class MessageRenderModel: ObservableObject {
    @Published private(set) var blocks: [MessageBlock] = []
    @Published private(set) var revision = 0
    private let pause: @Sendable () async throws -> Void
    private let parse: @Sendable (String) async -> [MessageBlock]
    private var pending: String?
    private var requested: String?
    private var generation = UUID()
    private var worker: Task<Void, Never>?

    init(pause: @escaping @Sendable () async throws -> Void = { try await Task.sleep(nanoseconds: 80_000_000) },
         parse: @escaping @Sendable (String) async -> [MessageBlock] = { text in
             await Task.detached(priority: .userInitiated) { MessageDocument.parse(text) }.value
         }) {
        self.pause = pause; self.parse = parse
    }

    func update(_ text: String) {
        guard requested != text else { return }
        requested = text; pending = text
        guard worker == nil else { return }
        let token = generation
        worker = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.worker = nil } }
            while let value = self.pending, self.generation == token, !Task.isCancelled {
                self.pending = nil
                let rendered = await self.parse(value)
                guard self.generation == token, !Task.isCancelled else { return }
                self.blocks = rendered; self.revision += 1
                // New deltas replace pending text without restarting this wait.
                // An idle renderer exits after one pause rather than polling.
                do { try await self.pause() } catch { return }
            }
        }
    }

    func cancel() {
        generation = UUID(); pending = nil; requested = nil
        worker?.cancel(); worker = nil
    }
}
