//
//  RemoteMemoryStore.swift
//  glasse
//
//  Drop-in replacement for MemoryStore that backs the conductor's memory with the
//  Redis-vector memory-service (via MemoryClient) for PERSISTENT, SEMANTIC, cross-
//  session recall — while keeping an on-device MemoryStore as a write-through cache so
//  recall(matching:)/promptBlock/notes stay SYNCHRONOUS and the app behaves identically
//  offline. With no backend configured (MemoryClient.baseURL empty) every remote call
//  no-ops, so this is byte-for-byte the old on-device behavior until the service is
//  deployed. See memory-service/ for the backend and REDIS_SETUP.md to provision it.
//

import Foundation
import Observation

@Observable
@MainActor
final class RemoteMemoryStore {
    /// On-device cache = source of truth for the SYNCHRONOUS API the conductor calls
    /// inline. Reads delegate here; because MemoryStore is itself @Observable, views
    /// reading `notes`/`promptBlock` still update reactively.
    private let local = MemoryStore()
    /// HTTPS client to the memory-service backend (no-op until MemoryClient.baseURL is set).
    private let client = MemoryClient()

    // MARK: - MemoryStore-compatible API (drop-in)

    var notes: [MemoryNote] { local.notes }
    var promptBlock: String { local.promptBlock }
    func recall(matching query: String) -> [MemoryNote] { local.recall(matching: query) }
    func forgetAll() { local.forgetAll() }

    /// Explicit "remember that I…": cache locally (immediate + offline + persisted) AND
    /// push to the backend (fire-and-forget) for cross-session/device persistence.
    func remember(category: String, text: String) {
        local.remember(category: category, text: text)
        client.remember(text, type: category)
    }

    // MARK: - Backend-only enhancements

    /// BEFORE a conductor turn: pull semantically-relevant memories for `query` from the
    /// backend and fold any NEW ones into the local cache, so the SYNCHRONOUS promptBlock
    /// the system prompt reads includes cross-session memories. No-op without a backend.
    func prime(query: String) async {
        let remote = await client.recall(query: query)
        guard !remote.isEmpty else { return }
        let known = Set(local.notes.map { $0.text })
        for text in remote where !known.contains(text) {
            local.remember(category: "recalled", text: text)
        }
    }

    /// AFTER the reply: let the backend extract + store durable preferences (fire-and-forget).
    func learn(userText: String, assistantText: String) {
        client.learn(userText: userText, assistantText: assistantText)
    }
}
