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
        writeDebugLog(
            "[ArtistBio] our own about-artist sheet — name "
                + (name.isEmpty ? "MISSING" : name)
                + ", biography "
                + (text == nil ? "NOT READ (0 char)" : "\(text?.count ?? 0) char")
        )
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
        card.backgroundColor = Self.cardColour(from: colour)
        card.layer.cornerRadius = 24
        card.layer.cornerCurve = .continuous
        card.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        card.clipsToBounds = true
        addSubview(card)

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
        bodyView.textContainerInset = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        bodyView.font = .systemFont(ofSize: 17)
        bodyView.textColor = UIColor.white.withAlphaComponent(0.92)
        card.addSubview(bodyView)

        // ★★ 2026-10-18 第四轮（用户：「关于艺人 的来源你有什么好方法么」）：正文**优先用 Spotify 那份**
        //    （跟着 app 语言、官方）；**读不到才去 Genius 要一份**（免 key 的那条现成线，见 `ArtistBioSource`；
        //    英文，而且必须署名）。两条都没有就留一句说明 + 那颗 Wikipedia 链接。
        if let text {
            bodyView.text = text
        } else {
            bodyView.text = "artist_bio_empty".localized
            ArtistBioSource.geniusBio(for: name) { [weak self] genius in
                guard let self, let genius else { return }
                self.bodyView.text = genius
                self.creditLabel.text = "artist_bio_from_genius".localized
                self.creditLabel.isHidden = false
            }
        }

        // 页脚：左边一颗**维基百科链接**（只给入口、**不抄文本** ⇒ 不欠 CC BY-SA 的署名 ——
        // Spotify 自己的 About 页也是这么干的：`SPTArtistAbout:sArtistWikipediaButtonTitle`，dump:21079），
        // 右边一句来源署名（走 Genius 那条时才显示）。
        let wiki = UIButton(type: .system)
        wiki.setTitle("artist_bio_wikipedia".localized, for: .normal)
        wiki.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        wiki.setTitleColor(UIColor.white.withAlphaComponent(0.85), for: .normal)
        wiki.frame = CGRect(x: 12, y: card.bounds.height - footer, width: 170, height: 40)
        wiki.autoresizingMask = [.flexibleTopMargin]
        wiki.contentHorizontalAlignment = .left
        wiki.addTarget(self, action: #selector(wikipediaTapped), for: .touchUpInside)
        card.addSubview(wiki)
        wikiURL = Self.wikipediaURL(for: name)

        creditLabel.font = .systemFont(ofSize: 13)
        creditLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        creditLabel.textAlignment = .right
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
    /// wiki 主机按 app 语言挑（zh / ja / en，其余落 en）。
    private static func wikipediaURL(for name: String) -> URL? {
        let language = String(Locale.preferredLanguages.first?.prefix(2) ?? "en").lowercased()
        let host = ["zh", "ja", "en"].contains(language) ? language : "en"
        guard var components = URLComponents(string: "https://\(host).wikipedia.org/wiki/Special:Search") else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "search", value: name)]
        return components.url
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
