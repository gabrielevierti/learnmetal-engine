// The iPhone and iPad app: a window, and in it the engine's view controller running the game.
// Everything else is in Swift/FPVKit, shared with the Mac version.

import FPVKit
import LMEngine
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = EngineViewController(game: FPVGame())
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
