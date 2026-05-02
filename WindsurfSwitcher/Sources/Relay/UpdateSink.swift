//
//  UpdateSink.swift
//  Relay
//
//  把 Pool 的 record_* 产出的 AccountUpdate 落库 / 上抛到 UI；
//  把 server.rs 的 /__relay/accounts POST 入库到 store。
//
//  Pool 不直接持有 store 引用——这两个 protocol 解耦让 lib 可单独测试。
//

import Foundation

/// Pool 修改账号状态后调用此 sink 持久化。
public protocol UpdateSink: Sendable {
    func apply(_ update: AccountUpdate) async
}

public struct AccountSinkError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public init(_ m: String) { self.message = m }
    public var description: String { message }
}

/// 外部 POST /__relay/accounts 时调用此 sink，把 token 上 store。
public protocol AccountSink: Sendable {
    /// 返回 (accountId, was_new) ；token 已存在时 was_new=false。
    func add(token: String, label: String?) async -> Result<(String, Bool), AccountSinkError>
}

/// 占位实现，给单元测试用。
public struct NoopUpdateSink: UpdateSink {
    public init() {}
    public func apply(_ update: AccountUpdate) async {}
}

public struct NoopAccountSink: AccountSink {
    public init() {}
    public func add(token: String, label: String?) async -> Result<(String, Bool), AccountSinkError> {
        .failure(AccountSinkError("no account sink configured"))
    }
}
