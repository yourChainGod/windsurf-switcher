//
//  AsyncSemaphore.swift
//  Relay
//
//  per-token 并发栅 + RAII permit。替代 tokio::sync::Semaphore +
//  OwnedSemaphorePermit。
//
//  设计要点：
//    - actor 串行化所有读写，无 race
//    - acquire 时若 current < limit → 立即增；否则挂 continuation 在 waiters 队列
//    - 用 SemaphorePermit 类（class）作 lease 持有；其 deinit 自动 release
//    - permit 即使被 cancel 也能正确释放（防止泄漏导致并发计数永远满）
//
//  注意：Swift 没有 Drop trait，permit 用 class + deinit 模拟。Class 必须不
//  被多份持有；因此 SemaphorePermit 是 final + 不 Sendable（持有者唯一）。
//

import Foundation

public actor AsyncSemaphore {
    public private(set) var limit: Int
    private var current: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(limit: Int) {
        precondition(limit > 0, "AsyncSemaphore limit must be > 0")
        self.limit = limit
    }

    /// 当前正在使用（已 acquire 未 release）的并发数。
    public var inUse: Int { current }

    /// 等待并占一个槽。Cancel 期间安全（不会泄漏）。
    public func acquire() async {
        if current < limit {
            current += 1
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
    }

    /// 释放一个槽：若有 waiter，直接唤醒一个（current 不变）；否则 current -=1。
    public func release() {
        if !waiters.isEmpty {
            let w = waiters.removeFirst()
            w.resume()
        } else {
            current = max(0, current - 1)
        }
    }
}

/// RAII permit：deinit 自动释放。lease 路径用 try await semaphore.acquire 后
/// 包一个 SemaphorePermit 持有，函数返回的 Lease 内嵌它。
public final class SemaphorePermit {
    private let semaphore: AsyncSemaphore
    private var released: Bool = false

    public init(_ semaphore: AsyncSemaphore) {
        self.semaphore = semaphore
    }

    /// 显式释放（幂等）。
    public func release() {
        guard !released else { return }
        released = true
        Task { [semaphore] in await semaphore.release() }
    }

    deinit {
        if !released {
            Task { [semaphore] in await semaphore.release() }
        }
    }
}

extension AsyncSemaphore {
    /// 一站式：await acquire → 返回 RAII permit。
    public func acquirePermit() async -> SemaphorePermit {
        await acquire()
        return SemaphorePermit(self)
    }
}
