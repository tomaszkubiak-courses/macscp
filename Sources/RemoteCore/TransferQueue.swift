import Foundation

public struct QueueItem: Sendable, Identifiable, Equatable {
    public enum State: Sendable, Equatable { case queued, running, done, failed(String), cancelled }
    public let id: UUID
    public let request: TransferRequest
    public var state: State = .queued
    public var progress = TransferProgress()

    public static func == (a: QueueItem, b: QueueItem) -> Bool {
        a.id == b.id && a.state == b.state && a.progress == b.progress
    }
}

public actor TransferQueue {
    public typealias Connect = @Sendable () async throws -> any RemoteFileSystem

    public var maxParallel: Int
    private let connect: Connect
    private let delegate: any TransferDelegate
    private var onChange: @Sendable ([QueueItem]) -> Void
    private var items: [QueueItem] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var idle: [any RemoteFileSystem] = []
    private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    public init(maxParallel: Int = 2, delegate: any TransferDelegate, connect: @escaping Connect,
                onChange: @escaping @Sendable ([QueueItem]) -> Void = { _ in }) {
        self.maxParallel = maxParallel; self.connect = connect; self.delegate = delegate; self.onChange = onChange
    }

    public var snapshot: [QueueItem] { items }

    public func observe(_ handler: @escaping @Sendable ([QueueItem]) -> Void) {
        onChange = handler
        handler(items)
    }

    public func setMaxParallel(_ n: Int) {
        maxParallel = max(1, n)
        schedule()
    }

    public var isBusy: Bool { items.contains { $0.state == .queued || $0.state == .running } }

    @discardableResult
    public func add(_ request: TransferRequest) -> UUID {
        let item = QueueItem(id: UUID(), request: request)
        items.append(item)
        changed()
        schedule()
        return item.id
    }

    public func cancel(_ id: UUID) {
        if let t = tasks[id] {
            t.cancel()
        } else if let i = items.firstIndex(where: { $0.id == id }), items[i].state == .queued {
            items[i].state = .cancelled
            finish(id)
        }
    }

    public func clearFinished() {
        items.removeAll { $0.state != .queued && $0.state != .running }
        changed()
    }

    public func wait(for id: UUID) async {
        guard let item = items.first(where: { $0.id == id }), item.state == .queued || item.state == .running else { return }
        await withCheckedContinuation { waiters[id, default: []].append($0) }
    }

    public func item(_ id: UUID) -> QueueItem? { items.first { $0.id == id } }

    public func shutdown() async {
        for t in tasks.values { t.cancel() }
        for fs in idle { await fs.disconnect() }
        idle.removeAll()
    }

    private func changed() { onChange(items) }

    private func finish(_ id: UUID) {
        tasks[id] = nil
        changed()
        waiters.removeValue(forKey: id)?.forEach { $0.resume() }
        schedule()
    }

    private func update(_ id: UUID, _ body: (inout QueueItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        body(&items[i])
        changed()
    }

    private func schedule() {
        while tasks.count < maxParallel, let next = items.first(where: { $0.state == .queued }) {
            let id = next.id
            update(id) { $0.state = .running }
            tasks[id] = Task { await self.run(id, next.request) }
        }
    }

    private func run(_ id: UUID, _ request: TransferRequest) async {
        var fs: (any RemoteFileSystem)?
        do {
            fs = idle.popLast()
            if fs == nil { fs = try await connect() }
            let engine = TransferEngine(fs: fs!, delegate: delegate, reconnect: connect) { p in
                Task { await self.update(id) { $0.progress = p } }
            }
            do {
                try await engine.run(request)
                fs = await engine.fs
            } catch {
                fs = await engine.fs
                throw error
            }
            update(id) { $0.state = .done }
        } catch {
            let cancelled = Task.isCancelled || (error as? RemoteError)?.kind == .cancelled || error is CancellationError
            update(id) { $0.state = cancelled ? .cancelled : .failed("\(error)") }

            if cancelled, let f = fs { await f.disconnect(); fs = nil }
        }
        if let fs { idle.append(fs) }
        finish(id)
    }
}
