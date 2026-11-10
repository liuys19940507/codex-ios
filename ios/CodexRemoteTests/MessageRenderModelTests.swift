import XCTest
@testable import CodexRemote

final class MessageRenderModelTests: XCTestCase {
    @MainActor
    func testContinuousUpdatesAdvanceAtEachThrottleBoundaryBeforeCompletion() async {
        let clock = RenderPause()
        let model = MessageRenderModel(pause: { await clock.wait() })
        model.update("起始😀\r\n")
        await expect { model.blocks.map(\.raw).joined() == "起始😀\r\n" }
        await expect { await clock.waitingCount == 1 }
        for index in 1...40 { model.update("持续输出 \(index) 中文😀\r\n") }
        XCTAssertEqual(model.blocks.map(\.raw).joined(), "起始😀\r\n")
        await clock.tick()
        await expect { model.blocks.map(\.raw).joined() == "持续输出 40 中文😀\r\n" }
        await expect { await clock.waitingCount == 1 }
        for index in 41...80 { model.update("持续输出 \(index) 中文😀\r\n") }
        await clock.tick()
        await expect { model.blocks.map(\.raw).joined() == "持续输出 80 中文😀\r\n" }
        await expect { await clock.waitingCount == 1 }
        model.update("完整结束😀\r\n")
        await clock.tick()
        await expect { model.blocks.map(\.raw).joined() == "完整结束😀\r\n" }
        model.cancel(); await clock.finish()
    }

    @MainActor
    func testCancelledOlderParseCannotOverwriteNewerRenderedText() async throws {
        let clock = RenderPause(), parser = HeldMessageParser()
        let model = MessageRenderModel(pause: { await clock.wait() }, parse: { await parser.parse($0) })
        model.update("旧回复")
        await expect { await parser.contains("旧回复") }
        model.cancel(); model.update("新回复😀")
        await expect { await parser.contains("新回复😀") }
        await parser.finish("新回复😀")
        await expect { model.blocks.map(\.raw).joined() == "新回复😀" }
        await parser.finish("旧回复")
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(model.blocks.map(\.raw).joined(), "新回复😀")
        model.cancel(); await clock.finish()
    }

    @MainActor
    private func expect(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Rendering state did not advance", file: file, line: line)
    }
}

private actor RenderPause {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var waitingCount: Int { waiters.count }
    func wait() async { await withCheckedContinuation { waiters.append($0) } }
    func tick() { if !waiters.isEmpty { waiters.removeFirst().resume() } }
    func finish() { let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
}

private actor HeldMessageParser {
    private var pending: [String: CheckedContinuation<[MessageBlock], Never>] = [:]
    func parse(_ text: String) async -> [MessageBlock] { await withCheckedContinuation { pending[text] = $0 } }
    func contains(_ text: String) -> Bool { pending[text] != nil }
    func finish(_ text: String) { pending.removeValue(forKey: text)?.resume(returning: MessageDocument.parse(text)) }
}
