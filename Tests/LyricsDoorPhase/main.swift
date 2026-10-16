import Foundation

// 「歌词进播放器」相位机的回归测试（纯 Foundation，不需要设备 / Theos）。
//
// 跑法（需要 Swift 工具链；本仓库本机没有，所以由 CI 跑）：
//   swiftc Sources/EeveeSpotify/Appearance/LyricsDoorPhase.swift \
//          Tests/LyricsDoorPhase/main.swift \
//          -o /tmp/lyrics-door-phase-tests && /tmp/lyrics-door-phase-tests
//
// 锁的是**转换表本身**：六旗标里哪些组合算哪一相、两条窗口什么时候过期、
// 以及"该收尾 / 该按住原生封面"这两条判据的边界。视图怎么动不在这个测试范围。

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}

private let now: CFAbsoluteTime = 1_000

// MARK: - 相位：优先级就是语义

require(
    LyricsDoorRules.phase(isLive: false, wantsOpen: false, pageLeaving: false) == .closed,
    "nothing live and no intent must be closed"
)
require(
    LyricsDoorRules.phase(isLive: false, wantsOpen: true, pageLeaving: false) == .opening,
    "an intent with nothing mounted must be opening"
)
require(
    LyricsDoorRules.phase(isLive: true, wantsOpen: false, pageLeaving: false) == .open,
    "something of ours on screen must be open"
)
require(
    LyricsDoorRules.phase(isLive: true, wantsOpen: true, pageLeaving: false) == .open,
    "mounted beats the intent - open stays open"
)
require(
    LyricsDoorRules.phase(isLive: false, wantsOpen: true, pageLeaving: true) == .closing,
    "the leaving flag must win over the intent"
)
require(
    LyricsDoorRules.phase(isLive: true, wantsOpen: true, pageLeaving: true) == .closing,
    "the leaving flag must win over a mounted layer too"
)
require(
    LyricsDoorRules.phase(isLive: false, wantsOpen: false, pageLeaving: true) == .closing,
    "a leaving page is closing even with nothing mounted"
)

// MARK: - 意图的窗口（wantsOpenNow 的纯版本）
//
// 1.0s 那条窗口存在的原因很具体：进页面第一拍量不到，但原生封面已经在转场里动了。

require(
    LyricsDoorRules.intentStillValid(wantsOpen: false, isLive: false, now: now, intentUntil: now + 1) == false,
    "no intent means nothing to keep alive"
)
require(
    LyricsDoorRules.intentStillValid(wantsOpen: true, isLive: false, now: now, intentUntil: now + 1) == true,
    "an intent inside its window is still valid"
)
require(
    LyricsDoorRules.intentStillValid(wantsOpen: true, isLive: false, now: now + 1, intentUntil: now + 1) == false,
    "the window must expire at its deadline, not after it"
)
require(
    LyricsDoorRules.intentStillValid(wantsOpen: true, isLive: true, now: now + 99, intentUntil: now + 1) == true,
    "once mounted the intent stays valid forever - that is what keeps the native cover down"
)

// MARK: - 重试窗口（2.5s ≈ 5 拍，只武装一次、不往后推）

require(LyricsDoorRules.retryWindowOpen(now: now, retryUntil: now + 2.5) == true, "retry window is open")
require(LyricsDoorRules.retryWindowOpen(now: now + 2.5, retryUntil: now + 2.5) == false, "retry window expires")
require(LyricsDoorRules.retryWindowOpen(now: now, retryUntil: 0) == false, "an unarmed retry window is closed")

// MARK: - 页面收尾：等价于原来那句 `pageLeaving || isOpen || isLive || wantsOpen || 其它`
//
// 逐条把原来的四个旗标代进来，确认等价 —— 这条判据漏掉一项的后果是"页面走掉时该跑的收尾整段被跳过"。

private func teardown(_ isLive: Bool, _ wantsOpen: Bool, _ pageLeaving: Bool, isOpen: Bool, edits: Bool) -> Bool {
    LyricsDoorRules.needsPageTeardown(
        phase: LyricsDoorRules.phase(isLive: isLive, wantsOpen: wantsOpen, pageLeaving: pageLeaving),
        isOpen: isOpen,
        hasPendingEdits: edits
    )
}

require(teardown(false, false, false, isOpen: false, edits: false) == false, "a clean closed page needs no teardown")
require(teardown(false, false, true, isOpen: false, edits: false) == true, "pageLeaving alone must trigger it")
require(teardown(false, false, false, isOpen: true, edits: false) == true, "the lying isOpen alone must trigger it")
require(teardown(false, true, false, isOpen: false, edits: false) == true, "a live intent alone must trigger it")
require(teardown(true, false, false, isOpen: false, edits: false) == true, "a mounted layer alone must trigger it")
require(teardown(false, false, false, isOpen: false, edits: true) == true, "one pending edit must trigger it")

// ⚠️ 这里钉住的正是那个"会撒谎的 isOpen"：`isOpen == true` 而屏上什么都没有 ⇒ 相位是 `.closed`，
//    但收尾**照样要做**（我们可能已经改过别人的视图）。把 `isOpen` 从这条判据里删掉会让这个用例红。
require(
    teardown(false, false, false, isOpen: true, edits: false) == true,
    "phase closed but isOpen true: the teardown must still run"
)

// MARK: - 按住原生封面（coverDidLayOut 的门禁）

require(
    LyricsDoorRules.shouldHoldNativeCover(isOpen: false, isLive: false, intentValid: false) == false,
    "nothing to hold for"
)
require(
    LyricsDoorRules.shouldHoldNativeCover(isOpen: false, isLive: false, intentValid: true) == true,
    "the intent alone must hold it - that is the first frame of the transition"
)
require(
    LyricsDoorRules.shouldHoldNativeCover(isOpen: true, isLive: false, intentValid: false) == true,
    "an attempted mount must hold it even when it failed"
)
require(
    LyricsDoorRules.shouldHoldNativeCover(isOpen: false, isLive: true, intentValid: false) == true,
    "a mounted layer must hold it"
)

// MARK: - 端到端的相位序列：点开 -> 第一拍量不到 -> 窗口过期
//
// 这是用户报过的两条回归的合成场景（"点了没反应" / "按着封面却什么都没画"）。

var phase = LyricsDoorRules.phase(isLive: false, wantsOpen: false, pageLeaving: false)
require(phase == .closed, "start closed")

// 用户点开：意图立起来，这一拍还没铺上。
var wantsOpen = true
let intentUntil = now + 1.0
var retryUntil = now + 2.5
phase = LyricsDoorRules.phase(isLive: false, wantsOpen: wantsOpen, pageLeaving: false)
require(phase == .opening, "the tap must enter opening")

// 同一拍铺失败 ⇒ 重试窗口武装（只武装一次）。
require(LyricsDoorRules.retryWindowOpen(now: now, retryUntil: retryUntil) == true, "the retry window is armed")

// 下一拍铺上了。
phase = LyricsDoorRules.phase(isLive: true, wantsOpen: wantsOpen, pageLeaving: false)
require(phase == .open, "a successful mount must settle into open")
require(
    LyricsDoorRules.intentStillValid(wantsOpen: wantsOpen, isLive: true, now: now + 60, intentUntil: intentUntil) == true,
    "once open the intent never expires - the native cover stays held"
)

// 换一首：意图过期而这一程什么都没铺上 ⇒ 不许留着"封面被按着、我们什么都没画"。
let expired = now + 2.0
require(
    LyricsDoorRules.intentStillValid(wantsOpen: wantsOpen, isLive: false, now: expired, intentUntil: intentUntil) == false,
    "an expired intent must not keep holding the native cover"
)

// 页面要走了：相位进 closing，而收尾判据同时为真；转场里**什么都不做**由调用方负责。
phase = LyricsDoorRules.phase(isLive: false, wantsOpen: false, pageLeaving: true)
require(phase == .closing, "leaving must be closing")
require(
    LyricsDoorRules.needsPageTeardown(phase: phase, isOpen: false, hasPendingEdits: false) == true,
    "a closing page must be torn down once it is really gone"
)

// 收尾之后：回到全关。
wantsOpen = false
retryUntil = 0
phase = LyricsDoorRules.phase(isLive: false, wantsOpen: wantsOpen, pageLeaving: false)
require(phase == .closed, "the teardown must end closed")
require(LyricsDoorRules.retryWindowOpen(now: now + 3, retryUntil: retryUntil) == false, "no retry is armed at rest")

print("lyrics door phase: all assertions passed")
