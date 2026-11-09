import Foundation

func reduce(snapshot: Snapshot, event: Envelope) -> Snapshot {
    var thread = snapshot.thread, items = snapshot.items, pending = snapshot.pending
    func decoded<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = try? JSONEncoder().encode(event.data) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    func upsert(_ item: Item) {
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
        else { items.append(item) }
    }
    func unknown() {
        upsert(Item(id: "unknown:\(event.cursor.epoch):\(event.cursor.seq)", turnId: thread.activeTurnId ?? "", kind: "unknown",
                    text: "暂不支持的活动：\(event.type)", data: .object(["eventType": .string(event.type)])))
    }
    if event.threadId == thread.id {
        switch event.type {
        case "thread/upsert":
            if let value = decoded(ThreadSummary.self), value.id == thread.id { thread = value } else { unknown() }
        case "item/upsert", "activity/unknown":
            if let value = decoded(Item.self) { upsert(value) } else { unknown() }
        case "item/delta":
            struct Delta: Decodable { let id: String; let turnId: String; let text: String }
            if let delta = decoded(Delta.self) {
                if let index = items.firstIndex(where: { $0.id == delta.id }) {
                    let completed: Bool
                    if case .object(let data) = items[index].data { completed = data["completed"] == .bool(true) } else { completed = false }
                    if !completed && items[index].turnId == delta.turnId { items[index].text += delta.text }
                } else {
                    upsert(Item(id: delta.id, turnId: delta.turnId, kind: "agentMessage", text: delta.text,
                                data: .object(["prefixComplete": .bool(false), "completed": .bool(false)])))
                }
            } else { unknown() }
        case "pending/upsert":
            if let value = decoded(Pending.self), value.threadId == thread.id {
                if let index = pending.firstIndex(where: { $0.id == value.id }) { pending[index] = value } else { pending.append(value) }
            } else { unknown() }
        case "pending/resolved":
            struct Resolved: Decodable { let id: String }
            if let value = decoded(Resolved.self) { pending.removeAll { $0.id == value.id } } else { unknown() }
        default: unknown()
        }
    }
    return Snapshot(cursor: event.cursor, thread: thread, items: items, itemsCursor: snapshot.itemsCursor, pending: pending, policy: snapshot.policy)
}
