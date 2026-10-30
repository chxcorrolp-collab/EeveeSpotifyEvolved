import Foundation
import SwiftUI
import UIKit

@objc(EeveeOfflineBridge)
public final class EeveeOfflineBridge: NSObject {
    @objc public static func download(_ reference: String) {
        Task { @MainActor in
            let store = MusicStore.shared
            store.link = reference
            await store.openLink()
            if store.notice == nil { store.enqueueAlbum() }
            showLibrary()
        }
    }
    @objc public static func showLibrary() {
        DispatchQueue.main.async {
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
                  let window = scene.windows.first(where: { $0.isKeyWindow }),
                  var top = window.rootViewController else { return }
            while let presented = top.presentedViewController { top = presented }
            let view = RootView().environmentObject(MusicStore.shared).tint(Color.green).preferredColorScheme(.dark)
            top.present(UIHostingController(rootView: view), animated: true)
        }
    }
}

struct DownloadStatusView: View {
    @EnvironmentObject var store: MusicStore
    var body: some View {
        NavigationStack {
            List {
                if store.loading { ProgressView("Leyendo canciones…") }
                ForEach(store.catalog?.tracks ?? []) { track in
                    VStack(alignment: .leading) {
                        Text(track.title)
                        Text(store.errors[track.id] ?? store.phases[track.id] ?? (store.saved(track.id) == nil ? "Pendiente" : "Descargada"))
                            .font(.caption).foregroundStyle(.secondary)
                        if let progress = store.progress[track.id] { ProgressView(value: progress) }
                        if store.errors[track.id] != nil { Button("Reintentar") { store.enqueue(track) } }
                    }
                }
            }.navigationTitle("Descargas")
        }
    }
}
