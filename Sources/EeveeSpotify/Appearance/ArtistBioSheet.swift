import Foundation
import UIKit

/// 「艺人介绍」——**我们自己的**那一张（2026-10-18 第三轮）。
///
/// 用户原话：「要不点击 i 之后不要 spotify 自己的了，把原本的 spotify 的 关于艺人 给去掉，我们自己搞」。
///
/// ## 正文从哪来（为什么不自己联网取）
///
/// 从 **Spotify 自己那个 `SPTArtistAboutBiographyView`** 里读（`eeveeLongestText`，见
/// `EntityPageHeader.swift`）—— 不引入新接口、不碰 token，读到的就是官方那份（也就是跟着 app 语言走的）
/// 文案 ✓。列表里那一段同时被折成 0 高（`EntityPageSectionDrop.aboutArtistFragment`），页面上不留重复 ✓。
///
/// ⚠️ 正文是**懒加载**的：页面刚打开时那一块还没建出来 ⇒ 点击 `i` 先"扫一遍列表"把它逼出来
/// （`eeveeMaterialiseBio`），**在同一个主线程回合里读走文字**（cell 一旦被回收就没了）。
///
/// ## 形态
///
/// 照 AM：底部一张卡片（顶部圆角、深色、可滚动），标题是艺人名，右上角一颗 ×，点背景也能关。
/// 读不到正文时不留白 —— 写一句话说明，并把"读了几个字"打进日志（下一份日志就能判断是不是被截断了）。
final class ArtistBioSheet: UIView {

    private static weak var current: ArtistBioSheet?

    private let card = UIView()
    private let titleLabel = UILabel()
    private let bodyView = UITextView()
    /// 来源署名（只有走 Genius 那条兜底时才显示 —— 它的条款要求署名）。
    private let creditLabel = UILabel()
    /// 那一颗 Wikipedia 链接的地址（`build` 里按 app 语言算好）。
    private var wikiURL: URL?
    /// **已经真的显示了正文**吗（占位那句不算）—— 只给"原生正文晚一拍到了"那条补看用，
    /// 免得把已经取到的 Genius / 维基正文又盖掉。
    private var hasBody = false
    /// 卡片**静止时**的 y（下滑关闭时用它回弹 / 判"滑够了没有"）。
    private var cardRestY: CGFloat = 0

    /// 弹一张（同时只留一张：连点两次不会叠）。
    static func present(name: String, text: String?, colour: UIColor?) {
        guard let window = EntityPageAppearance.frontWindow() else { return }
        current?.removeFromSuperview()

        let sheet = ArtistBioSheet(frame: window.bounds)
        sheet.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sheet.build(name: name, text: text, colour: colour)
        window.addSubview(sheet)
        current = sheet

        sheet.alpha = 0
        UIView.animate(withDuration: 0.2) { sheet.alpha = 1 }
        // ★★ 2026-10-11：这里原来还有一条"sheet presented + name/source/biography"的日志 ——
        //   它与 `build` 里那条**完全重复**（`build` 就在上面一行被调用），已删。
        //   现在那一行的内容更全：来源、**走哪条分支**、原生读到几个字，都在 `build` 里打。
    }

    static func dismissCurrent() {
        current?.removeFromSuperview()
        current = nil
    }

    // MARK: - 搭

    private func build(name: String, text: String?, colour: UIColor?) {
        backgroundColor = UIColor.black.withAlphaComponent(0.45)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(backdropTapped)))

        let height = min(max(240, bounds.height * 0.58), 560)
        card.frame = CGRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
        card.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
        // ★★ 2026-10-16（用户：「把艺人页的 `i` 点击后换成**液态玻璃**，并且可下滑关闭」）：
        //    卡片底改成**真玻璃**（`GlassCapsule.makeGlassView`：iOS 26 的 `UIGlassEffect`
        //    带折射与边缘高光；拿不到就退 `.systemUltraThinMaterialDark`，见那个工厂的说明），
        //    底下再垫一层**很淡的取色** —— 纯玻璃压在浅色照片上时白字会看不清，
        //    这一层就是给对比度兜底的（原来是**不透明**色块，所以「换成玻璃」才看得出来）。
        card.backgroundColor = Self.cardColour(from: colour).withAlphaComponent(0.28)
        card.layer.cornerRadius = 24
        card.layer.cornerCurve = .continuous
        card.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        card.clipsToBounds = true
        let glass = GlassCapsule.makeGlassView(wantsInteractive: false).view
        glass.frame = card.bounds
        glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        card.insertSubview(glass, at: 0)
        addSubview(card)

        cardRestY = card.frame.origin.y
        // 下滑关闭（见 `cardPanned`）：正文那层滚动仍然交给 `bodyView`，
        // 手势**什么时候该让位**由 `gestureRecognizerShouldBegin` 判（正文没滚到顶就不抢）。
        let pan = UIPanGestureRecognizer(target: self, action: #selector(cardPanned))
        pan.delegate = self
        card.addGestureRecognizer(pan)

        titleLabel.text = name
        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.frame = CGRect(x: 20, y: 18, width: card.bounds.width - 88, height: 28)
        titleLabel.autoresizingMask = [.flexibleWidth]
        card.addSubview(titleLabel)

        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark"), for: .normal)
        close.tintColor = UIColor.white.withAlphaComponent(0.85)
        close.frame = CGRect(x: card.bounds.width - 56, y: 12, width: 44, height: 44)
        close.autoresizingMask = [.flexibleLeftMargin]
        close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        card.addSubview(close)

        let footer: CGFloat = 52
        bodyView.frame = CGRect(
            x: 16,
            y: 58,
            width: card.bounds.width - 32,
            height: card.bounds.height - 58 - footer
        )
        bodyView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        bodyView.backgroundColor = .clear
        bodyView.isEditable = false
        bodyView.isScrollEnabled = true
        bodyView.showsVerticalScrollIndicator = true
        // ★★ 2026-10-16（用户：「艺人简介这部分**可能会自带社交软件链接**，比如推特、维基百科什么的」）：
        //    那段正文是 Spotify 给的原样文本（我们一个字都不改），里面就可能有 URL ——
        //    打开**链接识别**让它可点（点开走系统 Safari）。我们不自己解析、也不重排文字。
        bodyView.isSelectable = true
        bodyView.dataDetectorTypes = [.link]
        bodyView.textContainerInset = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        bodyView.font = .systemFont(ofSize: 17)
        bodyView.textColor = UIColor.white.withAlphaComponent(0.92)
        card.addSubview(bodyView)

        // ★★ 2026-10-18 第四轮：**来源由设置里那一项决定**（`UserDefaults.artistBioSource`，见
        //    `ArtistBioSourceKind`）：
        //      · `.automatic`（默认）—— Spotify 原生优先，读不到才退 Genius；
        //      · `.spotify` / `.genius` / `.wikipedia` —— 只用那一个（读不到就一句说明 + 链接）。
        //    ⚠️ `text` 是**扫列表时顺手读的**那份：`automatic` / `spotify` 用它，另两个选项**忽略**它。
        //      ★ 2026-10-11：扫列表现在**主要为"读到正文"服务** —— 折叠排在读取之后
        //      （`EntityPageSectionDrop` 的闸门是 `hasCapturedBio`）：读不到就**不折**。
        // ★★ 2026-10-11（真机日志 100）：**每一档都要看得出是哪一档**。
        //   以前四档在"取不到"时渲染出**一模一样**的卡片（同一句占位 + 底部那颗"维基百科"按钮）
        //   ⇒ 用户换完设置再点 `i`，观感"还是之前的那个"。现在：
        //     ① 走哪条分支、原生读到几个字，进日志；
        //     ② 底部那行署名**永远显示**，写清实际来源与失败原因；
        //     ③ 底部那颗按钮改成明确的**链接**文案（它本来只是个入口，不是来源标签）。
        let source = UserDefaults.artistBioSource
        writeDebugLog(
            "[ArtistBio] sheet — name \(name.isEmpty ? "MISSING" : name)"
                + ", source \(source.rawValue) (\(source)), native text "
                + (text.map { "\($0.count) char" } ?? "none")
        )
        switch source {
        case .spotify:
            if let text {
                show(text, credit: "artist_bio_from_spotify".localized)
            } else {
                showFailure("artist_bio_spotify_failed".localized)
                // 原生那份可能只是**还没建出来**（懒加载）⇒ 盯一会儿，抓到就补上。
                watchForNativeText(name)
            }
        case .genius:
            loadGenius(name)
        case .wikipedia:
            loadWikipedia(name)
        case .automatic:
            if let text {
                show(text, credit: "artist_bio_from_spotify".localized)
            } else {
                loadGenius(name)
                // 同上：Genius 在跑，原生那份晚一拍到了就换成它（`.automatic` = 原生优先）。
                watchForNativeText(name)
            }
        }

        // 页脚：左边一颗**维基百科链接**（只给入口、**不抄文本** ⇒ 不欠 CC BY-SA 的署名 ——
        // Spotify 自己的 About 页也是这么干的：`SPTArtistAbout:sArtistWikipediaButtonTitle`，dump:21079），
        // 右边一句**永远显示**的来源署名/状态（★ 2026-10-11：以前只有成功时才显示 —— 于是四档
        // 在失败时长得一模一样，用户以为设置没生效）。
        let wiki = UIButton(type: .system)
        // ★★ 2026-10-11（真机日志 100 的反馈「底部仍然显示 维基百科」）：它一直是个**入口按钮**，
        //   但文案与"来源"混在一起，用户就把它当成了来源标签 ⇒ 换成明确的链接说法。
        wiki.setTitle("artist_bio_open_wikipedia".localized, for: .normal)
        wiki.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        wiki.setTitleColor(UIColor.white.withAlphaComponent(0.85), for: .normal)
        wiki.frame = CGRect(x: 12, y: card.bounds.height - footer, width: 170, height: 40)
        wiki.autoresizingMask = [.flexibleTopMargin]
        wiki.contentHorizontalAlignment = .left
        wiki.addTarget(self, action: #selector(wikipediaTapped), for: .touchUpInside)
        card.addSubview(wiki)
        wikiURL = Self.wikipediaURL(for: name)

        creditLabel.font = .systemFont(ofSize: 12)
        creditLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        creditLabel.textAlignment = .right
        // ★★ 2026-10-11：两行 —— 失败原因那句比"来自 Genius"长
        //   （"维基百科没有响应（本机网络可能屏蔽了它）"）。
        creditLabel.numberOfLines = 2
        creditLabel.isHidden = true
        creditLabel.frame = CGRect(
            x: card.bounds.width - 198,
            y: card.bounds.height - footer,
            width: 186,
            height: 40
        )
        creditLabel.autoresizingMask = [.flexibleTopMargin, .flexibleLeftMargin]
        card.addSubview(creditLabel)
    }

    @objc private func wikipediaTapped() {
        guard let wikiURL else { return }
        UIApplication.shared.open(wikiURL, options: [:], completionHandler: nil)
        writeDebugLog("[ArtistBio] wikipedia link opened")
    }

    /// 维基百科那条**链接**：用**搜索页**（省掉"先找条目"这一步，同名艺人也不怕），
    /// wiki 主机与取词那条线**共用** `ArtistBioSource.wikipediaHost()`（免得两处漂）。
    private static func wikipediaURL(for name: String) -> URL? {
        guard var components = URLComponents(
            string: "https://\(ArtistBioSource.wikipediaHost())/wiki/Special:Search"
        ) else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "search", value: name)]
        return components.url
    }

    /// 正文 + 底部那行**永远显示**的署名/状态。
    private func show(_ body: String, credit: String) {
        bodyView.text = body
        hasBody = true
        setCredit(credit)
    }

    /// ★★ 2026-10-11（**日志 101**）：**原生正文晚一拍才抓到时，把这张已经开着的卡片补上**。
    ///
    /// 为什么需要：那张卡是懒加载的（见 `EntityPageHeaderManager.artistBiographyAppeared` 的说明）
    /// —— 用户点 `i` 的**那一刻**它可能还没建出来，日志 101 里 `native text none` 就是这么来的，
    /// 而几秒之后卡片才露头、正文才被 `captureBioTextOnSight` 读走。
    /// 盯 6 秒（12 × 0.5s）：一拿到就写上去，仍按 `.automatic` 的口径"原生优先"，
    /// **但绝不盖掉已经真的显示出来的正文**（`hasBody`）。
    private func watchForNativeText(_ name: String) {
        guard !name.isEmpty else { return }
        for step in 1...12 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.5) { [weak self] in
                guard let self, self.superview != nil, !self.hasBody else { return }
                guard let text = EntityPageHeaderManager.cachedBioText(for: name) else { return }
                self.show(text, credit: "artist_bio_from_spotify".localized)
            }
        }
    }

    /// 拿不到正文：正文照旧那句说明，但**底部必须说清是哪一档没取到**（以前四种失败长得一样）。
    private func showFailure(_ credit: String) {
        bodyView.text = "artist_bio_empty".localized
        setCredit(credit)
    }

    private func setCredit(_ text: String) {
        creditLabel.text = text
        creditLabel.isHidden = false
    }

    /// Genius 那条（**英文**，卡片上要署名）。
    private func loadGenius(_ name: String) {
        bodyView.text = "artist_bio_empty".localized
        setCredit("artist_bio_loading".localized)
        ArtistBioSource.geniusBio(for: name) { [weak self] bio in
            guard let self else { return }
            guard let bio else {
                self.setCredit("artist_bio_genius_failed".localized)
                return
            }
            self.bodyView.text = bio
            self.hasBody = true
            self.setCredit("artist_bio_from_genius".localized)
        }
    }

    /// 维基百科那条（**CC BY-SA**：要署名 + 给许可链接 —— 页脚那颗 Wikipedia 按钮就是那个链接）。
    private func loadWikipedia(_ name: String) {
        bodyView.text = "artist_bio_empty".localized
        setCredit("artist_bio_loading".localized)
        ArtistBioSource.wikipediaBio(for: name) { [weak self] bio in
            guard let self else { return }
            guard let bio else {
                self.setCredit("artist_bio_wikipedia_failed".localized)
                return
            }
            self.bodyView.text = bio
            self.hasBody = true
            self.setCredit("artist_bio_from_wikipedia".localized)
        }
    }

    /// 卡片底色：跟着这一页的取色走（太暗就抬一点，免得和页面糊成一片）。
    private static func cardColour(from colour: UIColor?) -> UIColor {
        guard let colour else { return UIColor(white: 0.13, alpha: 1) }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 1
        guard colour.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
            return UIColor(white: 0.13, alpha: 1)
        }
        return UIColor(
            hue: hue,
            saturation: min(1, saturation * 0.9),
            brightness: max(0.16, min(0.34, brightness * 0.72)),
            alpha: 1
        )
    }

    // MARK: - 关

    @objc private func backdropTapped(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self)
        // 点卡片里面不关（`bodyView` 的滚动、选中都要能用）。
        if card.frame.contains(point) { return }
        dismiss()
    }

    @objc private func closeTapped() {
        dismiss()
    }

    /// **下滑关闭**（2026-10-16，用户点名要的）。
    ///
    /// 判据照系统 sheet：滑过卡片高度的 30% **或者**放手时向下速度 > 800pt/s 就关，
    /// 否则弹回原位（用弹簧，手感与 `GlassCapsule` 那套一致）。
    /// ⚠️ 正文还在滚的时候**不抢手势** —— 见 `gestureRecognizerShouldBegin`。
    @objc private func cardPanned(_ pan: UIPanGestureRecognizer) {
        let offset = max(0, pan.translation(in: self).y)

        switch pan.state {
        case .changed:
            card.frame.origin.y = cardRestY + offset
            alpha = max(0.35, 1 - offset / max(1, card.bounds.height))
        case .ended, .cancelled, .failed:
            let velocity = pan.velocity(in: self).y
            if offset > card.bounds.height * 0.3 || velocity > 800 {
                dismissFromDrag()
            } else {
                UIView.animate(
                    withDuration: 0.28,
                    delay: 0,
                    usingSpringWithDamping: 0.86,
                    initialSpringVelocity: 0
                ) {
                    self.card.frame.origin.y = self.cardRestY
                    self.alpha = 1
                }
            }
        default:
            break
        }
    }

    private func dismissFromDrag() {
        UIView.animate(
            withDuration: 0.22,
            animations: {
                self.card.frame.origin.y = self.bounds.height
                self.alpha = 0
            },
            completion: { _ in
                self.removeFromSuperview()
                if ArtistBioSheet.current === self { ArtistBioSheet.current = nil }
            }
        )
    }

    private func dismiss() {
        UIView.animate(
            withDuration: 0.18,
            animations: { self.alpha = 0 },
            completion: { _ in
                self.removeFromSuperview()
                if ArtistBioSheet.current === self { ArtistBioSheet.current = nil }
            }
        )
    }
}

/// 下滑关闭那条手势的"让位"规则。
extension ArtistBioSheet: UIGestureRecognizerDelegate {

    /// **只在"下拉卡片"这一种情况下开始**，其余全让给正文那层滚动：
    ///   · 方向必须是**向下**（横向 / 向上都不抢）；
    ///   · 手指落在正文里、而正文**还没滚到顶** ⇒ 那是用户在滚正文，不是在下拉卡片。
    ///
    /// 为什么不做"同时识别"：那样拖正文会一边滚一边把卡片往下拽，手感是坏的。
    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let pan = gesture as? UIPanGestureRecognizer else { return true }

        let translation = pan.translation(in: self)
        guard translation.y > 0, abs(translation.y) > abs(translation.x) else { return false }

        let point = pan.location(in: card)
        if bodyView.frame.contains(point), bodyView.contentOffset.y > 0 { return false }
        return true
    }
}
