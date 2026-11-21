// ORIX OS Automation
// File: Packages/ORIXPersistence/Sources/ORIXPersistence/ChangeHub.swift
// Description: Fan-out of store changes to in-process AsyncStreams and, coalesced, to a Darwin notification other processes can observe.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import notify

final class ChangeHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<StoreChange>.Continuation] = [:]
    private var postPending = false
    private let postsDarwin: Bool
    private let darwinName: String

    init(postsDarwin: Bool, darwinName: String) {
        self.postsDarwin = postsDarwin
        self.darwinName = darwinName
    }

    deinit {
        for (_, c) in continuations { c.finish() }
    }

    /// A new stream that receives every change published after this call. Slow consumers keep the newest 2 048 changes.
    func stream() -> AsyncStream<StoreChange> {
        AsyncStream(bufferingPolicy: .bufferingNewest(2048)) { continuation in
            let id = UUID()
            lock.lock(); continuations[id] = continuation; lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.continuations[id] = nil; self.lock.unlock()
            }
        }
    }

    func publish(_ change: StoreChange) {
        lock.lock()
        let targets = Array(continuations.values)
        let schedule = postsDarwin && !postPending
        if schedule { postPending = true }
        lock.unlock()
        for c in targets { c.yield(change) }
        guard schedule else { return }
        // Bursts (hundreds of events per second) collapse into one cross-process notification every 50 ms.
        let name = darwinName
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            if let self { self.lock.lock(); self.postPending = false; self.lock.unlock() }
            notify_post(name)
        }
    }

    /// Fires each time any process posts `name`. Cancelling the consuming task unregisters.
    static func darwinStream(name: String) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            var token: Int32 = 0
            let status = notify_register_dispatch(name, &token, DispatchQueue.global(qos: .utility)) { _ in
                continuation.yield(())
            }
            guard status == NOTIFY_STATUS_OK else { continuation.finish(); return }
            let registered = token
            continuation.onTermination = { _ in notify_cancel(registered) }
        }
    }
}
