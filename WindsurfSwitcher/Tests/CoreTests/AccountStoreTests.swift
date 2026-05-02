//
//  AccountStoreTests.swift
//  CoreTests
//

import XCTest
@testable import Core

final class AccountStoreTests: XCTestCase {

    private func tempStorePath() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wss-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("accounts.json")
    }

    func testUpsertReplacesById() async throws {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let store = try await AccountStore(path: path)
        let acc = Account(label: "alpha", sessionToken: "tk1")
        try await store.upsert(acc)
        var updated = acc
        updated.label = "alpha-renamed"
        try await store.upsert(updated)

        let list = await store.list()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.label, "alpha-renamed")
    }

    func testUpsertMergesBySessionToken() async throws {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let store = try await AccountStore(path: path)

        let original = Account(label: "first", sessionToken: "tokenA")
        try await store.upsert(original)

        // 不同 id 但相同 token → 应该 merge 到 original 的 id
        let conflict = Account(id: UUID(), label: "second", sessionToken: "tokenA")
        let merged = try await store.upsert(conflict)
        XCTAssertEqual(merged.id, original.id)

        let list = await store.list()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.id, original.id)
        XCTAssertEqual(list.first?.label, "second") // 新 label 生效
    }

    func testDeleteById() async throws {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let store = try await AccountStore(path: path)

        let a = Account(label: "a", sessionToken: "ta")
        let b = Account(label: "b", sessionToken: "tb")
        try await store.upsert(a)
        try await store.upsert(b)
        try await store.delete(id: a.id)

        let list = await store.list()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.id, b.id)
    }

    func testUpdateMutates() async throws {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let store = try await AccountStore(path: path)
        let a = Account(label: "a", sessionToken: "ta")
        try await store.upsert(a)
        let modified = try await store.update(id: a.id) { $0.lastSwitchedAt = Date(timeIntervalSince1970: 1700000000) }
        XCTAssertEqual(modified?.lastSwitchedAt?.timeIntervalSince1970, 1700000000)

        // 重开 store 验证 atomic write 生效
        let store2 = try await AccountStore(path: path)
        let list = await store2.list()
        XCTAssertEqual(list.first?.lastSwitchedAt?.timeIntervalSince1970, 1700000000)
    }

    func testEmptyStoreLoads() async throws {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let store = try await AccountStore(path: path)
        let list = await store.list()
        XCTAssertEqual(list.count, 0)
    }
}
