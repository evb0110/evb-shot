import AppKit
import Sparkle

/// Sparkle owns download verification, replacement, rollback, and relaunch.
/// Installation always needs the user's action and waits for active captures.
@MainActor
final class AppUpdates: NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    private(set) var controller: SPUStandardUpdaterController!
    var isBusy: () -> Bool = { false }
    var onChange: (() -> Void)?
    private var pendingInstall: (() -> Void)?
    private var observation: NSKeyValueObservation?
    private(set) var updateAvailable = false

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
    }
    func start() { controller.startUpdater() }
    var canCheck: Bool { controller.updater.canCheckForUpdates && !isBusy() }
    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
    @objc func checkForUpdates(_ sender: Any?) {
        guard canCheck else { return }
        controller.checkForUpdates(sender)
    }
    func activityChanged() {
        onChange?()
        guard !isBusy(), let install = pendingInstall else { return }
        pendingInstall = nil; install()
    }
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if isBusy() { throw ShotError("Finish your capture or save before checking for updates.") }
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard isBusy() else { return false }
        pendingInstall = installHandler; return true
    }
    // Background checks never bring an update alert over a screencast.
    var supportsGentleScheduledUpdateReminders: Bool { true }
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool { !isBusy() }
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        updateAvailable = true; onChange?()
    }
    func standardUserDriverWillFinishUpdateSession() { updateAvailable = false; onChange?() }

    static func verifyLifecycle() throws {
        let updates = AppUpdates()
        var busy = true, installs = 0
        updates.isBusy = { busy }
        do {
            try updates.updater(updates.controller.updater, mayPerform: .updates)
            throw ShotError("Updates must not interrupt an active capture")
        } catch let error as ShotError {
            try SelfTest.check(error.localizedDescription.contains("Finish your capture"),"active capture blocks updater checks")
        }
        let item = SUAppcastItem.empty()
        let postponed = updates.updater(updates.controller.updater,shouldPostponeRelaunchForUpdate:item,untilInvokingBlock:{ installs += 1 })
        try SelfTest.check(postponed && installs == 0,"update relaunch waits for active work")
        updates.activityChanged()
        try SelfTest.check(installs == 0,"activity notifications cannot interrupt active work")
        busy = false; updates.activityChanged(); updates.activityChanged()
        try SelfTest.check(installs == 1,"queued update installation resumes exactly once when idle")
        try updates.updater(updates.controller.updater,mayPerform:.updates)
        print("PASS Sparkle capture/save guard and deferred installation lifecycle")
    }
}
