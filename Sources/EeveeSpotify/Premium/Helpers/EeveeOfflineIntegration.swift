import Foundation
import UIKit
import Darwin
import ObjectiveC.runtime
import MediaPlayer

/// Routes the native download action to the bundled audio engine.
/// Never forwards supported music downloads to Spotify's offline service.
enum EeveeOfflineIntegration {
    // The local library posts this immediately before starting AVAudioPlayer.
    private static let pauseSpotifyObserver: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: Notification.Name("EeveeOfflineWillPlay"), object: nil, queue: .main
    ) { _ in
        let center = MPNowPlayingInfoCenter.default()
        let rate = (center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue
        if rate == 1 || (rate == nil && center.playbackState == .playing) {
            _ = WordByWordPlaybackControl.togglePlayPause()
        }
    }
    static func download(_ uri: NSURL) {
        guard let reference = uri.absoluteString else { return }
        invoke("download:", reference: reference as NSString)
    }

    static func showLibrary() { invoke("showLibrary", reference: nil) }

    private static func invoke(_ name: String, reference: NSString?) {
        _ = pauseSpotifyObserver
        DispatchQueue.main.async {
            let path = Bundle.main.bundlePath + "/Frameworks/EeveeOfflineAudio.framework/EeveeOfflineAudio"
            guard dlopen(path, RTLD_NOW) != nil,
                  let cls = NSClassFromString("EeveeOfflineBridge"),
                  let method = class_getClassMethod(cls, Selector(name)) else {
                PopUpHelper.showPopUp(message: "No se pudo cargar el motor de descargas. Instala el IPA con EeveeOfflineAudio incluido.", buttonText: "Aceptar")
                return
            }
            if let reference {
                typealias Download = @convention(c) (AnyClass, Selector, NSString) -> Void
                unsafeBitCast(method_getImplementation(method), to: Download.self)(cls, Selector(name), reference)
            } else {
                typealias Open = @convention(c) (AnyClass, Selector) -> Void
                unsafeBitCast(method_getImplementation(method), to: Open.self)(cls, Selector(name))
            }
        }
    }
}
