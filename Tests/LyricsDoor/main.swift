import Foundation

// 「歌词进播放器」状态机的回归测试（纯 Foundation，不需要设备 / Theos）。
//
// 跑法（需要 Swift 工具链；本仓库本机没有，所以由 CI 跑）：
//   swiftc Sources/EeveeSpotify/Appearance/LyricsDoorPhase.swift \
//          Sources/EeveeSpotify/Appearance/LyricsDoor.swift \
//          Tests/LyricsDoor/main.swift \
//          -o /tmp/lyrics-door-tests && /tmp/lyrics-door-tests
//
// 锁的是**整组操作**与两条窗口的寿命：点开 / 失败 / 重试 / 过期 / 收尾 / 离开页面。
// 每一条都对应一个真机上修过的回归（"漏大封面" / "点了没反应" / "关掉之后留残迹"）。

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}

private let t0: CFAbsoluteTime = 5_000

// MARK: - 刚建出来：全关

var door = LyricsDoor()
require(door.isOpen == false && door.wantsOpen == false, "a fresh door is closed")
require(door.pageLeaving == false, "a fresh door is not leaving")
require(door.phase(isLive: false) == .closed, "a fresh door has no phase yet")
require(door.intentStillValid(now: t0, isLive: false) == false, "no intent, nothing to keep alive")
require(door.retryWindowOpen(now: t0) == false, "no retry window is armed")

// MARK: - 点开：意图与寿命一起立

door.openIntent(at: t0)
require(door.wantsOpen, "opening an intent must set the intent")
require(door.intentUntil == t0 + LyricsDoor.intentLifetime, "the intent must carry its lifetime")
require(door.phase(isLive: false) == .opening, "an intent with nothing mounted is opening")
require(door.intentStillValid(now: t0 + 0.5, isLive: false) == true, "the intent holds inside its window")
require(door.intentStillValid(now: t0 + 1.0, isLive: false) == false, "the intent expires at its deadline")

// MARK: - 第一拍量不到：重试窗口只武装一次、不往后推

door.armRetryWindowIfNeeded(at: t0)
require(door.retryUntil == t0 + LyricsDoor.retryWindow, "the first failure arms the retry window")
let armedOnce = door.retryUntil
door.armRetryWindowIfNeeded(at: t0 + 1.0)
require(
    door.retryUntil == armedOnce,
    "a later failure inside the window must NOT push the deadline - that would poll forever"
)
require(door.retryWindowOpen(now: t0 + 2.4) == true, "the retry window is open before its deadline")
require(door.retryWindowOpen(now: t0 + 2.5) == false, "the retry window closes at its deadline")

// MARK: - 铺上了：意图一直作数（原生封面继续被按住）

door = LyricsDoor()
door.openIntent(at: t0)
door.isOpen = true
require(door.phase(isLive: true) == .open, "a live layer is open")
require(
    door.intentStillValid(now: t0 + 600, isLive: true) == true,
    "once mounted the intent never expires - that is what keeps the native cover down"
)
door.clearRetryWindow()
require(door.retryWindowOpen(now: t0) == false, "a successful mount clears the retry window")

// MARK: - 过期而什么都没铺上：撤意图 + 清窗口（"封面被按着、我们什么都没画"）

door = LyricsDoor()
door.openIntent(at: t0)
door.armRetryWindowIfNeeded(at: t0)
let late = t0 + 2.0
require(door.intentStillValid(now: late, isLive: false) == false, "the intent has expired")
door.expireIntent()
door.clearRetryWindow()
require(door.wantsOpen == false, "the expired intent must be withdrawn")
require(door.intentUntil == 0, "the expiry deadline must be cleared with it")
require(door.retryWindowOpen(now: late) == false, "the retry window goes with it")
require(door.phase(isLive: false) == .closed, "expired with nothing drawn is closed")

// MARK: - 收起：整组归位（漏一项就会在下一程留残迹）

door = LyricsDoor()
door.openIntent(at: t0)
door.isOpen = true
door.armRetryWindowIfNeeded(at: t0)
door.pageWillLeave()
require(door.phase(isLive: true) == .closing, "leaving wins over a live layer")

door.close()
require(door.isOpen == false, "close must drop isOpen")
require(door.wantsOpen == false, "close must drop the intent")
require(door.intentUntil == 0, "close must clear the intent deadline")
require(door.retryUntil == 0, "close must clear the retry window")
require(door.pageLeaving == false, "close must clear the leaving flag")
require(door.phase(isLive: false) == .closed, "a closed door is closed")

// ⚠️ 这条是"关完之后每一项都干净"的**逐项**断言：`close()` 少清一项，这里就红。
door = LyricsDoor()
door.openIntent(at: t0)
door.isOpen = true
door.armRetryWindowIfNeeded(at: t0)
door.pageWillLeave()
door.coverGeneration = 7
door.close()
let snapshot = (door.isOpen, door.wantsOpen, door.intentUntil, door.retryUntil, door.pageLeaving)
require(
    snapshot == (false, false, 0, 0, false),
    "close() must leave exactly one clean state"
)
require(door.coverGeneration == 7, "close() must NOT touch the morph token - it is not state")

// MARK: - 取消令牌：单调递增，收尾里比对的是"有没有被新的一次顶掉"

door = LyricsDoor()
let first = door.nextCoverGeneration()
let second = door.nextCoverGeneration()
require(first == 1 && second == 2, "the morph token is monotonic")
require(first != door.coverGeneration, "an older token must be recognisable as stale")
require(second == door.coverGeneration, "the newest token matches the current one")

// MARK: - 一趟完整的"进页面 → 展开 → 换歌 → 离页"

door = LyricsDoor()
door.pageDidAppear()
require(door.phase(isLive: false) == .closed, "entering the page does not open anything by itself")

door.openIntent(at: t0)
require(door.phase(isLive: false) == .opening, "the remembered state re-opens into opening")

door.isOpen = true
door.clearRetryWindow()
require(door.phase(isLive: true) == .open, "the mount settles into open")

door.armRetryWindowIfNeeded(at: t0 + 10)
require(door.retryWindowOpen(now: t0 + 10) == true, "a later track change can arm a fresh window")

door.pageWillLeave()
require(door.phase(isLive: true) == .closing, "the exit transition holds everything still")

door.close()
require(door.phase(isLive: false) == .closed, "the teardown ends closed")

print("lyrics door: all assertions passed")
