import Foundation
import AppKit
import Combine
import Sparkle

/// Wraps Sparkle so the app updates itself from the public release feed.
///
/// Updates download silently in the background. When one is ready, Sparkle hands us a block
/// that installs it right away; the tab bar then shows "Update ready · Restart Dal" (like
/// GitKraken's status bar). Ignoring it is fine too: Sparkle installs the update when Dal quits.
@MainActor
final class Updater: NSObject, ObservableObject {
    private var controller: SPUStandardUpdaterController!
    private var installNow: (() -> Void)?
    private var lastBackgroundCheck = Date.distantPast

    @Published var canCheckForUpdates = false
    /// Version waiting to be installed ("0.1.4"), set once its download has finished.
    @Published var readyVersion: String?

    /// Debug builds don't poll the real feed; `DAL_FEED_URL` points them at a test feed.
    private let feedOverride = ProcessInfo.processInfo.environment["DAL_FEED_URL"]

    override init() {
        super.init()
        #if DEBUG
        let start = feedOverride != nil
        #else
        let start = true
        #endif
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        guard start else { return }
        controller.updater.automaticallyDownloadsUpdates = UserDefaults.standard.object(forKey: "downloadUpdatesAutomatically") as? Bool ?? true
        controller.startUpdater()
        checkInBackground()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkInBackground() }
        }
    }

    /// Quiet check, at most once an hour (on launch and when the app comes to the front).
    func checkInBackground() {
        guard Date().timeIntervalSince(lastBackgroundCheck) > 3600 || feedOverride != nil,
              controller.updater.sessionInProgress == false else { return }
        lastBackgroundCheck = Date()
        controller.updater.checkForUpdatesInBackground()
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Installs the downloaded update and relaunches Dal.
    func installAndRelaunch() {
        if let installNow {
            installNow()
        } else {
            // No silent download pending; fall back to the standard update window.
            controller.checkForUpdates(nil)
        }
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloads: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set {
            controller.updater.automaticallyDownloadsUpdates = newValue
            UserDefaults.standard.set(newValue, forKey: "downloadUpdatesAutomatically")
        }
    }

    /// "0.1.2" — what people mean by "which version am I on".
    var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}

extension Updater: SPUUpdaterDelegate {
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        #if DEBUG
        return ProcessInfo.processInfo.environment["DAL_FEED_URL"]
        #else
        return nil   // Release builds only ever use SUFeedURL
        #endif
    }

    /// Called once a silently downloaded update is ready. Returning true means "we'll offer it":
    /// the badge appears, and Sparkle still installs it on quit if the badge is never clicked.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.installNow = immediateInstallHandler
                self?.readyVersion = version
            }
        }
        return true
    }
}
