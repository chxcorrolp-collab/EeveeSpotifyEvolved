#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

// Replace only the native download action; Spotify's view controllers stay untouched.
static void eeveeDownload(id receiver, SEL selector, NSInteger availability,
                          id addAction, id removeAction, id pageIdentifier,
                          NSURL *pageURI, id interactionID) {
    NSString *reference = pageURI.absoluteString;
    if (reference.length == 0) return;
    NSString *path = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/EeveeOfflineAudio.framework/EeveeOfflineAudio"];
    Class bridge = dlopen(path.fileSystemRepresentation, RTLD_NOW) ? NSClassFromString(@"EeveeOfflineBridge") : Nil;
    SEL download = NSSelectorFromString(@"download:");
    if (bridge && [bridge respondsToSelector:download]) {
        ((void (*)(id, SEL, NSString *))objc_msgSend)(bridge, download, reference);
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Descargas locales"
        message:@"No se pudo cargar el motor de descargas." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Aceptar" style:UIAlertActionStyleDefault handler:nil]];
    for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        UIViewController *top = scene.windows.firstObject.rootViewController;
        while (top.presentedViewController) top = top.presentedViewController;
        [top presentViewController:alert animated:YES completion:nil];
        break;
    }
}

static BOOL eeveeInstall(void) {
    Class target = NSClassFromString(@"Offline_ContentOffliningUIImpl.ContentOffliningUIHelperImplementation");
    SEL action = NSSelectorFromString(@"downloadToggledWithCurrentAvailability:addAction:removeAction:pageIdentifier:pageURI:interactionID:");
    Method method = target ? class_getInstanceMethod(target, action) : NULL;
    if (!method) return NO;
    method_setImplementation(method, (IMP)eeveeDownload);
    return YES;
}

static void eeveeWaitForSpotify(unsigned attempt) {
    if (eeveeInstall() || attempt >= 120) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
        eeveeWaitForSpotify(attempt + 1);
    });
}

__attribute__((constructor)) static void eeveeStart(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ eeveeWaitForSpotify(0); });
}
