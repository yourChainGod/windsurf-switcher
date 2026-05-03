//
//  AccountStore.swift
//  Core
//
//  账号持久化：JSON 文件 + atomic write（写 .tmp 后 rename）。
//  路径：~/Library/Application Support/com.windsurfswitcher.native/accounts.json
//
//  与旧 store.rs 行为对齐：
//    - upsert：同 id 替换；同 sessionToken（不同 id）合并 id+addedAt 复用
//    - delete by id
//    - update<F>(id, mutate)：闭包改完再保存
//
//  并发：AccountStore actor 化。所有读写都过 actor 串行。
//

import Foundation

/// 持久化文件根结构。`version` 给将来 schema 演进留口子。
struct StoreFile: Codable {
    var version: Int
    var accounts: [Account]

    init(version: Int = 1, accounts: [Account] = []) {
        self.version = version
        self.accounts = accounts
    }
}

public enum AccountStoreError: Error, CustomStringConvertible {
    case dataDirectoryUnavailable
    case ioFailure(path: String, underlying: Error)

    public var description: String {
        switch self {
        case .dataDirectoryUnavailable:
            return "could not locate ~/Library/Application Support"
        case .ioFailure(let path, let err):
            return "I/O failure at \(path): \(err)"
        }
    }
}

/// 主数据目录：`~/Library/Application Support/com.windsurfswitcher.native/`。
public func defaultDataDirectory() throws -> URL {
    let fm = FileManager.default
    guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
        throw AccountStoreError.dataDirectoryUnavailable
    }
    return base.appendingPathComponent("com.windsurfswitcher.native", isDirectory: true)
}

/// 旧版数据目录（迁移源）。
public func legacyDataDirectory() throws -> URL {
    let fm = FileManager.default
    guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
        throw AccountStoreError.dataDirectoryUnavailable
    }
    return base.appendingPathComponent("com.windsurf.switcher", isDirectory: true)
}

public actor AccountStore {
    private let path: URL
    private var file: StoreFile

    /// 用默认路径打开（自动创建目录）。
    public static func openDefault() async throws -> AccountStore {
        let dir = try defaultDataDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("accounts.json")
        return try await AccountStore(path: path)
    }

    public init(path: URL) async throws {
        self.path = path
        if FileManager.default.fileExists(atPath: path.path) {
            do {
                let raw = try Data(contentsOf: path)
                let decoder = AccountStore.makeDecoder()
                self.file = (try? decoder.decode(StoreFile.self, from: raw)) ?? StoreFile()
            } catch {
                throw AccountStoreError.ioFailure(path: path.path, underlying: error)
            }
        } else {
            self.file = StoreFile()
        }
    }

    public var dataPath: URL { path }

    public func list() -> [Account] { file.accounts }

    public func get(id: UUID) -> Account? {
        file.accounts.first(where: { $0.id == id })
    }

    /// upsert：同 id 替换；否则同 sessionToken 复用 id；否则追加。
    @discardableResult
    public func upsert(_ account: Account) throws -> Account {
        var merged = account
        if let idx = file.accounts.firstIndex(where: { $0.id == account.id }) {
            file.accounts[idx] = merged
        } else if let idx = file.accounts.firstIndex(where: { $0.sessionToken == account.sessionToken }) {
            // 同 token 视为同账号，复用 id + addedAt
            let existing = file.accounts[idx]
            merged.id = existing.id
            merged.addedAt = existing.addedAt
            file.accounts[idx] = merged
        } else {
            file.accounts.append(merged)
        }
        try save()
        return merged
    }

    public func delete(id: UUID) throws {
        file.accounts.removeAll(where: { $0.id == id })
        try save()
    }

    /// 闭包式更新：改完自动持久化。返回被改后的副本（id 不存在 → nil）。
    @discardableResult
    public func update(id: UUID, _ mutate: (inout Account) -> Void) throws -> Account? {
        guard let idx = file.accounts.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        mutate(&file.accounts[idx])
        try save()
        return file.accounts[idx]
    }

    /// 整批替换（数据迁移用）。
    public func replaceAll(_ accounts: [Account]) throws {
        file.accounts = accounts
        try save()
    }

    // MARK: - Persistence

    private func save() throws {
        let encoder = AccountStore.makeEncoder()
        let data: Data
        do {
            data = try encoder.encode(file)
        } catch {
            throw AccountStoreError.ioFailure(path: path.path, underlying: error)
        }
        try atomicWrite(data: data, to: path)
    }

    /// 写 .tmp + rename 原子写入。失败保留旧文件不损坏。
    private func atomicWrite(data: Data, to target: URL) throws {
        let tmp = target.deletingPathExtension().appendingPathExtension("json.tmp")
        do {
            try data.write(to: tmp, options: [.atomic])
        } catch {
            throw AccountStoreError.ioFailure(path: tmp.path, underlying: error)
        }
        // FileManager.replaceItemAt 会保留 ACL / xattr，比 moveItem 更稳。
        if FileManager.default.fileExists(atPath: target.path) {
            do {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: tmp)
            } catch {
                throw AccountStoreError.ioFailure(path: target.path, underlying: error)
            }
        } else {
            do {
                try FileManager.default.moveItem(at: tmp, to: target)
            } catch {
                throw AccountStoreError.ioFailure(path: target.path, underlying: error)
            }
        }
    }

    // MARK: - Codec

    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }
}
