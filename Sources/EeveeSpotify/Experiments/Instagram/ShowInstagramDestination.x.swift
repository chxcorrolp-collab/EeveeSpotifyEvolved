import Orion
import UIKit

/// 「实验 → 显示 Instagram 分享位」。
///
/// ## 上游是怎么写的（`EeveeSpotifyReincarnated/Sources/EeveeSpotify/Experiments/Instagram/`）
///
/// 它挂两个类、三个方法：
///   · `SPTSharingSDK.canHandleShareDestination(_:)` —— 目标 id 含 `instagram` 就返回 true；
///   · `SPTShare_FoundationImplProperties.isInstagramStoriesCanvasSharingEnabled()` 与
///     `…InstagramDirectMessageSharingEnabled()` —— 直接返回 true。
///
/// ⚠️ **那三个名字在 9.1.88 上一个都不存在**：`dump-9.1.88.txt` 全文搜
/// `SPTSharingSDK` / `SPTShare_FoundationImplProperties` / `SPTSharingSDKDestination`
/// ⇒ **0 命中**。而上游 README 写的目标版本**也是 9.1.88**
/// （`Experiments/Instagram/ShowInstagramDestination.x.swift` 自 initial commit 起没改过）
/// ⇒ 上游那份在这版 Spotify 上**是死代码**，照抄只会得到一个"开了没反应"的开关。
///
/// ## 9.1.88 上的等价物（这一份实现的）
///
/// 那一族换成了 `Share_SharingSDKSwift.*ShareHandler`（dump 3220/3226/3228：Instagram 的
/// Notes / Stories / 私信三个 handler），而开关变成了**构造
/// `Share_FoundationSwiftImpl.SPTShare_FoundationSwiftImplProperties` 时传进去的 6 个 BOOL**
/// （dump:6190 是这个类的重整名 `_TtC25Share_FoundationSwiftImpl38…`，dump:26180 是它的 init 选择器）：
///
///     initWithIsInstagramDirectMessageSharingEnabled:
///     isInstagramStoriesCanvasSharingEnabled:
///     isFacebookCanvasSharingEnabled:
///     isFacebookMessengerSharingEnabled:
///     isSnapchatCanvasSharingEnabled:
///     isUseractivitySharingEnabled:
///
/// ⇒ 这里 hook 那个 init，把**两个 Instagram 参数改写成 true**、其余原样传下去 ——
///   与上游"把那两个 getter 强写成 true"是同一件事，只是换成了这一版的形态。
///
/// ⚠️ 第二条路（更保守、不碰任何类）：`ExperimentFlagReplacements` 里强制那三条服务端 flag。
///    两条一起上，谁生效都算数；类名/方法名对不上时这里只打一行日志、**不装**（见下面）。
struct InstagramDestinationGroup: HookGroup { }

class SPTShareFoundationSwiftImplPropertiesHook: ClassHook<NSObject> {
    typealias Group = InstagramDestinationGroup

    /// ⚠️ 这里必须写 **Swift 重整名**：dump:6190 逐字就是它
    /// （`Share_FoundationSwiftImpl.SPTShare_FoundationSwiftImplProperties` 这种带点的写法
    /// 在 `NSClassFromString` 里查不到 —— 本仓库挂 `_TtC14Creator_ECMKit…` 那张卡时同一条教训）。
    static let targetName = "_TtC25Share_FoundationSwiftImpl38SPTShare_FoundationSwiftImplProperties"

    func initWithIsInstagramDirectMessageSharingEnabled(
        _ instagramDirectMessage: Bool,
        isInstagramStoriesCanvasSharingEnabled instagramStories: Bool,
        isFacebookCanvasSharingEnabled facebookCanvas: Bool,
        isFacebookMessengerSharingEnabled facebookMessenger: Bool,
        isSnapchatCanvasSharingEnabled snapchatCanvas: Bool,
        isUseractivitySharingEnabled useractivity: Bool
    ) -> Target {
        // 两个 Instagram 参数**只认 true**；另外四个（Facebook / Messenger / Snapchat /
        // UserActivity）保持服务端给的原值 —— 用户只要求放开 Instagram。
        return orig.initWithIsInstagramDirectMessageSharingEnabled(
            true,
            isInstagramStoriesCanvasSharingEnabled: true,
            isFacebookCanvasSharingEnabled: facebookCanvas,
            isFacebookMessengerSharingEnabled: facebookMessenger,
            isSnapchatCanvasSharingEnabled: snapchatCanvas,
            isUseractivitySharingEnabled: useractivity
        )
    }
}

/// 装之前先问一句"**这个类、这个方法在不在**"（与 `EeveeAdBlockerExtended` /
/// CarPlayCrashFix 同一个套路）：对不上就只打一行日志 —— 不让 Orion 去解析一个不存在的名字。
enum InstagramShareDestination {

    static let className = "_TtC25Share_FoundationSwiftImpl38SPTShare_FoundationSwiftImplProperties"

    /// dump:26180 的那条选择器（6 个 BOOL）。
    static let initSelector = NSSelectorFromString(
        "initWithIsInstagramDirectMessageSharingEnabled:"
            + "isInstagramStoriesCanvasSharingEnabled:"
            + "isFacebookCanvasSharingEnabled:"
            + "isFacebookMessengerSharingEnabled:"
            + "isSnapchatCanvasSharingEnabled:"
            + "isUseractivitySharingEnabled:"
    )

    static func activateIfNeeded() {
        guard UserDefaults.experimentsOptions.showInstagramDestination else { return }

        guard let cls = NSClassFromString(className),
              class_getInstanceMethod(cls, initSelector) != nil else {
            writeDebugLog(
                "[Instagram] share-destination properties class/method missing — nothing hooked"
                    + " (Spotify changed the sharing SDK again; the flag rewrite alone stays in effect)"
            )
            return
        }

        InstagramDestinationGroup().activate()
        writeDebugLog(
            "[Instagram] share-destination hook on — Instagram Stories / direct message forced on"
                + " at initWithIsInstagram… (dump:26180)"
        )
    }
}
