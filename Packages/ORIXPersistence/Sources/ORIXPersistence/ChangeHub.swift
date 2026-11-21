// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXPersistence/Sources/ORIXPersistence/ChangeHub.swift
// Description      : Fan-out of store changes to in-process AsyncStreams and,
//                    coalesced, to a Darwin notification other processes can
//                    observe.
// Module           : ORIXPersistence
// Repository       : https://git.spboucher.ai/orix-automation
// Created          : 2026-11-21
// Last Modified    : 2026-11-21
//
// =============================================================================
// AUTHOR & PROFESSIONAL AFFILIATION
// =============================================================================
//
// Author           : Simon-Pierre Boucher
// Position         : Professor of Finance
// Institution      : Université du Québec en Outaouais (UQO)
// Department       : Département des sciences administratives
// Organization     : SP Boucher
//
// Website          : https://spboucher.ai
// Git              : https://git.spboucher.ai
//
// =============================================================================
// OFFICIAL CONTACT DIRECTORY
// =============================================================================
//
// General          : info@spboucher.ai
// Professional     : contact@spboucher.ai
// Direct           : simon@spboucher.ai
// Research         : research@spboucher.ai
// Development      : dev@spboucher.ai
// Support          : support@spboucher.ai
// Security/Admin   : admin@spboucher.ai
// Notifications    : notifications@spboucher.ai
//
// Preferred Contact: support@spboucher.ai
//
// =============================================================================
// COPYRIGHT & INTELLECTUAL PROPERTY
// =============================================================================
//
// Copyright (c) 2026
// Simon-Pierre Boucher
//
// All rights reserved where applicable.
//
// This file is governed by the applicable project license,
// copyright notices, institutional agreements and relevant law.
//
// Unless expressly authorized by the applicable license or
// rights holder, copying, redistribution, sublicensing,
// publication and commercial exploitation are not permitted.
//
// Existing third-party rights and notices remain unaffected.
//
// =============================================================================
// CONFIDENTIALITY & SECURITY
// =============================================================================
//
// Classification   : Public
// Distribution     : Public repository; use is governed by the project license
// Security Contact : admin@spboucher.ai
//
// Access to this source does not independently grant permission
// to redistribute or disclose confidential materials.
//
// Do not embed credentials, private keys, access tokens,
// certificates or confidential personal information.
//
// =============================================================================
// LICENSE & MAINTENANCE
// =============================================================================
//
// License          : Proprietary, all rights reserved (see license file)
// License File     : LICENSE
// Maintainer       : Simon-Pierre Boucher
// Technical Contact: dev@spboucher.ai
//
// =============================================================================
// END OF SP BOUCHER SOURCE HEADER
// =============================================================================

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
