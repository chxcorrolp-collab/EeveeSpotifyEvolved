// CADisplayLink 时钟：把播放进度喂给叠加视图 / Apple Music 渲染层。
import Orion
import UIKit
import ObjectiveC
import SwiftUI

// MARK: - 播放时钟

final class WordByWordPlaybackClock {
    static let shared = WordByWordPlaybackClock()

    private var displayLink: CADisplayLink?
    private(set) var currentMs: Double = 0
    var onChange: ((Double) -> Void)?

    func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// 供 Apple Music 渲染层使用的每帧回调。
    /// 与 `onChange` 互斥：挂载时只会设置其中一个。
    var tickHandler: ((Double) -> Void)?

    @objc private func tick() {
        let ms: Double
        if let seconds = WordByWordPositionResolver.shared.currentPositionSeconds() {
            ms = seconds * 1000
        } else {
            ms = currentMs
        }
        currentMs = ms
        onChange?(ms)
        tickHandler?(ms)
    }
}
