import Foundation
import Orion
import UIKit
import ObjectiveC.runtime

/// 关联对象的键。**必须放在文件作用域**：`&变量` 取到的地址要稳定且唯一，
/// 这是本仓库既有的写法（见 `DeclutterChrome.x.swift` 的 `declutterHiddenByUsKey`）。
var entityPageHeaderKey: UInt8 = 0

/// 页头替换：找到歌单页头、把 Spotify 那一列藏掉、把我们自己的（`EntityPageHeaderView`）摆上去。
///
/// ## 为什么挂 `HeaderContentLayout`
///
/// 它是那一块的**布局视图**（真机日志：`22.HeaderContentLayout@0,0,414,485`；符号表
/// `dump-9.1.88.txt:7799` 也在），**每一拍折叠/展开都会走它的 `layoutSubviews`** ——
/// 一个挂点就能覆盖"首次出现 / 滚动折叠 / 内容晚到"三种时机。
///
/// pw 还挂了一个 `SPTFreeTierPlaylistEncoreHeaderViewController`（它的 `viewDidLayoutSubviews`
/// 与 `update`）——**那个类在 9.1.88 上已经不存在**（歌单头改由 `ListUXPlatform_FreeTierPlaylistImpl`
/// 的 slot/element 类拼出来），所以这里不用它：主挂点已经够，计数器晚到那种情况由
/// "每一拍都重读一遍文本"覆盖。
///
/// ## 作用域（v1 故意收窄）
///
/// **只作用于歌单页**：`headerRoot` 必须是 `PL.Header`（那个 id 只在歌单页出现，
/// 真机日志 `15.UIView@…,id=PL.Header`）。专辑页用的是同一个 `HeaderContentLayout`，
/// 但它的头部结构、控件 id 与歌单不同 ⇒ **v1 一律不碰**（少一个变量，先让歌单页验完）。
///
/// ## 安全阀
///
/// 认不出标题就整块不动（`apply` 早退，一个视图都不藏）。所以任何一环失配 = "没生效"，
/// 而不是"歌单页坏了"。结果会在调试日志里留一行。
enum EntityPageHeaderManager {

    static var isEnabled: Bool { UserDefaults.entityPageAMHeader }

    private static var applying = false
    private static var logged = Set<String>()

    /// 每一拍的耗时（50 / 200 / 800 拍各报一次）。
    private static let meter = PerfMeter("EntityPageHeader")

    /// 页头每一拍要用的那几个视图**缓存下来**。
    ///
    /// ★ 2026-10-13（用户：「用较快的速度往下滑，会有渲染跟不上的问题」）：pw 的 `SGRFindByIdentifier`
    /// 带一个 `static char` key —— **命中一次之后每一拍只做一次"还在不在"的检查**，不再走子树。
    /// 我们原来是每拍 **5 次全树 BFS**（shuffle / play / save / download / 协作者）+ 3~4 次文本遍历，
    /// 而页头在快速滑动时**每一帧**都在折叠（`layoutSubviews` 每帧一次）⇒ 那些搜索全落在主线程上。
    private static var cachedShuffle: UIView?
    private static var cachedPlay: UIView?
    private static var cachedTrailing: UIView?
    private static var cachedCreatorLink: UIView?
    /// ★ 2026-10-13（性能）：封面元素与"那一块文字"也缓存 —— 这两次原来是**每帧**各一次整棵子树搜索
    /// （`eeveeFindView(layout, "Components.Header.UI.ArtworkImage")` / `blockIn(layout,…)`）。
    private static var cachedCover: UIView?
    private static var cachedBlock: UIView?
    /// ★ 2026-10-18：歌单页头里那个「在此页面上查找」搜索框（AM 页头接管后不该留着）。
    private static var cachedFindField: UIView?
    /// ★ 2026-10-13（性能）：上一拍认下的那四个标签（见 `TextViews`）。
    private static var cachedTextViews: TextViews?
    /// 专辑页那条路（见 `applyToAlbumPage`）：头容器、封面、三个文字容器，以及"kind·日期那行晚到"
    /// 的重试计数。**全部走缓存** —— 这一拍同样是每帧级的（pw 也是在 `layoutSubviews` 里每拍找，
    /// 靠它的 `SGRFindByIdentifier` 不再重搜）。
    private static var cachedAlbumHeader: UIView?
    private static var cachedAlbumCover: UIView?
    private static var cachedAlbumTitleRow: UIView?
    private static var cachedAlbumParentRow: UIView?
    private static var cachedAlbumMetadata: UIView?
    private static var albumRetryKey: UInt8 = 0
    /// 艺人页那条路（见 `applyToArtistPage`）：名字、月听众那行、照片、Follow —— 同样全走缓存。
    private static var cachedArtistName: UIView?
    private static var cachedArtistMeta: UIView?
    private static var cachedArtistCover: UIView?
    private static var cachedArtistFollow: UIView?
    /// 艺人页左边那颗 `i` 的转发目标：**艺人简介卡**（`CreatorBiographyCard`）。
    private static var cachedArtistBio: UIView?
    /// ★★ 2026-10-18：Follow 点击后的延迟复查要用这两样（见 `refreshArtistFollow`）。
    /// 都是**弱引用**：离开艺人页之后不该把整页留住。
    private static weak var lastArtistPage: UIView?
    private static weak var lastArtistHeaderView: EntityPageHeaderView?

    /// ★ 2026-10-18：艺人页标签栏的**原值**记录（关开关时逐个写回）。
    /// 视图一律弱引用 —— 离开艺人页之后不该把整页/滚动视图留住。
    private final class ArtistStripPageState {
        weak var scroll: UIScrollView?
        let enabled: Bool
        let transform: CGAffineTransform

        init(scroll: UIScrollView) {
            self.scroll = scroll
            enabled = scroll.isScrollEnabled
            transform = scroll.transform
        }
    }

    private final class ArtistStripState {
        weak var strip: UIView?
        let alpha: CGFloat
        let interactive: Bool
        let accessibilityHidden: Bool
        let pages: [ArtistStripPageState]

        init(strip: UIView, pages: [ArtistStripPageState]) {
            self.strip = strip
            alpha = strip.alpha
            interactive = strip.isUserInteractionEnabled
            accessibilityHidden = strip.accessibilityElementsHidden
            self.pages = pages
        }
    }

    private static var artistStripState: ArtistStripState?
    /// ★★ 2026-10-18 第二轮：从页面根出发那条兜底搜索**每页只试两拍**（见 `applyToArtistPage`）——
    /// 这两个数就是它的记账（换页清零；主力是 `ArtistBiographyViewHook`）。
    private static weak var artistBioSearchPage: UIView?
    private static var artistBioSearchPasses = 0
    /// ★★ 2026-10-18 第三轮（用户：「要不点击 i 之后不要 spotify 自己的了 … 我们自己搞」）：
    /// **读到过的艺人简介**按艺人名缓存（那一块是懒加载的，读一次就够；cell 一被回收文字就没了）。
    private static var bioTexts: [String: String] = [:]
    /// 这一页已经安排过"扫列表读简介"了（每页一次，延后 1.5s）。
    private static weak var bioSweepPage: UIView?
    private static var didReportBioSweep = false
    /// ★★ 2026-10-18 第四轮：那份"Spotify 原生数据线在哪"的诊断**只打一次**（见 `scheduleBioSweepIfNeeded`）。
    private static var didReportArtistAboutFetcher = false
    /// 现在这一页的艺人名（`applyToArtistPage` 每拍写）—— "我们自己的艺人介绍"拿它当标题。
    private static var artistNameStorage = ""

    static var currentArtistName: String { artistNameStorage }

    /// 读到的简介（没有就是 nil）。
    static func cachedBioText(for name: String) -> String? { bioTexts[name] }

    /// ★★ 2026-10-18：**Spotify 自己那条数据线**（`SPTArtistAboutDataLoader`）把
    /// `SPTArtistAbout` 交出来了 —— 这是"关于艺人"的**权威正文 + 真链接**。
    ///
    /// 与"从界面拼文字"的区别（用户：「解决方法总不能是正则式匹配字吧」）：
    ///   · **正文** = 模型的 `biographyText` 字段本身 ⇒ 艺人名 / "每月有 x 名听众"那两行
    ///     **根本不在里面**，不需要任何"猜哪一行不是正文"的判据；
    ///   · **完整**：界面 label 会被 `is_async_biography_truncation_enabled` 截断，这个字段不会；
    ///   · **链接** = `SPTArtistSocialLink` 上的 `wikipedia` / `twitter` / … 都是 `NSURL` ⇒
    ///     直接就是艺人真地址，不用点、不用转发、也不用拼搜索页。
    ///
    /// 线程：completion 可能在后台队列 ⇒ 只在这儿读模型（纯 ObjC 读，安全），
    /// 落库一律切主线程（`bioTexts` / `bioLinks` 的其它读点都在主线程）。
    static func artistAboutDidLoad(_ about: AnyObject?) {
        guard let about = about as? NSObject else { return }
        // completion 可能在后台队列 ⇒ 只在这儿读模型（纯 ObjC 读，安全），落库切主线程。
        if Thread.isMainThread {
            storeArtistAbout(about)
        } else {
            DispatchQueue.main.async { storeArtistAbout(about) }
        }
    }

    /// 把模型落库（`bioTexts` / `bioLinks` 的其它读点都在主线程 ⇒ 这里必须主线程调）。
    ///
    /// ⚠️ **落库的 key 必须与所有读点一致**：`cachedBioText` / `cachedBioLinks` /
    /// `hasCapturedBio` / `readBioWithoutScrolling` 用的都是**页面上的艺人名**
    /// （`artistNameStorage`）。模型的 `artistName` 多数时候与它逐字相同，但**不保证**
    /// （本地化 / 版本差异 / 空白与大小写）⇒ 只按模型名存就会出现
    /// "hook 装上了、日志也打了 `[ArtistBio] loader — …`、卡片里却什么都没有"。
    /// 所以：**页面名为主**；模型名不同就再当别名存一份（两个读法都能命中）。
    private static func storeArtistAbout(_ about: NSObject) {
        let biography = eeveeArtistAboutBiography(from: about)
        let links = eeveeArtistAboutLinks(from: about)
        guard biography != nil || !links.isEmpty else {
            writeDebugLog("[ArtistBio] loader — the model carried neither a biography nor a link")
            return
        }

        let pageName = artistNameStorage.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelName = eeveeArtistAboutName(from: about)
        let primary = pageName.isEmpty ? (modelName ?? "") : pageName
        guard !primary.isEmpty else { return }

        let previous = bioTexts[primary]?.count ?? 0
        applyArtistAbout(biography: biography, links: links, to: primary)
        if let modelName, modelName != primary {
            applyArtistAbout(biography: biography, links: links, to: modelName)
        }

        if let biography {
            writeDebugLog(
                "[ArtistBio] loader — \(primary), biography \(biography.count) char"
                    + " (was \(previous))"
            )
        } else {
            writeDebugLog("[ArtistBio] loader — \(primary), biographyText missing on the model")
        }
        if !links.isEmpty {
            writeDebugLog(
                "[ArtistBio] loader links — \(links.map(\.kind).joined(separator: ","))"
                    + " (from the model, real URLs)"
            )
        }
    }

    /// `storeArtistAbout` 的落库那一半 —— **同一份数据可以写两个 key**（见那里的 ⚠️）。
    private static func applyArtistAbout(
        biography: String?,
        links: [(kind: String, url: URL)],
        to name: String
    ) {
        guard !name.isEmpty else { return }

        if let biography {
            let previous = bioTexts[name]?.count ?? 0
            // 已经有一份更长的（比如上次那页读到的）就不覆盖；否则以数据线为准。
            if biography.count >= previous {
                bioTexts[name] = biography
            }
        }

        guard !links.isEmpty else { return }
        var refs = bioLinks[name] ?? []
        for link in links {
            // 同一个 kind 只留一条。原来的判据是"已有一条**带 URL** 的就跳过" —— 那样
            // 「页面扫描先存下一条读不到 URL 的 wikipedia → 模型这一轮再进一条带真地址的
            // wikipedia」会**变成两条**，卡片上就是两颗"维基百科"（而卡片只取前三颗，
            // 还会把别的链接顶掉）。现在：同 kind 已存在时**用模型这条覆盖**（真地址只有
            // 模型有），已有真地址的则严格不再加。
            if let index = refs.firstIndex(where: { $0.kind == link.kind }) {
                if refs[index].url == nil {
                    refs[index] = ArtistBioLinkRef(
                        kind: link.kind,
                        title: eeveeArtistBioLinkTitle(for: link.kind),
                        url: link.url,
                        control: refs[index].control
                    )
                }
                continue
            }
            refs.append(
                ArtistBioLinkRef(
                    kind: link.kind,
                    title: eeveeArtistBioLinkTitle(for: link.kind),
                    url: link.url,
                    control: nil
                )
            )
        }
        bioLinks[name] = refs
    }

    /// 「关于艺人」那块里找到的**社交链接**（维基 / 推特 / …）—— 按艺人名存。
    ///
    /// ★★ 2026-10-18（用户：「原本有的维基 / 推特链接之类的没显示」）：Spotify 自己那一块里
    /// 就有这些链接按钮（dump:21074-21079 的 `SPTArtistAbout:sArtist*ButtonTitle`），
    /// 我们把整块折掉之后它们一起消失。现在**露头那一刻就记下这些控件**（weak 引用），
    /// `ArtistBioSheet` 用它们画胶囊、点下去转发给控件本身（走 Spotify 自己的打开逻辑）。
    static func cachedBioLinks(for name: String) -> [ArtistBioLinkRef] { bioLinks[name] ?? [] }

    private static var bioLinks: [String: [ArtistBioLinkRef]] = [:]

    /// 在**一块子树**里把社交链接**认下来**（有界：默认 800 个节点、最多 6 条；空表不落库，
    /// 下一拍还能再试）。
    ///
    /// ★★ 2026-10-18（用户：「原本有的维基 / 推特链接之类的没显示」）：Spotify 自己那块里就有
    /// 这些链接按钮（二进制 @200596249 逐字：`SPTArtistExternalSocialLinkButton` /
    /// `…ButtonViewModel` / `SPTArtistSocialLink`；点它走委托 `externalSocialLinkTappedForType:`），
    /// 我们把整块折掉之后它们一起消失。现在**露头那一刻就记下这些控件**（weak 引用），
    /// `ArtistBioSheet` 用它们画胶囊、点下去优先用读到的真链接。
    ///
    /// ⚠️ 起点给**页面根**（`eeveeArtistBioSearchRoot`）而不是只给那张卡：艺人页的
    /// `CreatorBiographyCardLayout`（二进制 @182189882）里只有 bio / 头部 / 粉丝数 / "显示更多"，
    /// **没有**社交链接按钮 —— 只扫卡片会一条都收不到。
    private static func captureBioLinks(from root: UIView, name: String, limit: Int = 800) {
        var refs = bioLinks[name] ?? []
        guard refs.count < 6 else { return }

        var queue: [UIView] = [root]
        var visited = 0
        while !queue.isEmpty, visited < limit, refs.count < 6 {
            let view = queue.removeFirst()
            visited += 1
            if let hit = eeveeArtistBioLink(from: view),
               // 同一个 kind 只收一条：类名片段会同时命中那颗按钮与它的容器，
               // 不去重的话同一颗维基会画出两张胶囊。
               !refs.contains(where: { $0.control === view || (hit.kind != "link" && $0.kind == hit.kind) }) {
                refs.append(
                    ArtistBioLinkRef(kind: hit.kind, title: hit.title, url: hit.url, control: view)
                )
                writeDebugLog(
                    "[ArtistBio] link \(hit.kind) — url \(hit.url == nil ? "not readable" : "read")"
                        + ", title \(hit.title)"
                )
            }
            queue.append(contentsOf: view.subviews)
        }

        guard !refs.isEmpty else { return }
        bioLinks[name] = refs
        let kinds = refs.map(\.kind).joined(separator: ",")
        writeDebugLog("[ArtistBio] links found — \(kinds) (\(refs.count) control(s))")
    }

    /// 这一页的艺人简介**已经读到过**了吗 —— `EntityPageSectionDrop` 折叠「关于艺人」那一格之前要问它。
    ///
    /// ★★ 2026-10-11（日志 100）：折叠与读取原本是**两条独立的线** —— 折叠按 `CreatorBiography`
    /// 认（认得对）、读取按 `SPTArtistAboutBiographyView` 认（这一版页面上没有）⇒ 那一格被折成 0 高、
    /// 我们的卡片又读不到文字，用户**两边都看不到**。现在读不到就**不折**（宁可留着 Spotify 那段，
    /// 也不要都不显示）。
    static var hasCapturedBio: Bool {
        !artistNameStorage.isEmpty && bioTexts[artistNameStorage] != nil
    }

    /// **安排一次"扫列表读简介"**（每页一次，延后 1.5s）。
    ///
    /// 为什么不同步做：那一下会把列表里到"关于艺人"为止的 cell 全建出来，进页面那几帧本来就忙
    /// （页头在逐帧布局）。延后一拍半、而且 `eeveeMaterialiseBio` **一找到就停 + 回到原位**，代价小。
    /// 读到之后：① 存起来给 `i` 那张卡片用；② **读到之后**列表里那一段才会被折成 0 高
    /// （`EntityPageSectionDrop` 的闸门 = `hasCapturedBio`，所以这里还要主动作废一次布局）。
    private static func scheduleBioSweepIfNeeded(in page: UIView, name: String) {
        guard !name.isEmpty, bioTexts[name] == nil, bioTexts.count < 32 else { return }
        guard bioSweepPage !== page else { return }
        bioSweepPage = page
        // ★★ 2026-10-18 第四轮：顺手把"Spotify 原生那条数据线"的宿主类打进日志（一次性诊断，
        //    见 `ArtistBioSource.reportArtistAboutFetcher`）—— 下一份日志就能定下一轮怎么取**完整正文**。
        if !didReportArtistAboutFetcher {
            didReportArtistAboutFetcher = true
            ArtistBioSource.reportArtistAboutFetcher()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak page] in
            guard let page, page.window != nil else { return }
            // ★★ 2026-10-18：这一拍顺手也把**社交链接**扫一遍（见 `captureBioLinks`）——
            //    链接按钮与正文各出现各的，两边都从**页面根**起扫（有界 800 节点）。
            captureBioLinks(from: eeveeArtistBioSearchRoot(from: page), name: name)
            let text = readBioWithoutScrolling(in: page, name: name)
            guard !didReportBioSweep else { return }
            didReportBioSweep = true
            let count = text?.count ?? 0
            writeDebugLog(
                "[EntityPageHeader] about-artist read — \(name), biography "
                    + (text == nil ? "NOT READ" : "\(count) char")
                    // ★★ 2026-10-11：这句原来是"the section itself is folded to 0 height"（无条件断言）。
                    //    现在折叠有了闸门（读不到就**不折**），那句话不再恒真 ⇒ 照实写。
                    + (text == nil
                        ? "; nothing to fold this time (the section stays on the page)"
                        : "; the section gets folded now that we have the text")
            )
        }

        // ★★ 2026-10-16（**日志 103 的 AKIR 现场**）：上面那一次**不够**。
        //
        //    那一格是懒加载的，正文可能好几秒之后才到 —— AKIR 那次 1.5s 去读的时候，
        //    "关于"那一段还是 `Components.UI.RetrievalRowLoadingElementUI` 占位行
        //    （日志 103 的 cell dump 逐字：0-10 / 0-11 / 0-13 全是 h=92 的 Loading），
        //    于是 `biography NOT READ; nothing to fold this time` **一锤定音**：
        //    ⇒ ① 那一节**永远折不掉**（用户报的"关于艺人遮不住"）；
        //    ⇒ ② 点 `i` 也永远说"没有可读的介绍"。
        //
        //    现在**每 1.5s 补读一次、最多 10 次（≈15s）**，一读到就停。全程**零滚动**
        //    （滚动那一版会把列表滚一整趟再滚回来，用户看得见；见 `readBioWithoutScrolling`）。
        for attempt in 2...11 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 * Double(attempt)) { [weak page] in
                guard let page, page.window != nil else { return }
                // ★★ 2026-10-18：**正文与社交链接各走各的** —— 以前读到正文就不再进这一拍，
                //    而链接按钮常常比那张卡晚出现 ⇒ 一条都收不到。现在：
                //    · 每一拍都先扫一遍链接（有界；正文读到之后也继续扫）；
                //    · 正文只读到为止；两样都齐了 ⇒ 直接收工（不再白跑剩下的拍）。
                if bioTexts[name] != nil, !(bioLinks[name] ?? []).isEmpty { return }
                // ★★ 2026-10-18：**零风险的那条备用路** —— 数据线 hook 万一没装上/没响，
                //    就问一遍页面里有没有活着的 `SPTArtistAbout`（它的 `biographyText` 是权威正文、
                //    `socialLinks` 是真链接）。找不到就是找不到，不猜、不崩。
                if let model = eeveeArtistAboutModel(in: page) {
                    storeArtistAbout(model)
                }
                // 每一拍**先扫链接**（有界；收满 6 条就自己返回），再决定要不要读正文 ——
                // 两边都不重复扫。
                captureBioLinks(from: eeveeArtistBioSearchRoot(from: page), name: name)
                guard bioTexts[name] == nil else { return }
                guard let text = readBioWithoutScrolling(in: page, name: name) else { return }
                writeDebugLog(
                    "[EntityPageHeader] about-artist captured late — \(name), \(text.count) char"
                )
            }
        }
    }

    /// **零滚动**地读一次「关于艺人」的正文（读到就存起来 + 作废一次布局）。
    ///
    /// 为什么不用 `eeveeArtistBio`（→ `eeveeMaterialiseBio`）那一版：
    ///   · 它会**把列表一路滚到底再滚回来**（最多 12 步）—— 用户看得见（日志 100：连点四次 = 四次整页扫描）；
    ///   · 而且日志 102/103 里它**一次都没真的滚过**：那两页从页面根找不到 scroll view，
    ///     在 `guard let scroll …` 那句就静默 `return nil`（所以那两份日志里连
    ///     `about-artist sweep` 这一行都没有）⇒ 那条路已经是死的，留着只会让人以为正文是它读到的。
    ///
    /// 判据仍然只是"页面上**已经建出来**的那张卡"（`eeveeArtistBioCard`：零滚动 + 有界搜索）。
    @discardableResult
    private static func readBioWithoutScrolling(in page: UIView, name: String) -> String? {
        guard !name.isEmpty, page.window != nil else { return nil }
        if let cached = bioTexts[name] { return cached }
        guard let card = eeveeArtistBioCard(in: page) else { return nil }
        // 这个入口内部会把正文读走 → 存进 `bioTexts` → 作废一次布局（折叠闸门这才打得开）。
        artistBiographyAppeared(card)
        return bioTexts[name]
    }
    /// 读到简介之后**主动让列表重排一次** —— 折叠的闸门是"读到了吗"（`EntityPageSectionDrop`），
    /// 而"这一格多高"只在布局时被问，所以读到那一刻不作废布局的话，折叠要等用户滚一下才生效。
    ///
    /// 有界：从页面往下最多走 600 个节点、最多作废 **4** 个 `UICollectionView`，一律 `async`，
    /// 不会在布局回合里递归（与 `EntityPageRepaint.scheduleRelayout` 同一条纪律）。
    private static func relayoutAfterBioCapture(in page: UIView) {
        var queue: [UIView] = [page]
        var visited = 0
        var invalidated = 0
        while !queue.isEmpty, visited < 600, invalidated < 4 {
            let view = queue.removeFirst()
            visited += 1
            if let collection = view as? UICollectionView {
                invalidated += 1
                DispatchQueue.main.async { collection.collectionViewLayout.invalidateLayout() }
            }
            queue.append(contentsOf: view.subviews)
        }
        writeDebugLog(
            "[EntityPageHeader] about-artist captured — asked \(invalidated) collection view(s) to re-lay out"
        )
    }

    /// 「Follow 那颗的子树」只打一次（见 `probeFollowSubtree`）。
    private static var didProbeFollow = false
    /// ★★ 2026-10-06（照片 115-117：「**旁边还是随机播放**」）：简介卡是**懒加载**的（页面滚到
    /// "关于"那一段才建），所以某一拍找不到它**不能**就退回 shuffle —— 那样用户看到的就永远是
    /// shuffle。这里把**找到过的那颗控件**用 weak 记住（weak：上一页释放后自动失效，
    /// 下一页找到就替换），于是"只要见过一次 Info，之后每一拍都还是 Info"。
    private static weak var artistBioControl: UIView?
    /// ★ 2026-10-13（照 AM）：右上角那颗 `⋯` —— Spotify 的菜单按钮（`Components.UI.ContextMenuButton-<hash>`）
    /// 与**我们自己画的那一颗**（`EntityPageHeaderButton` 直接复用：它本来就是"玻璃圆 + 字形 + 转发"）。
    private static var cachedMore: UIView?
    private static var pinnedMore: EntityPageHeaderButton?
    /// ★ 2026-10-16：我们那颗 `⋯` 还在屏上、可 Spotify 的源已经没了 —— 只报一次（见 `pinMoreButton`）。
    private static var didReportPinnedMoreMissing = false
    /// ★ 2026-10-18：`⋯` 挂到 window 之后，只报一次几何/可交互性（用来判断"点不到"是位置还是层级）。
    private static var didReportPinnedMoreGeometry = false
    /// ★ 2026-10-18：歌单页「在此页面上查找」那一行的容器/滚动几何，只报一次（治"进入后还能往上划"）。
    private static var didReportPlaylistMetrics = false
    /// ★ 2026-10-18：艺人页 section / cell 的文字探针（找「最新发行 / 艺人之选」，不用转储视图树）。
    private static weak var artistProbePage: UIView?
    private static var artistProbeReports = 0
    private static var artistProbeLastPass: CFAbsoluteTime = 0
    private static var artistProbeSignature = ""

    /// 尾部按钮的兜底字形：**做成常量**（原来每一拍都 `UIImage(systemName:)` 造一张新的，
    /// 而这一拍在折叠的每一帧都会走到 —— 与"字形只取一次"同一条纪律）。
    private static let plusGlyph = UIImage(systemName: "plus")
    private static let downloadGlyph = UIImage(systemName: "arrow.down")

    /// 先看缓存（**还要在原来那棵树里、还在窗口上**），没有再搜。
    private static func find(_ identifier: String, in root: UIView, cache: inout UIView?) -> UIView? {
        if let cached = cache, cached.window != nil, cached.isDescendant(of: root) { return cached }
        let found = eeveeFindView(root, identifier: identifier)
        cache = found
        return found
    }

    /// 同 `find`，但**钻到真正能响应点击的那颗控件**上。
    ///
    /// ★★ 2026-10-17（用户真机第二轮：「艺人页 / 歌单页的**点击播放**按键没反应」「艺人页左边那颗
    /// 应该是 `i`…但现在是歌单的**随机播放**按钮，并且点击没反应」「已经关注了但没有绿色描边」）：
    ///
    /// 按 id 找到的往往是 `ElementView<URL, Any, Any>` 那层**包装** —— 转发打在包装上就是没反应，
    /// `isSelected` 也恒假（永远不变绿）。`firstControl` 的注释里逐字写着这件事，但当时**只有专辑页
    /// 那条路**（`findFloating`）真的钻了进去，歌单页与艺人页的 play / shuffle / follow 全直接
    /// 拿了包装层 ⇒ 用户看到的就是"日志说转发成功、界面一动不动"。
    ///
    /// 两条纪律：
    ///   · **钻不到就退回原来那个**（宁可保持原样，也不要因为钻而把东西丢掉）；
    ///   · 钻过一次**把钻到的那个写回缓存** —— 否则每拍都要在包装层里再走一趟子树。
    private static func findControl(_ identifier: String, in root: UIView, cache: inout UIView?) -> UIView? {
        let found = find(identifier, in: root, cache: &cache)
        guard let found, !(found is UIControl) else { return found }
        guard let control = firstControl(in: found) else { return found }
        cache = control
        return control
    }

    /// 只进日志：这颗控件**是什么类、是不是 `UIControl`** —— "有没有钻到真控件"就是这一行的答案。
    private static func describe(_ control: UIView?) -> String {
        guard let control else { return "missing" }
        let kind = NSStringFromClass(type(of: control))
        let tag = control is UIControl ? "UIControl" : "wrapper"
        return "\(kind)[\(tag)]"
    }

    // MARK: - 入口

    /// 从 `HeaderContentLayout` 的 `layoutSubviews` 调用 —— **快速滑动时每一帧一次**，
    /// 所以整段用 `PerfMeter` 记着：50 / 200 / 800 拍各报一次"一次多少毫秒"，
    /// 下一份日志就能直接回答"是不是我们拖慢的"，而不是靠猜。
    static func apply(in layout: UIView) {
        meter.measure { applyOnce(in: layout) }
    }

    private static func applyOnce(in layout: UIView) {
        guard isEnabled, !applying else { return }
        guard layout.bounds.width > 120, layout.bounds.height > 40 else { return }
        // 歌单页那条路（专辑页是**另一条路**：`applyToAlbumPage`，挂点也不同 —— 见它的说明）。
        guard let headerRoot = playlistHeaderRoot(of: layout) else { return }

        applying = true
        defer { applying = false }

        let fullbleedClass = NSClassFromString("_TtC28EncoreConsumerMobile_BaseKit26HeaderFullbleedCentralView")
        let fullbleed = layout.subviews.first { view in
            guard let fullbleedClass else { return false }
            return view.isKind(of: fullbleedClass)
        }

        // ★ 2026-10-13（性能）：这两个原来是每帧各一次整棵子树搜索，走缓存（同上面那五个挂点）。
        let cover = find("Components.Header.UI.ArtworkImage", in: layout, cache: &cachedCover) ?? fullbleed
        let block: UIView
        if let cached = cachedBlock, cached.window != nil, cached.isDescendant(of: layout) {
            block = cached
        } else {
            guard let found = blockIn(layout, cover: cover, fullbleed: fullbleed) else { return }
            cachedBlock = found
            block = found
        }
        guard block.bounds.height > 20 else { return }

        let texts = headerTexts(block: block, headerRoot: headerRoot)
        guard !texts.title.isEmpty else {
            logOnce("noTitle", "no title found — leaving Spotify's header alone")
            return
        }

        // 我们那一份：挂在 **headerRoot** 上（block 万一被换掉，同一份跟着搬过去，不会画两份）。
        let header: EntityPageHeaderView
        if let existing = objc_getAssociatedObject(headerRoot, &entityPageHeaderKey) as? EntityPageHeaderView {
            header = existing
        } else {
            header = EntityPageHeaderView()
            objc_setAssociatedObject(headerRoot, &entityPageHeaderKey, header, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }

        if header.superview !== block {
            block.addSubview(header)
        } else if block.subviews.last !== header {
            block.bringSubviewToFront(header)
        }

        // 位置：**页面宽度、居中** —— Spotify 的 block 比页面窄（真机 386 / 402）。
        let x = -block.convert(.zero, to: headerRoot).x
        let frame = CGRect(x: round(x), y: 0, width: headerRoot.bounds.width, height: block.bounds.height)
        if header.frame != frame { header.frame = frame }

        // Spotify 那一列整列藏掉（我们自己的那份除外）。幂等；Spotify 边加载边往里加东西，
        // 所以**每一拍都要重新走一遍**。
        for sub in block.subviews where sub !== header { eeveeConceal(sub) }

        // ★★ 2026-10-18（用户：「歌单页的那个**搜索歌单内歌曲框**还在」）：
        //    「在此页面上查找」那颗搜索框在 **PL.Header 里、不在 block 里**（上游
        //    `GlassPlaylist.x` 也是从 header 里找 `Components.Header.UI.Toolbar.SearchField`）
        //    ⇒ 上面那轮 `block.subviews` 永远命不中。AM 页头接管后它不该留在页头，
        //    这里单独藏一次（连它的圆底包装一起，走 `wrapperFor`）。
        if let findField = find(
            "Components.Header.UI.Toolbar.SearchField",
            in: headerRoot,
            cache: &cachedFindField
        ) {
            eeveeConceal(wrapperFor(findField, in: headerRoot))
            logOnce(
                "hidPlaylistFind",
                "playlist page: hid Spotify's find-in-playlist field (it lives in PL.Header, not in the header block)"
            )
            reportPlaylistMetrics(headerRoot: headerRoot, findField: findField)
        }

        header.update(title: texts.title, creator: texts.creator, length: texts.length, about: texts.about)

        // ★ 五个挂点全部走缓存（pw 的 `SGRFindByIdentifier` 同一条纪律）：命中过就不再搜树。
        // ★★ 2026-10-17：**这三颗都改成 `findControl`** —— 按 id 拿到的是包装层时，点了没反应
        //    （用户真机第二轮报的"歌单页点击播放没反应"）。
        let shuffle = findControl("Components.UI.ShuffleButton", in: block, cache: &cachedShuffle)
        let play = findControl("header-play-button", in: headerRoot, cache: &cachedPlay)
        let save = findControl("Components.UI.AddToButton", in: block, cache: &cachedTrailing)
        // ★★ 2026-10-16（用户：「喜欢的歌曲**播放键右边那颗向下箭头点了没反应**」）：
        //    ⚠️ 2026-10-17 把 shuffle / play / save 三颗都改成了 `findControl`（按 id 拿到的常常是
        //    `ElementView<…>` 包装层，转发打在包装上 = 没反应，见本文件 :984 那段说明），
        //    **唯独漏了 download 这一颗** —— 而"已点赞的歌曲"那一页**走的正是它**
        //    （日志 85 逐字：`trailing download`）。补齐：同样先钻到真正的 `UIControl`。
        let download = save == nil
            ? eeveeFindView(block, identifier: "DownloadButton.Granular*").map { firstControl(in: $0) ?? $0 }
            : nil
        header.updateRow(
            shuffle: shuffle,
            play: play,
            trailing: save ?? download,
            trailingFallback: save != nil ? plusGlyph : downloadGlyph
        )
        // ★ 2026-10-17：长按播放键 = 随机播放（见 `EntityPageHeaderPlay.feedLongPress`）。
        header.updatePlayLongPress(shuffle)
        header.updateCreatorLink(
            find("Components.PlaylistHeader.collaboratorsButton", in: block, cache: &cachedCreatorLink)
        )

        // Play 在页头的**前景区**，不在 block 里 ⇒ 单独藏一次（它自己那一拍也会再补，见下面的 hook）。
        eeveeConceal(play)

        // ★ 2026-10-13（照 AM）：把 `⋯` 钉到右上角去。
        pinMoreButton(in: headerRoot)

        logOnce(
            "applied",
            "applied — title \"\(texts.title)\", creator \"\(texts.creator.isEmpty ? "-" : texts.creator)\""
                + ", length \"\(texts.length.isEmpty ? "-" : texts.length)\""
                + ", shuffle \(describe(shuffle))"
                + ", play \(describe(play))"
                + ", trailing \(save != nil ? "save" : (download != nil ? "download" : "none"))"
        )
    }

    /// `PlayButtonView` 自己的那一拍：页面刚打开时它会**晚一步**进前景区（pw 也遇到：角上先闪一下
    /// Spotify 自己的绿盘）。只有它确实在歌单页头里才藏 —— 专辑页那种浮动 Play 不碰。
    static func concealPlayButtonIfNeeded(_ view: UIView) {
        guard isEnabled else { return }
        guard view.accessibilityIdentifier == "header-play-button" else { return }
        // ★ 2026-10-13：**两个页面都藏**（歌单页的头 `PL.Header` / 专辑页的 `CreativeWorkTemplateView`）
        //   —— 两个页面我们都在行里镜像了这颗 Play。别的页面（艺人页那种浮动 Play）不碰。
        guard isEntityPage(of: view) else { return }
        eeveeConceal(view)
    }

    // MARK: - 找页面 / 找那一块

    /// 往上找 `PL.Header`（歌单页头那个容器）。找不到就返回 nil ——
    /// **专辑页与别的页面因此完全不受影响**。
    private static func playlistHeaderRoot(of view: UIView) -> UIView? {
        var node: UIView? = view
        while let current = node {
            if current.accessibilityIdentifier == "PL.Header" { return current }
            node = current.superview
        }
        return nil
    }

    /// 这是不是**我们接管的那两种页面**里的视图：歌单页判 `PL.Header`，专辑页判页面 root 的 id
    /// 或它的头容器 —— 三个都在祖先链上，走一次就够（pw 的 `SGRPlaylistHeaderOf` / `SGRAlbumPageOf`
    /// 也是各走一次祖先链）。
    private static func isEntityPage(of view: UIView) -> Bool {
        var node: UIView? = view
        var level = 0
        while let current = node, level < 24 {
            level += 1
            if let identifier = current.accessibilityIdentifier,
               identifier == "PL.Header"
                || identifier == "CreativeWorkPlatform.CreativeWorkTemplateView"
                || identifier == "CreativeWorkPlatform.Components.UI.CreativeWorkHeader" {
                return true
            }
            node = current.superview
        }
        return false
    }

    // MARK: - 专辑页（**另一条路**）

    /// 专辑页那一拍。**与歌单页不是同一条路** —— 两边的头结构不同，pw 也是分开的两份
    /// （`Album/AlbumHeader.x` 与 `Playlist/PlaylistHeader.x`）：
    ///
    /// ```
    /// 歌单页（PL.Header）            封面 + **一个** block：标题 / 描述 / 创建者 / 长度 / 操作行
    /// 专辑页（CreativeWorkHeader）   顶部 group（封面 + 标题 + 艺人）+ 底部 group（kind·日期 + 操作行）
    /// ```
    ///
    /// ⇒ 歌单页那个 `blockIn`（按宽度挑一块）在专辑页会挑到**底部 group**（那里没有标题），
    /// 所以这里**不挑块**：文字按**明确的 id** 读（`TitleRow` / `ParentRow` / `MetadataRow` ——
    /// pw 的 `AlbumHeader.x` 用的就是这三个），我们那一份铺在**整个头**上
    /// （pw 逐字：`setFrame(info, header.bounds)`）。
    ///
    /// 挂点是 `CreativeWorkTemplateView.layoutSubviews`（pw 的 `AlbumHeader.x` 也挂这里）。
    static func applyToAlbumPage(_ page: UIView) {
        guard isEnabled, !applying else { return }
        guard page.bounds.width > 120, page.bounds.height > 200 else { return }
        guard let header = find(
            "CreativeWorkPlatform.Components.UI.CreativeWorkHeader",
            in: page,
            cache: &cachedAlbumHeader
        ), header.bounds.height > 40 else { return }

        applying = true
        defer { applying = false }

        let texts = albumTexts(in: header)
        guard !texts.title.isEmpty else {
            logOnce("noTitleAlbum", "album page: no title found — leaving Spotify's header alone")
            return
        }

        let cover = find(
            "CreativeWorkPlatform.Components.UI.ArtWorkElement.WithCoverArt",
            in: header,
            cache: &cachedAlbumCover
        )

        let headerView: EntityPageHeaderView
        if let existing = objc_getAssociatedObject(header, &entityPageHeaderKey) as? EntityPageHeaderView {
            headerView = existing
        } else {
            headerView = EntityPageHeaderView()
            objc_setAssociatedObject(header, &entityPageHeaderKey, headerView, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        if headerView.superview !== header {
            header.addSubview(headerView)
        } else if header.subviews.last !== headerView {
            header.bringSubviewToFront(headerView)
        }
        if headerView.frame != header.bounds { headerView.frame = header.bounds }

        concealAlbumChrome(in: header, avoiding: cover, skipping: headerView)

        headerView.update(title: texts.title, creator: texts.creator, length: texts.length, about: "")

        // Play 与 Shuffle 在**页面上**（浮在右上角，不在头里）—— pw 的 `floatingIn` 逐字：
        // 只搜页面的直接子视图、且宽度 ≤120 的那些（头 / wash / 列表都是整页宽，走进去等于每拍走整棵树）。
        let play = findFloating("header-play-button", in: page, cache: &cachedPlay)
        let shuffle = findFloating("Components.UI.ShuffleButton", in: page, cache: &cachedShuffle)
        let add = findControl("Components.UI.AddToButton", in: header, cache: &cachedTrailing)
        // ★★ 2026-10-16：与歌单页那条同一个漏点 —— download 也要先钻到真正的 `UIControl`
        //    （见上面 `applyToPlaylistPage` 里那段说明）。
        let download = add == nil
            ? eeveeFindView(header, identifier: "DownloadButton.Granular*").map { firstControl(in: $0) ?? $0 }
            : nil
        headerView.updateRow(
            shuffle: shuffle,
            play: play,
            trailing: add ?? download,
            trailingFallback: add != nil ? plusGlyph : downloadGlyph
        )
        // ★ 2026-10-17：长按播放键 = 随机播放（见 `EntityPageHeaderPlay.feedLongPress`）。
        headerView.updatePlayLongPress(shuffle)
        // 专辑页的"创建者"就是艺人，点它开艺人页 —— pw 逐字：`[info showCreatorLink:parent]`。
        headerView.updateCreatorLink(
            find("CreativeWorkPlatform.Components.UI.ParentRow", in: header, cache: &cachedAlbumParentRow)
        )

        // ★ 2026-10-13（用户：「这播放旁边的图标是重合的还没修吗」）：三颗**都藏"包着它的最外层等尺寸
        //   视图"**（pw 的 `wrapperFor`）—— 见那个函数的说明。另外把 shuffle 也一起藏：我们那一行里
        //   本来就有它（左边那颗），Spotify 原生那颗**一直没被藏过**，与我们的叠在同一格。
        //   顺便把 trailing 的源与字形打进日志：用户说右边那颗"看起来像随机播放的图标"，
        //   这一行能直接分辨是"取错了源"还是"取错了字形"。
        eeveeConceal(wrapperFor(play, in: page))
        eeveeConceal(wrapperFor(shuffle, in: page))
        eeveeConceal(wrapperFor(add, in: header))
        eeveeConceal(wrapperFor(download, in: header))

        // ★ 2026-10-13（照 AM）：把 `⋯` 钉到右上角去。
        pinMoreButton(in: header)
        logOnce(
            "trailingSource",
            "trailing ← \(add != nil ? "AddToButton" : (download != nil ? "DownloadButton" : "nothing"))"
                + " (id \(add?.accessibilityIdentifier ?? download?.accessibilityIdentifier ?? "-"))"
                + ", glyph \(eeveeGlyph(of: add ?? download) == nil ? "none" : "taken"),"
                + " shuffle \(shuffle == nil ? "missing" : "found")"
        )

        // 那行 kind·日期是 collection view 的 **cell**，晚一拍才建出来（pw 也等：最多 6 次、每次 0.25s）。
        if texts.length.isEmpty {
            let tries = (objc_getAssociatedObject(header, &albumRetryKey) as? NSNumber)?.intValue ?? 0
            if tries < 6 {
                objc_setAssociatedObject(
                    header,
                    &albumRetryKey,
                    NSNumber(value: tries + 1),
                    .OBJC_ASSOCIATION_RETAIN_NONATOMIC
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak page] in
                    guard let page else { return }
                    applyToAlbumPage(page)
                }
            }
        }

        logOnce(
            "appliedAlbum",
            "album page — title \"\(texts.title)\", artist \"\(texts.creator.isEmpty ? "-" : texts.creator)\""
                + ", kind \"\(texts.length.isEmpty ? "-" : texts.length)\""
                + ", shuffle \(shuffle == nil ? "missing" : "ok")"
                + ", play \(play == nil ? "missing" : "ok")"
                + ", trailing \(add != nil ? "add" : (download != nil ? "download" : "none"))"
        )
    }

    // MARK: - 艺人页（**第三条路**）

    /// ★ 2026-10-13（用户：「做艺人页，看起来像 Apple Music，或者完全一样，要求优雅」）。
    /// 照 pw 的 `Artist/ArtistHeader.x`，它开头逐字写着要的东西：
    ///
    /// > The photo runs full bleed across the top of the page and dissolves into the page's colour;
    /// > the name and the monthly listeners are centred on the bottom of that dissolve; and under them
    /// > one row -- shuffle, a white Play capsule, and Follow.
    ///
    /// 页面判据是 **`creator-page`**（pw 的 `ArtistField.x` 里 `kPageIdentifier` 就是这个字符串），
    /// 页头容器是 `TemplateKit` 的 **`HeaderContainer`** —— 那个容器**身上没有 accessibility id**，
    /// 只能按类名认（pw 的 `containerOf` 也是这么找的）。
    ///
    /// ⚠️ 两个**绝不能动**的地方，都是 pw 用真机崩溃换来的：
    ///   · 这里**只用空 mask 藏东西、绝不设 hidden** —— 页头在 `OverflowStackView` 里，
    ///     一行里最"高"的视图被 hidden 时它会 force-unwrap nil 并 trap（见 `eeveeBlank`）；
    ///   · **不要强制** `…context_menu_in_navigation_bar_enabled_artist` 那个 flag（同一个 trap）。
    /// ## 真机树（**我们自己打的**，2026-09-30，`readlog` 里那份 `creator-page` dump）
    ///
    /// 这条路**不是照 pw 的注释猜的**：下面每一行都来自我们自己日志里的实测（`[Tree] #12` 那一份），
    /// pw 的 `ArtistHeader.x` 只在少数地方与它不同，**以我们这份为准**：
    ///
    /// ```
    /// 14.TemplateView@0,0,414,896,id=creator-page
    /// 15.UIView@0,0,414,896,id=CreativeWorkPlatform.Tab      ← 和专辑页同一个容器（要清底）
    /// 16.UIScrollView…id=PCFFTabLayoutViewController.containerScrollView
    /// 17.UIStackView@0,0,414,1416
    /// 18.HeaderContainer@0,0,414,520                        ← hero 宿主（420 与 584 两档都出现过）
    /// 19.ElementView<URL,Any,Any>@0,420,414,100
    /// 20.ImageHeaderView@0,0,414,100
    /// 22.ShadowContainer@0,0,414,414,alpha=-0.15,id=Components.Header.UI.ArtworkImage  ← 照片，全宽 414
    /// 22.GradientView@0,-100,414,200                        ← 照片上那层渐变（同样要藏）
    /// 22.AdaptiveTitle@0,-154,382,212,id=Encore.AdaptiveTitle   ← 名字
    /// 21.UIStackView@16,-16,107,24,id=ImageHeaderView.VerifiedBadge
    /// 23.OBJC_ONLY_Label@0,0,326,18,id=Components.Header.UI.Metadata  ← "xx 月听众"
    /// 22.OverflowStackView@0,0,290,48                       ← ⚠️ 就是它（在里面 hidden 会 trap）
    /// 23.ElementView<URL,Any,Any>@0,4,58,40                 ← Follow（`Encore.Button.Secondary`，"关注"）
    /// 24.EncoreButton@0,0,48,48,id=Components.UI.ContextMenuButton-…
    /// 22.ElementView<URL,Any,Any>@338,0,68,48               ← play（`header-play-button`）
    /// 22.HeaderNavigationBar@0,0,414,100 > 23.GradientView@0,0,414,100
    /// 18.UIView@0,520,414,896,id=PCFFTabLayoutViewController.tabsViewAccessibilityID
    /// 19.UIView@0,0,414,44,id=Components.UI.TabsSectionHeading  ← Music / Video / Merch
    /// ```
    ///
    /// 与 pw 注释**不同**、以我们实测为准的三处：`HeaderContainer` 是 **520 / 584pt**（pw 写 568）；
    /// 照片是 **414×414 全宽**（pw 的树里 402 宽）；顺序上 Follow 那一行在 `OverflowStackView` 里 ——
    /// 也就是"藏 header 里的东西不能碰 hidden"这条**在我们机器上同样成立**，不是 pw 的机器特异。
    static func applyToArtistPage(_ page: UIView) {
        guard isEnabled, !applying else { return }
        guard page.accessibilityIdentifier == "creator-page" else {
            // ★ 2026-10-18（图片 142：进页面后仍是原生左对齐页头 + 黑底）：先分清"这一页
            //    不是艺人页"与"它是艺人页、但根 id 不叫 creator-page"。后者是我们漏接管，
            //    下一份日志里这一行会直接给出真实 id。
            if eeveeFindView(
                page,
                identifier: "Curation.FollowButtonElementKit.FollowButton",
                maxNodes: 800
            ) != nil {
                let rootID = page.accessibilityIdentifier ?? "nil"
                logOnce(
                    "artistRootMismatch",
                    "artist-like page ignored — root id is \(rootID), not creator-page"
                )
            }
            return
        }
        guard page.bounds.width > 120, page.bounds.height > 200 else { return }
        guard let header = artistHeaderContainer(in: page), header.bounds.height > 80 else { return }

        applying = true
        defer { applying = false }

        // ★ 2026-10-18：标签栏从"无条件藏"变成一颗开关（默认仍是藏，见 `UserDefaults.artistHideTabs`）。
        if UserDefaults.artistHideTabs {
            hideArtistTabStrip(in: page)
        } else {
            restoreArtistStrip()
        }

        // 名字：pw 的树里那是 `UIView {16, 334}` 里的 `Encore.AdaptiveTitle`（45pt）；
        // 拿不到就退回"字号最大的那个标签"（与歌单页同一条兜底）。
        var name = ""
        if let title = find("Encore.AdaptiveTitle", in: header, cache: &cachedArtistName),
           let label = firstLabel(in: title, skipping: nil) {
            name = label.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        if name.isEmpty, let label = biggestLabel(in: header, skipping: []) {
            name = label.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        guard !name.isEmpty else {
            logOnce("noNameArtist", "artist page: no name found — leaving Spotify's header alone")
            return
        }

        // ★★ 2026-10-18 第三轮：① 记下艺人名（`i` 那张"我们自己的艺人介绍"拿它当标题）；
        //    ② 安排一次"扫列表读简介"（见 `scheduleBioSweepIfNeeded`）。
        artistNameStorage = name
        scheduleBioSweepIfNeeded(in: page, name: name)

        // 副标题：`Components.Header.UI.Metadata` —— 树里是 "58,4M monthly listeners"。
        var meta = ""
        if let metadata = find("Components.Header.UI.Metadata*", in: header, cache: &cachedArtistMeta) {
            meta = metadataLine(metadata)
        }

        // 我们那一份：铺在**整个页头容器**上（pw：`setFrame(info, header.bounds)`，内容贴底）。
        let headerView: EntityPageHeaderView
        if let existing = objc_getAssociatedObject(header, &entityPageHeaderKey) as? EntityPageHeaderView {
            headerView = existing
        } else {
            headerView = EntityPageHeaderView()
            objc_setAssociatedObject(header, &entityPageHeaderKey, headerView, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        if headerView.superview !== header {
            header.addSubview(headerView)
        } else if header.subviews.last !== headerView {
            header.bringSubviewToFront(headerView)
        }
        if headerView.frame != header.bounds { headerView.frame = header.bounds }
        // ★★ 2026-10-18：Follow 状态复查要能找回"这一页 / 这个页头"（见 `refreshArtistFollow`）。
        if lastArtistPage !== page { tapMaterialisedPages.removeAll() }
        lastArtistPage = page
        lastArtistHeaderView = headerView
        if headerView.onTrailingTapped == nil {
            headerView.onTrailingTapped = { EntityPageHeaderManager.refreshArtistFollow() }
        }
        // ★★ 2026-10-17：**只有这一页的页头会缩**（520 → 100pt 的导航栏）⇒ 也只有这一页要那条
        //    "装不下就渐隐让位"。歌单/专辑页的页头是定高的，给它打开只会把整块内容弄没（照片 124）。
        headerView.fadesWhenTight = true
        // ★★ 2026-10-18 第三轮（用户：「**spotify 的按键又靠上**」）：**贴底 0**（不是默认的 14）
        //    ⇒ 姓名与那三颗整体下移 14pt，与 AM 的照片 118 对齐（见 `contentBottom` 那段）。
        if headerView.contentBottom != 0 { headerView.contentBottom = 0 }

        // ★★ 2026-10-17（用户：图片 136 那张「最新发布」小卡片）：取这一位艺人的最新发布。
        //
        //    优先级（用户原话：「优先展示**艺人之选**，没有艺人之选再展示最新发布」）：
        //      · 艺人之选是 **Spotify 自己的**板块，只能从页面里读（`captureArtistPick`，见下方说明）；
        //      · 读不到（多半是没滚到 / 这位艺人没有那一块）⇒ 退回 `ArtistLatestReleaseSource`
        //        （iTunes 目录；实测与图片 136 逐字一致，且**不需要令牌**）。
        scheduleLatestRelease(for: headerView, name: name)
        // 「艺人之选」优先：它就在同一页上（懒加载板块），滚到那一块时读一次就换掉卡片内容。
        captureArtistPick(in: page)
        // ★★ 2026-10-17（用户：图片 145「这里会默认不展开『显示更多』…… 不展开又很难看」）：
        //    进页后替用户点一次那颗展开按钮（原地铺开这一段 → 那条黑带与半截行都不再出现）。
        scheduleSectionExpansion(in: page)
        // 卡片要占 ~106pt ⇒ 页头容器得跟着长高（用户选 A：卡片画在我们自己的页头里）。
        makeRoomForReleaseCard(in: header)

        // Spotify 那一列：**空 mask 藏**（不碰 hidden —— 见函数头那段）。照片归 `EntityPageAppearance`。
        let cover = find("Components.Header.UI.ArtworkImage", in: header, cache: &cachedArtistCover)
        blankArtistChrome(in: header, avoiding: cover, skipping: headerView)

        // ★ 2026-10-18：月听众那行也做成开关（默认保留）。`meta` 仍算出来给日志用。
        headerView.update(
            title: name,
            creator: "",
            length: UserDefaults.artistHideListeners ? "" : meta,
            about: ""
        )

        // 三颗：shuffle / play / Follow。pw 从**页头**里找它们，但那一行会随 `ImageHeaderView`
        // 一起缩成 100pt 的导航栏，所以这里和专辑页一样：浮动控件按 `floatingIn` 从**页面**找，
        // Follow 是页头那一行里的文字按钮，按 pw 给的类名找。
        //
        // ★★ 2026-10-17（用户真机第二轮：「**点击播放**没反应」「左边应该是 `i` 但现在是**随机播放**
        //    按钮、点了也没反应」「已关注但没有绿描边」）：三颗**全部改成 `findControl`** —— 按 id
        //    拿到的都是 `ElementView<…>` 包装层，转发打在包装上 = 没反应，`isSelected` 也恒假。
        let play = findControl("header-play-button", in: page, cache: &cachedPlay)
        let shuffle = findControl("Components.UI.ShuffleButton", in: page, cache: &cachedShuffle)
        let follow = findControl(
            "Curation.FollowButtonElementKit.FollowButton",
            in: header,
            cache: &cachedArtistFollow
        ) ?? eeveeFindView(header, identifier: "FollowButton*").map { firstControl(in: $0) ?? $0 }
        // Follow 是**文字按钮**（"关注" / "已关注"），取不到字形 ⇒ 用一对 SF Symbol 兜底，
        // 而且按它的选中态换字形 —— 状态因此看得见（pw 那边直接读它的字，这里读者是图标）。
        //
        // ★★ 2026-10-06（用户：「播放页左边的按钮不应该是那个 `i` 吗，还没改？」）：照 AM 换成 Info。
        // ★★★ 2026-10-17（**日志 94 的 `leading none` + 老树是判决**）：之前找的
        //   `Components.UI.CreatorBiographyCard*` **是听歌页的"了解艺人"卡**（那一族树行的前缀全是
        //   `[NPVTree]`），**艺人页上根本没有它** ⇒ 永远退回 shuffle，用户看到的就是随机播放。
        //   艺人页真正的"关于艺人"是 **`SPTArtistAboutBiographyView`**：
        //
        //   ```
        //   [Tree] #9  14.TemplateView@0,0,414,896,id=creator-page     ← 艺人页根
        //   [Tree] #9  17.SPTArtistAboutBiographyView@16,82,382,1126   ← 「关于艺人」
        //   [Tree] #7  20.SPTArtistAboutBiographyView@16,82,382,70     ← 收起态
        //   ```
        //
        //   382 = 414−32（列表行的内缩），两种高度就是"收起 / 展开"。它**没有 accessibility id**，
        //   只能按**类名**认 ⇒ `eeveeFindView(_:classNameContains:)`。旧 id 那条留着当第二顺位
        //   （万一别的版本又用回那张卡）。
        // 缓存失效的三个条件都要看：**没找到过 / 已经不在窗口上 / 换了一页**。
        let bioStale = cachedArtistBio == nil
            || cachedArtistBio?.window == nil
            || !(cachedArtistBio?.isDescendant(of: page) ?? false)
        // ★★ 2026-10-18 第二轮（用户：「点击 i 按键不会跳转到艺人介绍」）：**这条 BFS 只在前两拍试**。
        //    真机日志 91 的树里 `SPTArtistAboutBiographyView` 落在**深度 20**，从页面根搜要走掉几千个节点；
        //    日志 97 逐字 `leading MISSING`（用户按了四次，我们只把页面往下滚，从来没拿到目标）。
        //    现在的主力是 `ArtistBiographyViewHook`（那个类出现即认下，事件驱动、零搜索），
        //    这里只剩"钩子还没触发时"的兜底。
        if artistBioSearchPage !== page {
            artistBioSearchPage = page
            artistBioSearchPasses = 0
        }
        if bioStale, artistBioSearchPasses < 2 {
            artistBioSearchPasses += 1
            // ★★ 2026-10-11（日志 100）：判据换成**真机证实过的那三个名字**（见 `eeveeArtistBioCard`）。
            //    原来第一判据是 `SPTArtistAboutBiographyView` —— 它在这一版艺人页上一次都没出现过，
            //    却排在前面 ⇒ 就算后面那条 id 前缀能命中，也永远轮不到。
            cachedArtistBio = eeveeArtistBioCard(in: page)
                ?? eeveeFindView(page, classNameContains: "SPTArtistAboutBiographyView")
        }
        if let info = cachedArtistBio, let control = firstControl(in: info) { artistBioControl = control }
        // ★★ 2026-10-06：**记住找到过的那颗**（见 `artistBioControl`）—— 那一块是懒加载的，
        //    某一拍没有它不代表该退回 shuffle。
        let leading = artistBioControl

        // ★★ 2026-10-17（用户：「如果艺人已经关注了，它应该是有**绿色描边**的，但现在没有」）：
        //    判据从"只看 `(follow as? UIControl)?.isSelected`"换成 `eeveeIsOn` —— 三条信号一起看
        //    （`isSelected` / 无障碍里的 `.selected` / 文字里的"已关注"），并且**四条都进日志**
        //    （`eeveeOnSignals`），下一份日志就能告诉我们哪一条真的会变。
        let followed = eeveeIsOn(follow)
        headerView.updateRow(
            shuffle: leading ?? shuffle,
            play: play,
            trailing: follow,
            // ★★ 2026-10-16（用户：「播放按键右边的**添加艺人**显示有问题。改成**中空的五角星**
            //    （和 AM 一样）……点击之后（即收藏艺人之后）变成现在的绿色勾」）：
            //    未关注 ⇒ `star`（SF Symbol 的 star 本来就是中空）+ **强制用兜底字形**
            //    （不采用 Spotify 那颗自己的"＋人"图）；已关注 ⇒ 保持原样：
            //    Spotify 自己的绿勾优先，取不到才用 `checkmark` 兜底。
            trailingFallback: UIImage(systemName: followed ? "checkmark" : "star"),
            trailingPrefersFallback: !followed
        )
        // ★★ 2026-10-17：**左边那颗永远是 `i`**（用户点名要的），不再因为"那一块还没建出来"退回
        //    shuffle 的样子；**动作**落在"关于艺人"上（`setLeadingTarget`），目标没建出来时点它
        //    只会把页面往下滚一屏去把它滚出来，**绝不退回去做随机播放**。
        //    随机播放改挂**长按播放键**（见 `updatePlayLongPress`）。
        // ★★ 2026-10-18 第二轮：**转发目标换成"关于艺人"那一块本身**（`cachedArtistBio`，不是它里面
        //    第一颗 `UIControl`）—— 用户自己点那一块能跳转，说明处理它的那一层在**祖先链**上；
        //    配合 `eeveeFireWide`（再往上 6 层 + cell 的选中回调）才有机会走通。
        headerView.setLeadingTarget(cachedArtistBio, glyph: UIImage(systemName: "info.circle"))
        headerView.updatePlayLongPress(shuffle)
        headerView.updateCreatorLink(nil)

        // ★ 2026-10-17（日志 94：`followSignals` 四条**全是空的**）：把 Follow 那颗的子树打一次，
        //   看"已关注"到底画在哪个类上、状态挂在哪个属性上。只打一次。
        probeFollowSubtree(follow)

        eeveeBlank(play)
        eeveeBlank(shuffle)
        eeveeBlank(follow)
        eeveeBlank(leading)

        // ★ 2026-10-13（照 AM）：把 `⋯` 钉到右上角去。
        pinMoreButton(in: header)

        // ★★ 2026-10-17：日志要说清三件事 ——
        //   · **左边那颗到底是谁**（简介卡 / 找不到简介卡退回的 shuffle / 压根没有）；
        //   · 三颗各自**钻到了什么类**（`[UIControl]` = 真控件、`[wrapper]` = 还是包装层）；
        //   · follow 的四条状态信号（哪一条真的会随"已关注"变，下一份日志就看出来了）。
        let leadingKind = leading == nil
            ? "MISSING (button still shows i; tapping scrolls the page to build it)"
            : (leading === shuffle ? "shuffle-fallback" : "about(SPTArtistAboutBiographyView)")
        let followNote = follow == nil ? "missing" : (followed ? "following" : "follow")
        logOnce(
            "appliedArtist",
            "artist page — name \"\(name)\", meta \"\(meta.isEmpty ? "-" : meta)\""
                + ", leading \(leadingKind)"
                + ", play \(describe(play))"
                + ", shuffle \(describe(shuffle))"
                + ", follow \(followNote) \(describe(follow))"
                + ", followSignals \(eeveeOnSignals(follow))"
        )

        // ★ 2026-10-18：找「最新发行 / 艺人之选」用（用户不想开转储视图树）。
        probeArtistPageSections(in: page)
    }

    /// ★ 2026-10-18（用户：「播放按键和热门歌曲中间塞个方框……最新发布歌曲 / 艺人之选」）：
    /// 把艺人页里**每个 CollectionViewCell 的 y / 第一个文字 / ids** 按位置打出来，
    /// 每页最多 10 次、0.8s 节流、内容没变不重复。用户滚到「最新发行」那一段时，
    /// 日志里就会出现那一格的真名与文字 —— 下一轮按它做方框，不用开转储视图树。
    private static func probeArtistPageSections(in page: UIView) {
        if artistProbePage !== page {
            artistProbePage = page
            artistProbeReports = 0
            artistProbeLastPass = 0
            artistProbeSignature = ""
        }
        guard artistProbeReports < 10 else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - artistProbeLastPass >= 0.8 else { return }
        artistProbeLastPass = now

        var cells: [(y: CGFloat, text: String, ids: String)] = []
        var queue: [UIView] = [page]
        var visited = 0
        while !queue.isEmpty, visited < 2000 {
            let view = queue.removeFirst()
            visited += 1
            if NSStringFromClass(type(of: view)).contains("CollectionViewCell") {
                var ids: [String] = []
                var idQueue: [UIView] = [view]
                var idVisited = 0
                while !idQueue.isEmpty, idVisited < 40 {
                    let child = idQueue.removeFirst()
                    idVisited += 1
                    if let id = child.accessibilityIdentifier, !id.isEmpty { ids.append(id) }
                    idQueue.append(contentsOf: child.subviews)
                }
                let text = eeveeControlText(of: view).prefix(40)
                let frame = view.convert(view.bounds, to: page)
                cells.append((
                    y: frame.minY,
                    text: String(text),
                    ids: ids.prefix(6).joined(separator: ",")
                ))

                // ★ 2026-10-18：cell 里那些**可能**是"最新发行 / 艺人之选"的类（Release / Carousel /
                //    SectionHeading / Pick / Card）也单独列出来 —— 它们的 id 可能为空，
                //    但类名 + 文字足够下一轮定位。每格最多 8 条。
                var interesting: [String] = []
                var innerQueue: [UIView] = [view]
                var innerVisited = 0
                while !innerQueue.isEmpty, innerVisited < 120, interesting.count < 8 {
                    let inner = innerQueue.removeFirst()
                    innerVisited += 1
                    let cls = NSStringFromClass(type(of: inner))
                    let hit = ["Release", "Carousel", "SectionHeading", "Pick", "Card"]
                        .contains { cls.localizedCaseInsensitiveContains($0) }
                    if hit {
                        let innerText = eeveeControlText(of: inner).prefix(30)
                        interesting.append("\(cls) [\(innerText)]")
                    }
                    innerQueue.append(contentsOf: inner.subviews)
                }
                if !interesting.isEmpty {
                    writeDebugLog(
                        "[ArtistPageProbe] matches y=\(Int(frame.minY)) — \(interesting.joined(separator: " | "))"
                    )
                }
            }
            queue.append(contentsOf: view.subviews)
        }

        cells.sort { $0.y < $1.y }
        let shown = Array(cells.prefix(14))
        let signature = shown
            .map { "\(Int($0.y))|\($0.text)|\($0.ids)" }
            .joined(separator: "||")
        guard !signature.isEmpty, signature != artistProbeSignature else { return }
        artistProbeSignature = signature
        artistProbeReports += 1

        for cell in shown {
            writeDebugLog(
                "[ArtistPageProbe] cell y=\(Int(cell.y)) ids=[\(cell.ids)] text=\(cell.text)"
            )
        }
    }

    /// ★★ 2026-10-18（用户：「点击收藏之后，按钮不会变绿，删除艺人之后，才会变绿」）：
    /// **点击之后重新读一次 Follow 的状态**。
    ///
    /// 为什么不能只靠 `applyToArtistPage` 的下一拍：`tapped()` 里那次 `refreshTint()` 发生在
    /// **转发之前**，读到的是点击前的旧状态；而 Spotify 更新关注状态**不保证**会让页头再布局一次
    /// （用户看到的正是"点关注不变绿、再点取消反而变绿"——迟了一整次点击）。
    ///
    /// 由 `EntityPageHeaderButton.afterFire` 在点击后 0.2 / 0.7 / 1.6 / 3.0 / 5.0s 各叫一次：
    /// 重新认一次控件（Spotify 可能整颗换掉）、读状态、换 `star` / `checkmark` 与绿色描边。
    static func refreshArtistFollow() {
        guard isEnabled else { return }
        guard let page = lastArtistPage, page.window != nil,
              let headerView = lastArtistHeaderView, headerView.window != nil else { return }

        // ⚠️ **每次都重新认**（清掉缓存再搜）：Spotify 换关注状态时可能整颗 Follow 重建，
        //    旧实例还挂在树上（只是被我们 blank 了）⇒ 只信缓存会一直读到"关注/已关注"的旧值。
        //    一次点击最多搜 4 次，页头已建好；这比"状态永远差一拍"便宜得多。
        cachedArtistFollow = nil
        var follow: UIView?
        if let header = artistHeaderContainer(in: page) {
            follow = findControl(
                "Curation.FollowButtonElementKit.FollowButton",
                in: header,
                cache: &cachedArtistFollow
            ) ?? eeveeFindView(header, identifier: "FollowButton*").map { firstControl(in: $0) ?? $0 }
        }
        guard let follow else {
            logOnce("followRefreshMissing", "follow state after tap — the Follow control is not in the tree")
            return
        }

        cachedArtistFollow = follow
        let followed = eeveeIsOn(follow)
        headerView.updateFollow(
            followed: followed,
            glyph: UIImage(systemName: followed ? "checkmark" : "star"),
            source: follow
        )
        logOnce(
            "followRefresh-\(followed)",
            "follow state after tap — followed=\(followed); \(eeveeOnSignals(follow))"
        )
    }

    /// ★ 2026-10-18（用户：「还是只能往下划到原本的艺人模块再划回去，点击 i 才有用」）：
    /// **一次点击最多扫一趟列表**。`eeveeMaterialiseBio` 会把列表逐屏翻一遍再回到原位，
    /// 每点一次都扫一遍会很卡；按页面记，第一次点击才允许扫。
    private static var tapMaterialisedPages = Set<ObjectIdentifier>()

    static func beginTapMaterialise(for page: UIView?) -> Bool {
        guard let page else { return false }
        return tapMaterialisedPages.insert(ObjectIdentifier(page)).inserted
    }

    /// ★★ 2026-10-17（用户：「艺人页还是**不手动往下滑过**，`i` 的就不会展示艺人简介」）：
    /// 点 `i` 时那一趟扫描**可能白跑** —— 卡片是懒加载的（不滚到它就不会被建出来），
    /// 而列表在刚进页面的一两秒里还在长（`contentSize` 边滚边变）⇒ 一次扫空就永远空着。
    ///
    /// 现在：扫空之后**再补扫两次**（0.6s / 1.6s）。每次只看两种情况 —— 已经拿到正文就停；
    /// 页面已经离开就停。`eeveeMaterialiseBio` 自己会回到原位，所以补扫不会把页面留在下面。
    static func retryMaterialiseBio(from view: UIView, remaining: Int = 2) {
        guard remaining > 0 else { return }
        let name = currentArtistName
        let delay: TimeInterval = remaining == 2 ? 0.6 : 1.6

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak view] in
            guard let view, view.window != nil else { return }
            if !name.isEmpty, cachedBioText(for: name) != nil { return }

            if let card = eeveeMaterialiseBio(from: view) {
                artistBiographyAppeared(card)
                writeDebugLog(
                    "[EntityPageHeader] about-artist retry found the card (\(remaining) retry/retries left)"
                )
                return
            }

            writeDebugLog(
                "[EntityPageHeader] about-artist retry still empty (\(remaining) retry/retries left)"
            )
            retryMaterialiseBio(from: view, remaining: remaining - 1)
        }
    }

    // MARK: - 「艺人之选」/「最新发布」卡片（艺人页三颗按钮下面那张）

    /// 「艺人之选」读到的样子（标题 + 副标题 + 封面）。
    private struct ArtistPick {
        let title: String
        let meta: String?
        let artwork: UIImage?
    }

    private static var artistPickCache: [String: ArtistPick] = [:]
    private static var didLogArtistPick = false
    /// 每一位艺人只发一次"最新发布"请求（数据源自己还有 TTL 缓存与在飞去重）。
    private static var releaseArtist: String?

    /// 用户 2026-10-17：**优先「艺人之选」，没有它再展示「最新发布」**。
    ///
    /// 艺人之选是 **Spotify 自己的**板块（日志 109：`[ArtistPageProbe] matches y=996 — … [艺人之选]`），
    /// 苹果目录里没有 ⇒ 只能从页面里读。它和其它懒加载板块一样：**没滚到就不存在**，所以这里每拍
    /// 做一次**有界**尝试（≤ 900 节点 / 深 12）：找到标题就取它**下面那一格**（同 section 的下一格，
    /// 或下一个 section 的第一格）的封面 + 最长的一段文字 + 次长的一段；找到才换，找不到就继续用
    /// 最新发布（**绝不拿猜出来的东西冒充**）。
    static func captureArtistPick(in page: UIView) {
        let name = currentArtistName
        guard !name.isEmpty else { return }
        if artistPickCache[name] != nil {
            if !didLogArtistPick, let pick = artistPickCache[name] {
                didLogArtistPick = true
                writeDebugLog("[Release] artist pick cached — \(pick.title)")
            }
            return
        }

        var queue: [(view: UIView, depth: Int)] = [(page, 0)]
        var visited = 0
        var heading: UILabel?
        while !queue.isEmpty, visited < 900, heading == nil {
            let (view, depth) = queue.removeFirst()
            visited += 1
            if let label = view as? UILabel,
               let text = label.text,
               isPickHeading(text) {
                heading = label
                break
            }
            guard depth < 12 else { continue }
            queue.append(contentsOf: view.subviews.map { ($0, depth + 1) })
        }
        guard let heading else { return }

        // ⚠️ `enclosingCell` 返回的是 `UIView?`（它同时认 table cell），而 `indexPath(for:)`
        //    只吃 `UICollectionViewCell` ⇒ **必须显式转一次**（2026-10-17 IPA build 报
        //    `cannot convert value of type 'UIView' to expected argument type 'UICollectionViewCell'`）。
        guard let ancestor = enclosingCell(of: heading),
              let cell = ancestor as? UICollectionViewCell,
              let collection = eeveeEnclosingCollectionView(of: cell),
              let indexPath = collection.indexPath(for: cell) else { return }

        var candidates: [IndexPath] = []
        if indexPath.item + 1 < collection.numberOfItems(inSection: indexPath.section) {
            candidates.append(IndexPath(item: indexPath.item + 1, section: indexPath.section))
        }
        if indexPath.section + 1 < collection.numberOfSections,
           collection.numberOfItems(inSection: indexPath.section + 1) > 0 {
            candidates.append(IndexPath(item: 0, section: indexPath.section + 1))
        }

        for candidate in candidates {
            guard let next = collection.cellForItem(at: candidate),
                  let pick = makePick(from: next) else { continue }
            artistPickCache[name] = pick
            writeDebugLog(
                "[Release] artist pick — \(pick.title)"
                    + " (from \(candidate.section),\(candidate.item))"
            )
            if let headerView = lastArtistHeaderView, currentArtistName == name {
                applyPick(pick, to: headerView)
            }
            return
        }
    }

    // MARK: - 「显示更多」：进页替用户展开一次

    private static var expandScheduledPages = Set<ObjectIdentifier>()

    /// 用户 2026-10-17（图片 145）：「这里会默认不展开『显示更多』这个东西，**但是不展开又很难看**」。
    ///
    /// 那一颗是 Spotify 的 `Components.UI.ListSectionFooter.Button`：它把"热门"那一段截在 6 行，
    /// 底部再盖一条往黑的渐变（`ScrollGradientOverlay`）让胶囊读得清 —— 用户看到的就是
    /// **半截的第 6 行 + 一条黑带**。他自己验证过（照片 121）：「把热门歌曲十首歌展开之后就好了」。
    ///
    /// ⇒ 进页 1 秒后（等 section 建出来）**替用户点一次**：原地铺开，不再有黑带与半截行。
    /// 每页只排一次；点到几颗、有没有点动都进日志。
    /// ★ 2026-10-17（第二版）：**只试一次太脆**。
    ///
    /// 进页的 1 秒里列表还在长（`contentSize` 每拍都在变）⇒ 那一拍"热门"这一段 footer 很可能
    /// **还没建出来**，于是只留一行 `no footer button`，用户照样看见「显示更多」。
    /// ⇒ 改成三轮（1.0 / 2.5 / 5.0s），点到就停；三轮都没有才认输，并把轮数写进日志
    ///   （下一份日志一眼能分出是"没找到"还是"点了没动"）。
    private static let expandAttemptDelays: [Double] = [1.0, 2.5, 5.0]

    private static func scheduleSectionExpansion(in page: UIView) {
        let key = ObjectIdentifier(page)
        guard !expandScheduledPages.contains(key) else { return }
        expandScheduledPages.insert(key)
        attemptSectionExpansion(in: page, attempt: 0)
    }

    private static func attemptSectionExpansion(in page: UIView?, attempt: Int) {
        guard let page, attempt >= 0, attempt < expandAttemptDelays.count else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + expandAttemptDelays[attempt]) { [weak page] in
            guard let page, page.window != nil else { return }
            if expandSectionFooters(in: page) { return }
            if attempt + 1 < expandAttemptDelays.count {
                attemptSectionExpansion(in: page, attempt: attempt + 1)
            } else {
                writeDebugLog(
                    "[EntityPageHeader] section expansion — no footer button after"
                        + " \(expandAttemptDelays.count) attempt(s)"
                )
            }
        }
    }

    /// 这一颗是不是"**原地展开**这一段"那颗 footer。
    ///
    /// ★★ 2026-10-17（第三版，日志 111 的现场）：上一版把判据放宽成"文字里出现
    ///   `显示全部 / show all / see all / すべて表示` 也算" —— **那是导航**，不是展开。
    ///   日志 111 逐字（进艺人页 1 秒后，连点三颗）：
    ///
    /// ```
    /// section expansion — activate.touchUpInside(…Encore…6Button9Secondary) on Components.UI.ListSectionFooter.Button
    /// section expansion — activate.touchUpInside(…Encore…6Button8Tertiary) on Components.UI.NavigationButtonHome
    /// section expansion — activate.touchUpInside(…Encore…6Button9Secondary) on Components.UI.ListSectionFooter.Button
    /// ```
    ///
    /// 第二颗是**标签栏的主页键**（`NavigationButtonHome`），第三颗把页面**导航到了「全部歌曲」**
    /// —— 用户的现场："进入的时候，是自动跳转 全部歌曲 这个东西的"。⇒ 判据收紧成三条：
    ///
    /// ① **必须**是 `ListSectionFooter` 那一族（id 里带这个词）—— 没有 id 的**一律不点**，
    ///    这就是上一版误点主页键的来源（它当时只靠文字命中）；
    /// ② 文字里要有"**更多**"（`更多 / more / もっと`）；
    /// ③ 文字里**不能**有"**全部**"（`全部 / all / すべて`）—— 那是"去完整列表"，点了就离开这一页。
    private static func isSectionFooter(_ control: UIControl) -> Bool {
        guard (control.accessibilityIdentifier ?? "").contains("ListSectionFooter") else { return false }
        // 文字两处都看：无障碍标签是一处，`UIButton.titleLabel` / 子树里的 UILabel 是另一处
        //（`eeveeControlText` 就是取后者 —— 自绘的 Encore 按钮往往只有它）。
        let text = [
            control.accessibilityLabel ?? "",
            control.accessibilityValue ?? "",
            eeveeControlText(of: control),
        ].joined(separator: " ").lowercased()
        guard !text.isEmpty else { return false }
        let expands = ["更多", "more", "もっと"].contains { text.contains($0) }
        let navigates = ["全部", "all", "すべて"].contains { text.contains($0) }
        return expands && !navigates
    }

    /// 点最多**两颗**「显示更多」；**点到了返回 true**（调用方据此停止重试）。
    ///
    /// ⚠️ 上一版最多点 4 颗 —— 页面上恰好有两颗 footer 时会连着导航两次（见 `isSectionFooter`）。
    /// 现在判据已经排除导航型，数量也收一半。
    private static func expandSectionFooters(in page: UIView) -> Bool {
        var found: [UIControl] = []
        var queue: [UIView] = [page]
        var visited = 0
        while !queue.isEmpty, visited < 1200, found.count < 2 {
            let view = queue.removeFirst()
            visited += 1
            if let control = view as? UIControl, isSectionFooter(control) {
                found.append(control)
                continue
            }
            queue.append(contentsOf: view.subviews)
        }

        guard !found.isEmpty else { return false }

        for control in found {
            let path = eeveeActivate(control) ?? "NOTHING"
            let identifier = String(describing: control.accessibilityIdentifier ?? "-")
            writeDebugLog("[EntityPageHeader] section expansion — \(path) on \(identifier)")
        }
        return true
    }

    /// 卡片高度（含与按钮行之间的间距）—— 页头排版与"页头长高"共用同一个数。
    private static let releaseCardRoom: CGFloat =
        EntityPageHeaderReleaseCard.height + EntityPageHeaderReleaseCard.spacing

    private static var headerBaseHeightKey: UInt8 = 0
    private static var didLogReleaseRoom = false

    /// ★★ 2026-10-17（用户二选一里选了 **A**：卡片画在我们自己的页头里）：
    /// 把艺人页的页头容器**加高**一张卡的高度。
    ///
    /// 为什么必须加高：`EntityPageHeaderView` 是**贴底排**的（`y = bounds.height - contentBottom -
    /// contentHeight`），内容一旦超过页头高度，整块会**向上溢出**，名字直接被顶出页头上面。
    ///
    /// ⚠️ 容器高度是 Spotify 自己算的 ⇒ 这里只改 `frame`，而且**每一拍补一次**（跟着
    /// `applyToArtistPage` 的频率）。第一次改时打一行 `[Release] header room — base → wanted`；
    /// 如果日志里看到它每拍都被写回去，说明那一层归 Auto Layout 管，就得换成
    /// "卡片挂在页头下缘 + 列表 `contentInset.top`"那条（交接文档 §5.2 的 B 方案）。
    private static func makeRoomForReleaseCard(in header: UIView) {
        guard let headerView = objc_getAssociatedObject(header, &entityPageHeaderKey) as? EntityPageHeaderView,
              headerView.hasReleaseCard else { return }
        guard header.bounds.height > 80 else { return }

        // ★ 只按**静止态**的页头量"原本多高"：缩成导航栏（100pt）那一拍量出来的值不能当底，
        //   否则写回去会把导航栏撑成一屏高。等下一次静止态再量。
        let stored = (objc_getAssociatedObject(header, &headerBaseHeightKey) as? NSNumber)?.doubleValue
        let base: CGFloat
        if let stored, stored > 200 {
            base = CGFloat(stored)
        } else if header.bounds.height > 200 {
            base = header.bounds.height
            objc_setAssociatedObject(
                header,
                &headerBaseHeightKey,
                NSNumber(value: Double(base)),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        } else {
            return
        }

        let wanted = base + releaseCardRoom
        guard abs(header.bounds.height - wanted) > 0.5 else { return }

        var frame = header.frame
        frame.size.height = wanted
        header.frame = frame

        if !didLogReleaseRoom {
            didLogReleaseRoom = true
            writeDebugLog(
                "[Release] header room — \(Int(base)) → \(Int(wanted))pt for the card"
            )
        }
    }

    /// 每一位艺人只取一次「最新发布」（缓存优先 ⇒ 同步就能画）。
    private static func scheduleLatestRelease(for headerView: EntityPageHeaderView, name: String) {
        // 已经有"艺人之选"⇒ 卡片归它（用户：优先展示艺人之选）。
        if let pick = artistPickCache[name] {
            applyPick(pick, to: headerView)
            return
        }

        if let cached = ArtistLatestReleaseSource.cached(for: name) {
            applyLatestRelease(cached, to: headerView)
            return
        }

        // 换艺人那一拍先把上一张藏掉（名字变了、卡片还印着上一张最难看）。
        if releaseArtist != name {
            headerView.updateRelease(title: nil, date: nil, meta: nil)
        }
        guard releaseArtist != name else { return }
        releaseArtist = name

        ArtistLatestReleaseSource.fetch(artist: name) { release in
            guard let current = lastArtistHeaderView, currentArtistName == name else { return }
            guard let release else {
                // ★ 2026-10-17（第二版）：取不到时要**留一行**，否则"卡片没出现"在日志上
                //   和"这段代码根本没跑"长得一模一样（数据源自己会先打一行 `iTunes search failed`）。
                writeDebugLog("[Release] no release for \"\(name)\" — the card stays hidden")
                return
            }
            applyLatestRelease(release, to: current)
            writeDebugLog("[Release] card shows the latest release for \"\(name)\"")
        }
    }

    private static func applyLatestRelease(_ release: ArtistLatestRelease, to headerView: EntityPageHeaderView) {
        let date = release.date.map { ArtistLatestReleaseSource.cardDateFormat.string(from: $0) }
        let meta = release.trackCount > 0
            ? String(format: "artist_latest_release_tracks".localized, release.trackCount)
            : nil
        headerView.updateRelease(
            title: release.title,
            date: date,
            meta: meta,
            artworkURL: release.artworkURL
        )
    }

    private static func applyPick(_ pick: ArtistPick, to headerView: EntityPageHeaderView) {
        headerView.updateRelease(
            title: pick.title,
            date: nil,
            meta: pick.meta,
            artwork: pick.artwork
        )
    }

    /// 标题行的文字是不是"艺人之选"这一块（多语言各写一条 —— Spotify 的 UI 跟着 App 语言走）。
    private static func isPickHeading(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let needles = [
            "艺人之选",
            "artist's pick",
            "artists pick",
            "artist pick",
            "アーティストのピックアップ",
            "アーティストピック",
        ]
        return needles.contains { lowered.contains($0) }
    }

    /// 往上找最近的 collection/table cell（标题行 → 装它的那一格）。
    private static func enclosingCell(of view: UIView) -> UIView? {
        var node: UIView? = view
        var levels = 0
        while let current = node, levels < 12 {
            if current is UICollectionViewCell || current is UITableViewCell { return current }
            node = current.superview
            levels += 1
        }
        return nil
    }

    /// 从"下一格"里抠出 pick：**最长的一段文字当标题**，另一段当副标题，第一张像样的图当封面。
    private static func makePick(from cell: UIView) -> ArtistPick? {
        var image: UIImage?
        var texts: [String] = []
        var queue: [UIView] = [cell]
        var visited = 0

        while !queue.isEmpty, visited < 120 {
            let view = queue.removeFirst()
            visited += 1
            if image == nil, let imageView = view as? UIImageView,
               let found = imageView.image, found.size.width > 40 {
                image = found
            }
            if let label = view as? UILabel,
               let text = label.text?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty, text.count <= 120 {
                texts.append(text)
            }
            queue.append(contentsOf: view.subviews)
        }

        var unique: [String] = []
        for text in texts where !unique.contains(text) { unique.append(text) }

        guard let title = unique.max(by: { $0.count < $1.count }) else { return nil }
        let meta = unique.first { $0 != title }
        return ArtistPick(title: title, meta: meta, artwork: image)
    }

    /// ★ 2026-10-18：设置页改了「艺人页」那两格之后，如果艺人页还在下面，**当场重跑一遍**。
    ///
    /// 设置页是盖在艺人页上的；它自己不一定会让下面的页面再布局一次。没有这一句的话，
    /// 用户切完开关要退回去再滚一下才看得到变化（月听众那行尤其明显）。
    static func reapplyArtistPageAppearance() {
        guard isEnabled, !applying,
              let page = lastArtistPage, page.window != nil else { return }
        applyToArtistPage(page)
    }

    /// 艺人页的页头容器：`TemplateKit` 的 `HeaderContainer`（**没有 accessibility id**，按类名认）。
    private static func artistHeaderContainer(in page: UIView) -> UIView? {
        var queue: [UIView] = [page]
        var visited = 0
        while !queue.isEmpty, visited < 400 {
            let view = queue.removeFirst()
            visited += 1
            if NSStringFromClass(type(of: view)).contains("HeaderContainer") { return view }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// ★★ 2026-10-18 第二轮（用户：「点击 i 按键不会跳转到艺人介绍」）：**"关于艺人"出现的那一拍就认下它**。
    ///
    /// 为什么不能靠搜：`applyToArtistPage` 里那次 BFS 从**页面根**出发，而真机日志 91 的树里
    /// `SPTArtistAboutBiographyView` 落在**深度 20**（`21.UIScrollView` → … → 那个 section，
    /// 旁边就是 `ArtistAboutListenersView` / `ListRow id=artist-about-listeners`）⇒ 日志 97 逐字
    /// `leading MISSING`：用户按了四次，我们只把页面往下滚，**从来没拿到目标**。
    /// 这个类**没有 accessibility id**，但它是 ObjC 类（`SPT*`）⇒ 直接挂它自己：事件驱动、零搜索。
    static func artistBiographyAppeared(_ view: UIView) {
        guard isEnabled else { return }
        guard isArtistPageAncestor(of: view) else { return }
        cachedArtistBio = view
        if let control = firstControl(in: view) { artistBioControl = control }
        captureBioTextOnSight(from: view)
    }

    /// ★★ 2026-10-11（**日志 101 + 图片 133 的现场**）：**这一块露头的那一刻就把正文读走**。
    ///
    /// 以前这里只记下"它在哪儿"（给 `i` 转发用），正文全靠进页面 1.5s 那一次扫列表 —— 而这张卡
    /// 是**懒加载**的：奈奈塚那次 1.5s 时整页还是 `leading MISSING`（日志 101 逐字），
    /// 卡片是用户自己滚下去、之后才建出来的 ⇒ **它出现了，我们却什么都没读**：
    /// `bioTexts` 一直空 ⇒ ① `i` 那张卡说"没有可读的介绍"；② 列表里那一段因为折叠闸门
    /// （`hasCapturedBio`）也不折 —— 用户两边都看不到，而 Spotify 自己那份其实就在页面上
    /// （图片 133 逐字：*Nanatsukaze is a Japan-based EDM × J-POP music duo…*）。
    ///
    /// 所以：**只要它露头就读**（必须当场读 —— cell 一被回收文字就没了），并按艺人名存起来；
    /// 存下来那一刻顺手作废一次布局，折叠闸门才打得开（见 `relayoutAfterBioCapture`）。
    private static func captureBioTextOnSight(from view: UIView) {
        let name = artistNameStorage
        guard !name.isEmpty else { return }

        // ★★ 2026-10-18（照片 141）：**社交链接那颗一起收下** —— 用户点名「原本有的维基 / 推特
        //    链接之类的没显示」。这一段是懒加载的，控件一被回收就没了 ⇒ 现在（露头那一刻）
        //    就把它们记下来，`ArtistBioSheet` 那颗胶囊点下去时再转发给它们自己。
        captureBioLinks(from: view, name: name)

        guard bioTexts[name] == nil, bioTexts.count < 32 else { return }
        // ★★ 2026-10-18（用户：「那个 i 点击之后，艺人简介在内可能会有分行，现在没有」）：
        //    同一张卡有两条读法：
        //      · `eeveeArtistBioText` —— 按 id 读**一颗** label，最准，但 Spotify 有时把整段
        //        塞进一个 label（段之间的换行只剩视觉段距，字符串里没有 `\n`）；
        //      · `eeveeArtistBioBlockText` —— 把卡里**每一颗** label 按位置拼起来，段与段之间
        //        天然有 `\n`（照片 141 那些分行就是它）。
        //    以前是"label 优先" ⇒ 一旦 label 读得到，就永远轮不到会有分行的 block。
        //    现在**两边都读，选换行更多的那一份**（内容由 `eeveeSanitizedArtistBio` 再收拾）。
        let labelText = eeveeArtistBioText(in: view)
        let blockText = eeveeArtistBioBlockText(in: view)
        let picked = Self.richerBioText(label: labelText, block: blockText)
        guard let raw = picked.text, !raw.isEmpty else { return }
        // ★★ 2026-10-18：**存之前先收拾** —— 卡里那两行"艺人名 / 每月有 x 名听众"不是简介
        //    （用户看照片 141 点名的"多出来一些其他东西"），见 `eeveeSanitizedArtistBio`。
        let text = eeveeSanitizedArtistBio(raw, artistName: name)
        guard !text.isEmpty else { return }
        bioTexts[name] = text
        writeDebugLog(
            "[ArtistBio] capture source — \(picked.source), label \(Self.lineCount(labelText)) line(s),"
                + " block \(Self.lineCount(blockText)) line(s), chose \(Self.lineCount(text)) line(s)"
        )
        writeDebugLog(
            "[EntityPageHeader] about-artist captured on sight — \(name), \(text.count) char"
                + (text.count == raw.count ? "" : " (cleaned from \(raw.count) char)")
        )
        if let page = eeveeAncestor(withIdentifier: "creator-page", of: view) {
            relayoutAfterBioCapture(in: page)
        }
    }

    /// 简介的两条读法里**换行更多**的那一份（见 `captureBioTextOnSight` 的说明）。
    private static func richerBioText(label: String?, block: String?) -> (text: String?, source: String) {
        switch (label, block) {
        case let (label?, block?):
            return lineCount(block) > lineCount(label) ? (block, "block") : (label, "label")
        case let (label?, nil):
            return (label, "label")
        case let (nil, block?):
            return (block, "block")
        default:
            return (nil, "none")
        }
    }

    private static func lineCount(_ text: String?) -> Int {
        guard let text else { return 0 }
        return text.components(separatedBy: "\n").count
    }

    /// 往上找页面根那个 `creator-page`（与 `EntityPageAppearance.isArtistPage` 同一个判据）。
    private static func isArtistPageAncestor(of view: UIView) -> Bool {
        var node: UIView? = view
        var level = 0
        while let current = node, level < 24 {
            level += 1
            if current.accessibilityIdentifier == "creator-page" { return true }
            node = current.superview
        }
        return false
    }

    /// 现在认下的"关于艺人"那一块（没有就是 nil）—— 给 `eeveeMaterialiseBio` 的"扫列表"用。
    ///
    /// ★★ 2026-10-18 第三轮（用户：「按下 i 之后还是没有跳转到 艺人介绍」）：那一块是懒加载的，
    /// 页面刚打开时整棵树只有 1000 来个节点 ⇒ 扫一遍列表把它逼出来之后，这里就能拿到它。
    static var artistBioTarget: UIView? { cachedArtistBio }

    /// 藏掉艺人页头里 Spotify 自己画的东西，**绕开那张照片**，而且**只用空 mask**（见 `eeveeBlank`）。
    private static func blankArtistChrome(in root: UIView, avoiding cover: UIView?, skipping ours: UIView) {
        for sub in root.subviews {
            if sub === ours { continue }
            // ⚠️★ 日志 90：同 `concealAlbumChrome` —— 我们自己的东西（页头、右上角那颗 ⋯、
            //    满幅封面）一律跳过，否则艺人页上那颗 `⋯` 也是永远 hidden。
            if isOurs(sub) { continue }
            if let cover {
                if sub === cover { continue }
                if cover.isDescendant(of: sub) {
                    blankArtistChrome(in: sub, avoiding: cover, skipping: ours)
                    continue
                }
            }
            eeveeBlank(sub)
        }
    }

    /// **歌手页那条 tab 栏（Music / Video / Merch）要走掉** —— pw 的 `ArtistField.x` 逐字：
    ///
    /// > The strip is Music, Video and Merch. The Music list is the page the Music app gives an artist:
    /// > the videos and the merch have their own tabs only so that they can be left out, so the strip
    /// > goes and the Music list stays. … it goes invisible and the pages under it move up into its
    /// > place and stop paging.
    ///
    /// 用 `alpha = 0`（**不是 hidden**：它在 `AutoLayoutStackView` 里，隐藏会 trap）+ 关交互，
    /// 再把同层的分页 scroll 整体上移一格的高度、并关掉分页。
    static func hideArtistTabStrip(in page: UIView) {
        guard let strip = eeveeFindView(page, identifier: "Components.UI.TabsSectionHeading") else { return }

        // 换了一页 / 旧记录已经失效 ⇒ 先把旧的写回去，再给这一条重新记原值。
        if let state = artistStripState, state.strip !== strip {
            restoreArtistStrip()
        }
        if artistStripState == nil {
            var pages: [ArtistStripPageState] = []
            if let parent = strip.superview {
                for sibling in parent.subviews {
                    guard let scroll = sibling as? UIScrollView else { continue }
                    pages.append(ArtistStripPageState(scroll: scroll))
                }
            }
            artistStripState = ArtistStripState(strip: strip, pages: pages)
        }

        if strip.alpha != 0 { strip.alpha = 0 }
        if strip.isUserInteractionEnabled { strip.isUserInteractionEnabled = false }
        strip.accessibilityElementsHidden = true

        let lift = strip.bounds.height
        guard lift > 0, let parent = strip.superview else { return }
        for sibling in parent.subviews {
            guard let pages = sibling as? UIScrollView else { continue }
            if pages.isScrollEnabled { pages.isScrollEnabled = false }
            let move = CGAffineTransform(translationX: 0, y: -lift)
            if pages.transform != move { pages.transform = move }
        }
        logOnce("artistStrip", "artist page: the Music/Video/Merch strip is gone, the Music list moved up \(Int(lift))pt")
    }

    /// 关掉「隐藏 Music / Video / Merch 标签栏」时，把 `hideArtistTabStrip` 动过的每一格写回。
    ///
    /// ★ 2026-10-18：这颗开关默认是**开**（保持 2026-10-17 以来的观感）；关掉时必须能还原，
    /// 否则用户只能重启 Spotify 才能看见标签栏。记录只存**原值**，不猜"应该是什么"。
    static func restoreArtistStrip() {
        guard let state = artistStripState else { return }
        if let strip = state.strip {
            strip.alpha = state.alpha
            strip.isUserInteractionEnabled = state.interactive
            strip.accessibilityElementsHidden = state.accessibilityHidden
        }
        for page in state.pages {
            guard let scroll = page.scroll else { continue }
            scroll.isScrollEnabled = page.enabled
            scroll.transform = page.transform
        }
        artistStripState = nil
        writeDebugLog("[EntityPageHeader] artist page: the Music/Video/Merch strip is back (the hide-tabs switch is off)")
    }

    /// 是不是**我们自己**插进 Spotify 视图树里的东西 —— 统一靠 id 前缀 `eevee-` 认。
    ///
    /// ★ 2026-10-06（日志 90 抓到）：**藏"头里除我们那份以外的一切"时必须跳过这些**。
    /// 原来只按两个具体 id 跳（页头 `EntityPageHeaderView` 与满幅封面 `eevee-page-hero-sharp`），
    /// 于是后加的 `eevee-pinned-more`（右上角那颗 ⋯）被顺手藏了：它在**歌单页**是好的
    /// （那颗挂在 `PL.Header` 上），一切到**专辑页/艺人页**就永远是 `hidden`
    /// —— 那两条路每拍都在藏"头里除了页头以外的一切"，而它已经被搬进那棵树里了。
    ///
    /// 判据改成前缀之后，以后再往 Spotify 的树里插自己的视图，不用回来补这一行。
    private static func isOurs(_ view: UIView) -> Bool {
        (view.accessibilityIdentifier ?? "").hasPrefix("eevee-")
    }

    /// 藏掉专辑页头里 Spotify 自己画的东西，**绕开封面那一支**。
    ///
    /// ⚠️ 为什么不能像歌单页那样整支藏（`for sub in block.subviews { eeveeConceal(sub) }`）：
    /// 专辑页的封面与标题**在同一支**里（顶部 group 装着"封面方块 + 标题块"），而封面归
    /// `EntityPageAppearance.concealNativeCover` 管 —— **那边记了原值**。`eeveeConceal` 不记原值，
    /// 这边再藏一次就会把"已经藏了"写进对面的原值记录 ⇒ 关掉开关封面再也回不来。
    ///
    /// 规则：**含封面的一支只递归、不整支藏**；封面自己跳过；其余整支藏掉。
    private static func concealAlbumChrome(in root: UIView, avoiding cover: UIView?, skipping ours: UIView) {
        for sub in root.subviews {
            if sub === ours { continue }
            // ⚠️★ 日志 90：**我们自己插的一律跳过**（见 `isOurs`）—— 顺手藏掉 `eevee-pinned-more`
            //    就是这么发生的。原来这里那一行只跳满幅封面，覆盖不到后加的东西。
            if isOurs(sub) { continue }
            if let cover {
                if sub === cover { continue }
                if cover.isDescendant(of: sub) {
                    concealAlbumChrome(in: sub, avoiding: cover, skipping: ours)
                    continue
                }
            }
            eeveeConceal(sub)
        }
    }

    /// ★ 2026-10-17（日志 94：`followSignals isSelected=false selectedTrait=false label="-" text=""`
    /// —— **四条信号全是空的**，所以绿描边点不亮）：把 Follow 那颗的**子树**打一次，看"已关注"
    /// 到底画在哪个类上、状态挂在哪个属性上。只打一次，60 个节点以内。
    ///
    /// ⚠️ 为什么不能靠猜：`Encore.Button.Secondary` 是 Spotify 自己的按钮，标题可能不是 `UILabel`
    /// （SwiftUI 宿主 / 自绘都见过），状态也可能既不在 `isSelected` 也不在无障碍特征上。
    /// 这一行日志一次性把"类名 / id / label / value / 文字 / 选中特征"全列出来。
    private static func probeFollowSubtree(_ follow: UIView?) {
        guard !didProbeFollow, let follow else { return }
        didProbeFollow = true

        var lines: [String] = []
        var queue: [(view: UIView, depth: Int)] = [(follow, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 60 {
            let (view, depth) = queue.removeFirst()
            visited += 1
            let kind = NSStringFromClass(type(of: view))
            let id = view.accessibilityIdentifier ?? "-"
            let label = view.accessibilityLabel ?? "-"
            let value = view.accessibilityValue ?? "-"
            let selected = view.accessibilityTraits.contains(.selected)
            var text = "-"
            if let asLabel = view as? UILabel { text = asLabel.text ?? "-" }
            if let asButton = view as? UIButton {
                text = asButton.title(for: .normal) ?? asButton.title(for: .selected) ?? "-"
            }
            lines.append(
                "\(depth):\(kind) id=\(id) label=\(label) value=\(value) text=\(text) sel=\(selected)"
            )
            guard depth < 3 else { continue }
            for sub in view.subviews { queue.append((sub, depth + 1)) }
        }
        writeDebugLog(
            "[EntityPageHeader] follow subtree (\(visited) node(s)): \(lines.joined(separator: " | "))"
        )
    }

    /// **往上找"仍然恰好包着这个控件"的最外层视图** —— pw 的 `wrapperFor`（`AlbumHeader.x`）逐字：
    ///
    /// > The outermost view that still wraps the control exactly: the element view Spotify's layout
    /// > places, so concealing it leaves the control itself alone to be read and fired.
    ///
    /// ★ 2026-10-13（用户：「这播放旁边的图标是重合的还没修吗…」）：**这才是"重合"的正解**。
    /// 只藏控件本身的话，那颗按钮的**圆底/边框画在它的父视图上**、还留在原地 ⇒ Spotify 的圆
    /// 与我们的玻璃圆叠在一起，看着就是"两个图标重合"。往上收到"尺寸不再变化"的那一层再藏，
    /// 整个按钮（含圆底）一起消失。
    /// ★ 2026-10-13（用户编译报错：`value of optional type 'UIView?' must be unwrapped`）：
    /// **参数与返回值都做成可选** —— 调用方那四颗（play / shuffle / add / download）本来就是
    /// `UIView?`（找不到就是 nil），而 `eeveeConceal` 收的也是 `UIView?`。
    /// 做成可选之后 `eeveeConceal(wrapperFor(play, in: page))` 一句就合法，
    /// 不必在四个调用点各写一次 `if let`（那条路还会漏掉其中一个）。
    private static func wrapperFor(_ control: UIView?, in stop: UIView) -> UIView? {
        guard let control else { return nil }
        var wrapper = control
        var node: UIView? = control.superview
        // ⚠️ 加一道**层数上限**（pw 没有，但它那边的 `stop` 就是页面）：万一祖先链上连着几层同尺寸的
        //    包装容器，走到页面那一层就会把**整页**藏掉 —— 那是灾难性的。5 层足够收住一颗按钮。
        var levels = 0
        while let current = node, current !== stop, levels < 5 {
            levels += 1
            if abs(current.bounds.width - control.bounds.width) > 4 { break }
            if abs(current.bounds.height - control.bounds.height) > 4 { break }
            wrapper = current
            node = current.superview
        }
        return wrapper
    }

    /// ★ 2026-10-13（照 AM）：把 `⋯` **钉在页头的右上角**。
    ///
    /// AM 在那一格放的是一颗"**分享 + ⋯**"的玻璃胶囊；而 **Spotify 的专辑页/艺人页没有独立的分享按钮**
    /// —— 我们全仓日志里 `ShareButton*`（`ShareButtonNowPlayingView` / `lyrics-share-button`）只出现在
    /// **听歌页与歌词页**，专辑页与艺人页的分享是 `⋯` 菜单里的一项。所以这里**只做 `⋯` 一颗**，
    /// 不去造一颗点不动的假分享键（本项目纪律：绝不留下"看得见、点不动"的东西）。
    ///
    /// pw 的 `SGRPinnedMore` 是同一件事，它的注释逐字：
    ///
    /// > the Kit's pinned ⋯ (`SGRPinnedMore`) draws and fires it from the top trailing corner of the
    /// > page, level with the back button.
    ///
    /// 藏 Spotify 行里那颗走 `wrapperFor`（连它的圆底一起）—— 否则同一页上会出现两颗 `⋯`。
    private static func pinMoreButton(in headerRoot: UIView) {
        // ★★ 2026-10-17（用户：「歌单页右上角那三个点点击没反应」——他说这个"等会做也行"，
        //    但根因与播放键是同一个：按 id 拿到的是 `ElementView<…>` 包装层）⇒ 一起改成 `findControl`。
        guard let menu = findControl("Components.UI.ContextMenuButton*", in: headerRoot, cache: &cachedMore) else {
            // 这一页没有 `⋯`（或者还没建出来）⇒ 什么都不做，**也不留一颗假的**。
            //
            // ★★ 2026-10-16（用户：「右上角那个**点不动**的三点」）：这里原来**静默返回**，
            //    而 `pinnedMore` 是**文件级静态**、一旦建出来就留在屏上 —— 于是"Spotify 重建了页头、
            //    弱引用 `source` 失效"这种情况会留下一颗**永远点不动、日志里也没有任何痕迹**的按钮。
            //    现在留一行日志（只在"屏上已经有我们那颗"时报一次），下一份日志就能分清
            //    "这一页没有 ⋯" 与 "有，但源丢了"。
            if let stale = pinnedMore, stale.window != nil, !didReportPinnedMoreMissing {
                didReportPinnedMoreMissing = true
                writeDebugLog(
                    "[EntityPageHeader] pinned ⋯ is still on screen but Spotify's ContextMenuButton is gone"
                        + " — the button has no source and will do nothing"
                )
            }
            return
        }
        didReportPinnedMoreMissing = false

        let side = EntityPageHeaderMetrics.pinnedMoreSide
        let more: EntityPageHeaderButton
        if let existing = pinnedMore {
            more = existing
        } else {
            more = EntityPageHeaderButton()
            more.accessibilityIdentifier = "eevee-pinned-more"
            pinnedMore = more
            writeDebugLog(
                "[EntityPageHeader] pinned the ⋯ into the top trailing corner, level with the back button"
                    + " (AM's corner; Spotify keeps its own ⋯ hidden in the row)"
            )
        }
        // ★★ 2026-10-18（用户：「**歌单页点击三点无反应**；艺人页点击三点会崩溃」）：
        //    **挂到 window 上，不再塞进页头**。日志 105 的 `[HeaderProbe] page ids:` 里
        //    歌单页那一段**根本没有 `eevee-pinned-more`**，而艺人页有 —— 说明它在歌单页
        //    要么被页头/导航栏盖住、要么根本不在一条能收到触摸的链上。
        //    window 是最后加、最上面的一层：位置用 window 坐标算，不会再被页头折叠带走。
        //    离开实体页时由 `EntityPageAppearance.restore` 调 `removePinnedMore()` 收走。
        guard let host = headerRoot.window else { return }
        if more.superview !== host {
            host.addSubview(more)
        } else if host.subviews.last !== more {
            host.bringSubviewToFront(more)
        }

        // 与左上角那颗返回键同高：window 坐标 + 安全区。
        let top = host.safeAreaInsets.top + 4
        let frame = CGRect(
            x: host.bounds.width - side - 16,
            y: top,
            width: side,
            height: side
        )
        if more.frame != frame { more.frame = frame }
        if !didReportPinnedMoreGeometry {
            didReportPinnedMoreGeometry = true
            let inWindow = more.convert(more.bounds, to: host)
            writeDebugLog(
                "[EntityPageHeader] pinned ⋯ geometry — host window \(Int(host.bounds.width))x\(Int(host.bounds.height)),"
                    + " safeTop \(Int(host.safeAreaInsets.top)), button at \(Int(inWindow.minX)),\(Int(inWindow.minY)),"
                    + " interactive \(more.isUserInteractionEnabled), hidden \(more.isHidden)"
            )
        }
        more.feed(from: menu)
        // ★★ 2026-10-16（用户：「右上角那个**点不动**的三点」）：三件事一起补上 ——
        //   ① `role = "more"`：日志里那颗原来一直是默认的 `side button`，分不出是谁（见 `tapped`）；
        //   ② **`fireTarget = menu`**：转发目标从**弱引用** `source` 换成这颗真实控件 ——
        //      `source` 一旦被回收（Spotify 重建页头）就变成一颗**静默失效**的按钮；
        //   ③ `firesDeep = true`：前三档都落空时再往祖先链/选中回调那一档找（见 `eeveeFireWide`）。
        //
        // ★★ 2026-10-17 第六轮（用户：「艺人页／专辑页右上角三个点还是点不动」，日志 109 判决）：
        //    **不再跳过 target/action**（`skipsControlAction = false`），而且**不再把源控件藏死**。
        //
        //    日志 109 的两行是关键：
        //      · `⋯ clickability — targets=[touchUpInside=EncoreControlEventHandler…]` ⇒ 它**有** target；
        //      · `more tapped — … fired: NOTHING (no action and no tap recogniser)` ⇒ 我们**跳过了**那一档，
        //        而手势那一档失败（它的 `UITapGestureRecognizer` 读不出 `_targets`）。
        //    pw 的 `SGRFire`（`Kit/SGRRestyle.m`）走的正是我们跳过的那一档：
        //      `primaryActionTriggered` → `touchUpInside` → 都没有才 `accessibilityActivate`；
        //    而且 pw 藏东西只加**空 mask**（`blank()` 逐字："Not hidden — the header's OverflowStackView
        //    traps when a view in it hides, and a hidden view is one the redesign still has to read and fire"）。
        //    我们原来用 `eeveeConceal`（`layer.isHidden` + 空 mask）⇒ 一个 **hidden** 的视图，
        //    UIKit 侧拿不到可用的锚点，菜单自然弹不出来（日志 100 那句"发成功了但界面一动没动"）。
        more.role = "more"
        more.fireTarget = menu
        more.skipsControlAction = false
        more.firesDeep = true

        // ★★ 2026-10-17：**只遮不藏**（`eeveeBlank`：空 mask + 关交互 + 关无障碍，`isHidden` 一个都不碰）。
        //   见上面 pw 那段引文 —— 这颗按钮**必须还是一个"活着"的控件**，菜单才弹得出来。
        eeveeBlank(wrapperFor(menu, in: headerRoot))
    }

    /// ★ 2026-10-18（用户：「歌单页进入后还是能往上接着划……进入的位置可以上移吗」）：
    /// 把隐藏的搜索框那一行的**真实 frame / 父链 / 滚动 offset / topInset** 打一次。
    /// 下一份日志就能分清"空档是那一行的高度"还是"contentInset 多了一截"，再决定折高度还是改 offset。
    private static func reportPlaylistMetrics(headerRoot: UIView, findField: UIView) {
        guard !didReportPlaylistMetrics else { return }
        didReportPlaylistMetrics = true

        var chain: [String] = []
        var node: UIView? = findField
        var level = 0
        while let current = node, level < 4 {
            let frame = current.convert(current.bounds, to: headerRoot)
            chain.append(
                "\(NSStringFromClass(type(of: current)))"
                    + " \(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))"
            )
            node = current.superview
            level += 1
        }

        let scroll = eeveeOutermostScroll(from: headerRoot)
        let offset = scroll.map { "\(Int($0.contentOffset.x)),\(Int($0.contentOffset.y))" } ?? "-"
        let inset = scroll.map { "\(Int($0.adjustedContentInset.top))" } ?? "-"
        let host = headerRoot.window ?? headerRoot
        let headerFrame = headerRoot.convert(headerRoot.bounds, to: host)
        writeDebugLog(
            "[EntityPageHeader] playlist find-field chain — \(chain.joined(separator: " < "));"
                + " scroll offset=\(offset) topInset=\(inset);"
                + " PL.Header \(Int(headerFrame.minY))h\(Int(headerFrame.height))"
        )
    }

    /// ★ 2026-10-18：离开实体页时把挂在 window 上的 `⋯` 收走（见 `pinMoreButton`）。
    static func removePinnedMore(reason: String = "") {
        guard let more = pinnedMore else { return }
        more.removeFromSuperview()
        pinnedMore = nil
        didReportPinnedMoreMissing = false
        didReportPinnedMoreGeometry = false
        writeDebugLog(
            "[EntityPageHeader] pinned ⋯ removed"
                + (reason.isEmpty ? "" : " (\(reason))")
        )
    }

    /// 专辑页的文字：**按明确的 id 读**（pw 的 `applyHeader` 用同样这三个 id）。
    private static func albumTexts(in header: UIView) -> HeaderTexts {
        var texts = HeaderTexts()

        if let title = find("CreativeWorkPlatform.Components.UI.TitleRow", in: header, cache: &cachedAlbumTitleRow),
           let label = firstLabel(in: title, skipping: nil) {
            texts.title = label.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        if let parent = find("CreativeWorkPlatform.Components.UI.ParentRow", in: header, cache: &cachedAlbumParentRow) {
            if let label = firstLabel(in: parent, skipping: nil) {
                texts.creator = label.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            } else {
                texts.creator = parent.accessibilityLabel ?? ""
            }
        }
        if let metadata = find("Components.UI.MetadataRow", in: header, cache: &cachedAlbumMetadata) {
            texts.length = metadataLine(metadata)
        }

        // 标题兜底：id 没找到时退回"字号最大的那个标签"（与歌单页同一条兜底）。
        if texts.title.isEmpty, let label = biggestLabel(in: header, skipping: []) {
            texts.title = label.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return texts
    }

    /// 专辑页那行是**两格**（kind 与日期各是一个 cell、各一个 label）。
    /// pw 的 `metadataText` 逐字：按**画出来的顺序**（x 从小到大）读，空格连接。
    private static func metadataLine(_ root: UIView) -> String {
        var parts: [(x: CGFloat, text: String)] = []
        forEachView(root) { view in
            guard let label = view as? UILabel, label.window != nil else { return }
            let text = (label.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            parts.append((label.convert(.zero, to: root).x, text))
        }
        parts.sort { $0.x < $1.x }
        return parts.map(\.text).joined(separator: " ")
    }

    /// 从 `root` 往下找**第一个真正的控件**（`UIControl`，含自身）。
    ///
    /// ★★ 2026-10-06（照片 113 + 用户报的三件事其实是**同一个**根因）：
    ///   · 专辑页的**随机播放点了没反应**；
    ///   · 艺人页的**播放键没反应**；
    ///   · 右边那颗**关注没有点击反馈**（"加入了音乐库会变绿"—— 状态本来是有的）。
    ///
    /// 因为 `findFloating` 在页面上按 id 找到的往往是**外面那层 `ElementView<…>` 包装**
    /// （我们自己的树里那一行全是 `ElementView<URL, Any, Any>`），而不是能响应 `sendActions` /
    /// `handleTap` 的那颗按钮：转发打在包装上 = 没反应；`(source as? UIControl)?.isSelected`
    /// 也恒为假 ⇒ 永远不变绿。**歌单页没有这个问题**，因为它从页头里按 id 直接拿到了真控件。
    private static func firstControl(in root: UIView) -> UIView? {
        if root is UIControl { return root }
        var queue: [UIView] = root.subviews
        var visited = 0
        while !queue.isEmpty, visited < 400 {
            let view = queue.removeFirst()
            visited += 1
            if view is UIControl { return view }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// pw 的 `floatingIn`（`AlbumHeader.x`）：那两颗浮动控件是**页面的直接子视图、48pt 上下**，
    /// 而头、wash、列表都是整页宽 —— 只搜"小尺寸的直接子视图"，免得每一拍走一整棵树。
    private static func findFloating(_ identifier: String, in page: UIView, cache: inout UIView?) -> UIView? {
        if let cached = cache, cached.window != nil, cached.isDescendant(of: page) { return cached }
        var found: UIView?
        for sub in page.subviews where sub.bounds.width <= 120 {
            if let hit = eeveeFindView(sub, identifier: identifier) {
                // ★ 钻到真正的控件（见 `firstControl`）：命中的若是包装层，点了就是没反应。
                //   缓存里存的**也是钻过之后的那一个**，所以每拍不会重走这一趟。
                found = firstControl(in: hit) ?? hit
                break
            }
        }
        cache = found
        return found
    }

    /// 那一块"文字 + 控件"：`HeaderContentLayout` 里**宽度接近整页**的那个孩子
    /// （封面方形与满幅图都排除掉）。
    ///
    /// 按宽度取而不是"取最靠下的"：Liked Songs 的 layout 里还有一个 45pt 的图标槽位，
    /// 加载途中它会落在 block 下面，按"最靠下"会把它当成 block（pw 在真机上因此把页头画了两遍）。
    private static func blockIn(_ layout: UIView, cover: UIView?, fullbleed: UIView?) -> UIView? {
        let wide = layout.bounds.width * 0.6
        var block: UIView?
        for sub in layout.subviews {
            if sub === cover || sub === fullbleed { continue }
            if sub is EntityPageHeaderView { continue }
            if sub.bounds.width < wide { continue }
            if block == nil || sub.frame.minY > block!.frame.minY { block = sub }
        }
        return block
    }

    // MARK: - 读文字

    private struct HeaderTexts {
        var title = ""
        var creator = ""
        var length = ""
        var about = ""
    }

    /// ★ 2026-10-13（性能）：**上一拍认下的那四个标签**。
    ///
    /// 日志 86 逐字：`[Perf][EntityPageHeader] 200 passes, 140.53 ms total, 0.703 ms avg` ——
    /// 而 `HeaderContentLayout.layoutSubviews` 在页头折叠时**每一帧**都会来（用户那边就是
    /// 「用较快的速度往下滑，会有渲染跟不上的问题」）。原来每一拍要走 **5~8 次整棵子树遍历**：
    /// 封面 1 次 + `Metadata*` 最多 3 次 + 脸堆 1 次 + 标题 1 次 + 创建者 1 次，全落在主线程上。
    ///
    /// pw 的每一步查找都带 `static char` key（`SGRFindByIdentifier`：命中过就不再搜树）——
    /// 这里照它的纪律，把**引用**留下，之后每一拍只读 `.text`。
    /// 引用一旦离开那棵树（Spotify 换了 label、换了页面）就整批作废，重新认一次。
    private struct TextViews {
        weak var title: UILabel?
        weak var creator: UILabel?
        weak var length: UILabel?
        weak var about: UILabel?
    }

    /// 文本来源**分两级**（pw 的分法）：标题/描述优先读页面的 view model，创建者与长度读
    /// Spotify 自己那些**被藏起来的标签**（所以语言永远跟着 Spotify 走）。
    ///
    /// ⚠️ 9.1.88 上 model 那条路的存在性**没证实**（`dump-9.1.88.txt` 里没有
    /// `defaultHeaderViewModel` / `playlistName` 这两个名字）⇒ 一律 `responds(to:)` 守卫，
    /// 拿不到就退回标签启发式。**标签兜底才是这里的主路径**。
    /// ★ 2026-10-13（性能）：上一拍认下的四个标签还在那棵树上 ⇒ **只读 `.text`**（每帧一次，成本≈0）。
    /// 认不出来（进页面第一拍、或者 Spotify 换了 label）才走下面那条完整的启发式。
    private static func headerTexts(block: UIView, headerRoot: UIView) -> HeaderTexts {
        if let views = cachedTextViews, let title = views.title, title.isDescendant(of: block) {
            var texts = HeaderTexts()
            texts.title = title.text ?? ""
            texts.creator = views.creator?.text ?? ""
            texts.length = views.length?.text ?? ""
            texts.about = views.about?.text ?? ""
            return texts
        }
        let (texts, views) = headerTextsSlow(block: block, headerRoot: headerRoot)
        cachedTextViews = views
        return texts
    }

    /// 完整那条：**只在缓存失效时走**（进页面那一拍、换页面、Spotify 换掉标签）。
    /// 返回的 `views` 为 `nil` = "这一页的值不完全是标签读来的"（view model 参与了）⇒ 不许走快路。
    private static func headerTextsSlow(block: UIView, headerRoot: UIView) -> (HeaderTexts, TextViews?) {
        var texts = HeaderTexts()
        var views = TextViews()
        var fromModel = false

        let model = viewModel(from: headerRoot)
        if let model {
            if let name = modelString(model, "playlistName") { texts.title = name; fromModel = true }
            if let about = plainText(modelString(model, "playlistDescription")) { texts.about = about; fromModel = true }
        }

        // 长度：Spotify 自己那行（`Components.Header.UI.Metadata*`）—— **只查一次**（原来这条最多查三次）。
        let metadata = metadataView(block)
        if let metadata, let label = firstLabel(in: metadata, skipping: nil) {
            texts.length = label.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            views.length = label
        }

        // 创建者：脸堆（FacepileView）那一行里、除了脸堆以外的第一个非空标签。
        var facepile: UIView?
        forEachView(block) { view in
            if facepile == nil, NSStringFromClass(type(of: view)).contains("FacepileView") { facepile = view }
        }
        if let facepile {
            var row: UIView? = facepile.superview
            var level = 0
            while let current = row, current !== block, level < 3 {
                if let label = firstLabel(in: current, skipping: facepile) {
                    texts.creator = label.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    views.creator = label
                    break
                }
                row = current.superview
                level += 1
            }
        }

        // 标题兜底：block 里**字号最大**的那个标签（页头里最大的字就是标题），
        // 同字号取最靠上的。排除长度那行与创建者那行。
        if texts.title.isEmpty, let label = biggestLabel(in: block, skipping: [facepile, metadata]) {
            texts.title = label.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            views.title = label
        }

        // 描述兜底：只剩**一个**没被认领的标签、而且它够长时才用它（宁可没有，不要贴错）。
        if texts.about.isEmpty {
            let leftovers = unclaimedLabels(in: block, facepile: facepile, metadata: metadata)
            if leftovers.count == 1, let only = leftovers.first,
               let text = only.text?.trimmingCharacters(in: .whitespacesAndNewlines), text.count > 12 {
                texts.about = text
                views.about = only
            }
        }

        // view model 参与了 ⇒ 值不是（也不该）从标签读的，快路会读错 ⇒ 这一页禁用快路。
        return (texts, fromModel ? nil : views)
    }

    private static func metadataView(_ block: UIView) -> UIView? {
        eeveeFindView(block, identifier: "Components.Header.UI.Metadata*")
    }

    /// 字号最大的那个标签（页头里最大的字就是标题）。返回**标签本身**而不是文本 ——
    /// 调用方要把它当引用缓存下来，之后每一拍只读 `.text`（见 `TextViews`）。
    private static func biggestLabel(in root: UIView, skipping skip: [UIView?]) -> UILabel? {
        var best: (size: CGFloat, y: CGFloat, label: UILabel)?
        forEachView(root) { view in
            guard let label = view as? UILabel else { return }
            for skipped in skip.compactMap({ $0 }) where view.isDescendant(of: skipped) { return }
            let text = (label.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let size = label.font.pointSize
            let y = label.convert(.zero, to: root).y
            if let current = best {
                if size > current.size || (size == current.size && y < current.y) {
                    best = (size, y, label)
                }
            } else {
                best = (size, y, label)
            }
        }
        return best?.label
    }

    /// block 里还没被认领的标签（标题/创建者/长度之外的那些）。
    private static func unclaimedLabels(in block: UIView, facepile: UIView?, metadata: UIView?) -> [UILabel] {
        var labels: [UILabel] = []
        let biggest = biggestLabel(in: block, skipping: [facepile, metadata])
        var titleTaken = false
        forEachView(block) { view in
            guard let label = view as? UILabel else { return }
            if let facepile, view.isDescendant(of: facepile) { return }
            if let metadata, view.isDescendant(of: metadata) { return }
            let text = (label.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count > 1 else { return }
            if !titleTaken, let biggest, label === biggest { titleTaken = true; return }
            labels.append(label)
        }
        return labels
    }

    /// 那一行里第一个非空标签。返回**标签本身**，理由同 `biggestLabel`（引用要留下来当缓存）。
    private static func firstLabel(in root: UIView, skipping skip: UIView?, longerThan minimum: Int = 1) -> UILabel? {
        var found: UILabel?
        forEachView(root) { view in
            guard found == nil, let label = view as? UILabel else { return }
            if let skip, view.isDescendant(of: skip) { return }
            let text = (label.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count > minimum { found = label }
        }
        return found
    }

    private static func forEachView(_ root: UIView, _ body: (UIView) -> Void) {
        var queue: [UIView] = [root]
        var visited = 0
        while !queue.isEmpty, visited < 1500 {
            let view = queue.removeFirst()
            visited += 1
            body(view)
            queue.append(contentsOf: view.subviews)
        }
    }

    /// HTML 描述（`<a>` 链接与 `&amp;` 之类的实体）→ 纯文本。
    private static func plainText(_ html: String?) -> String? {
        guard let html, !html.isEmpty else { return nil }
        var text = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&quot;": "\"", "&#x27;": "'", "&#39;": "'",
                        "&lt;": "<", "&gt;": ">", "&nbsp;": " "]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - 读 view model（能找到就用，找不到算了）

    /// 沿 responder 链找页面的 view model：先问 `defaultHeaderViewModel` / `headerViewModel`，
    /// 再问 `headerController` 要一个。**每个 selector 都先 `responds(to:)`**。
    private static func viewModel(from view: UIView) -> AnyObject? {
        var responder: UIResponder? = view
        var guardCount = 0
        while let current = responder, guardCount < 40 {
            guardCount += 1
            if let object = current as? NSObject {
                for name in ["defaultHeaderViewModel", "headerViewModel"] {
                    if let value = performObject(object, name) { return value }
                }
                if let controller = performObject(object, "headerController") as? NSObject,
                   let value = performObject(controller, "defaultHeaderViewModel") {
                    return value
                }
            }
            responder = current.next
        }
        return nil
    }

    private static func performObject(_ object: NSObject, _ name: String) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector), let value = object.perform(selector) else { return nil }
        return value.takeUnretainedValue()
    }

    private static func modelString(_ model: AnyObject, _ name: String) -> String? {
        guard let object = model as? NSObject,
              let value = performObject(object, name) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func logOnce(_ key: String, _ message: String) {
        guard logged.insert(key).inserted else { return }
        writeDebugLog("[EntityPageHeader] \(message)")
    }
}

// MARK: - 挂点

func activateEntityPageHeader() {
    // 两个开关共用这一条每帧的布局拍：AM 页头（`entityPageAMHeader`）与"满幅封面 + 取色底"
    // （`entityPageDissolve`）。**任一打开这条钩子就得在**，否则满幅封面那条路又退回 0.6s 的 tick。
    guard EntityPageHeaderManager.isEnabled || EntityPageAppearance.isEnabled else { return }

    let required = [
        EntityPageHeaderLayoutHook.targetName,
        EntityPagePlayButtonHook.targetName,
    ]
    let missing = required.filter { NSClassFromString($0) == nil }
    guard missing.isEmpty else {
        writeDebugLog("[EntityPageHeader] skipped — missing \(missing.joined(separator: ", "))")
        return
    }

    EntityPageHeaderGroup().activate()
    // 专辑页 / 艺人页那两条路都是**可选**的：类不在就少做一页（不能因为一个可选的类把整组拖垮）。
    let album = NSClassFromString(EntityPageAlbumLayoutHook.targetName) != nil
    let artist = NSClassFromString(EntityPageArtistLayoutHook.targetName) != nil
    // ★★ 2026-10-18 第二轮：`SPTArtistAboutBiographyView` 那条也是可选的 —— 它不在就等于"关于艺人"
    //    只能靠 `applyToArtistPage` 那条兜底搜索（每页两拍），日志里会写出来。
    //    ★ 2026-10-11（日志 101）：**真正露头的是下面那个 `CreatorBiographyCardLayout`** ——
    //    两个各报各的，少一个就少一条事件线（日志里必须一眼看得出缺哪个）。
    let bio = NSClassFromString(ArtistBiographyViewHook.targetName) != nil
    let bioCard = NSClassFromString(ArtistBiographyCardLayoutHook.targetName) != nil
    // ⚠️ 这一组**单独装**（见 `ArtistBioCardHookGroup` 的说明）：名字里带私有哈希，
    //    换一版就可能解析不到 —— 解析不到就只是少一条事件线，不能连累共用组。
    if bioCard { ArtistBioCardHookGroup().activate() }
    // ★★ 2026-10-18：Spotify 自己的「关于艺人」数据线（`SPTArtistAboutDataLoader`）——
    //    装得上就等于"一进页面就有**完整正文 + 真链接**"；装不上就退回界面读文字那条老路
    //    （走的是哪一条，日志里都写清楚）。
    //    ⚠️ 探测在 `ArtistAboutDataLoaderProbe` 里、不在 hook 类里 —— Orion 不准 hook 类
    //       带 `static func`（见那个 enum 的说明）。
    let aboutLoader = ArtistAboutDataLoaderProbe.canInstall(
        className: SPTArtistAboutDataLoaderHook.targetName
    )
    if aboutLoader { ArtistAboutDataHookGroup().activate() }
    let aboutEncoding = ArtistAboutDataLoaderProbe.typeEncoding(
        className: SPTArtistAboutDataLoaderHook.targetName
    )
    writeDebugLog(
        "[EntityPageHeader] on — AM header \(EntityPageHeaderManager.isEnabled ? "ON" : "OFF"),"
            + " page look \(EntityPageAppearance.isEnabled ? "ON" : "OFF")"
            + " (one layout pass drives both; playlist pages"
            + (album ? " + album pages" : "; album hook missing")
            + (artist ? " + artist pages)" : "; artist hook missing")
            + (bio ? "; about-artist hook on" : "; about-artist hook MISSING")
            + (bioCard ? " + card-layout hook on" : " + card-layout hook MISSING")
            + (aboutLoader ? " + about-data hook on" : " + about-data hook MISSING")
            + " (encoding \(aboutEncoding))"
    )
}
