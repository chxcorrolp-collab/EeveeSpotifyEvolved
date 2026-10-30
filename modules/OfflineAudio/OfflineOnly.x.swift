import Foundation
import UIKit
import Orion
import ObjectiveC.runtime
import Darwin

struct OfflineButtonGroup: HookGroup {}

// The class and selector are checked at launch because Spotify may rename private APIs.
struct EeveeOfflineOnly: Tweak {
    init() {
        let selector = Selector("downloadToggledWithCurrentAvailability:addAction:removeAction:pageIdentifier:pageURI:interactionID:")
        if let cls = NSClassFromString(OfflineDownloadButtonHook.targetName),
           class_getInstanceMethod(cls, selector) != nil {
            OfflineButtonGroup().activate()
        }
    }
}

class OfflineDownloadButtonHook: ClassHook<NSObject> {
    typealias Group = OfflineButtonGroup
    static let targetName = "Offline_ContentOffliningUIImpl.ContentOffliningUIHelperImplementation"

    func downloadToggledWithCurrentAvailability(
        _ availability: NSInteger,
        addAction: NSObject,
        removeAction: NSObject,
        pageIdentifier: NSString,
        pageURI: NSURL,
        interactionID: NSString
    ) {
        guard let reference = pageURI.absoluteString else { return }
        DispatchQueue.main.async {
            let path = Bundle.main.bundlePath + "/Frameworks/EeveeOfflineAudio.framework/EeveeOfflineAudio"
            guard dlopen(path, RTLD_NOW) != nil,
                  let cls = NSClassFromString("EeveeOfflineBridge"),
                  let method = class_getClassMethod(cls, Selector("download:")) else {
                let alert = UIAlertController(title: "Descargas locales", message: "No se pudo cargar el motor de descargas.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Aceptar", style: .default))
                if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
                   let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController {
                    var top = root
                    while let shown = top.presentedViewController { top = shown }
                    top.present(alert, animated: true)
                }
                return
            }
            typealias Download = @convention(c) (AnyClass, Selector, NSString) -> Void
            unsafeBitCast(method_getImplementation(method), to: Download.self)(cls, Selector("download:"), reference as NSString)
        }
    }
}
