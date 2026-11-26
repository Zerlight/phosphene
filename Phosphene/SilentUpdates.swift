import AppKit
import AppUpdater
import Foundation
import Observation
import os
import Tiptoe

/// The app's updater: downloads from GitHub Releases, verifies, and swaps the bundle in place —
/// silently when the user allows it, on an explicit install otherwise.
///
/// The heavy lifting is [Tiptoe](https://github.com/artginzburg/Tiptoe) over mxcl/AppUpdater:
/// AppUpdater checks the release, downloads the DMG, and verifies the Team ID against the running
/// app; Tiptoe decides *when* the swap may run, waiting for the Mac to go quiet. The swap restarts
/// the app — harmless for a menu bar controller (the wallpaper extension is a separate process and
/// keeps playing) — except while a video optimization is running, so the gate below vetoes exactly
/// that. The gate is a veto, not a preference: Tiptoe's own patience relaxes over days, this never
/// does.
///
/// One check loop serves both modes: with auto-update off the check still runs and still
/// answers ``availableVersion`` — the menu bar badge and version chip draw from it — but nothing
/// downloads or installs except through ``updateNow(version:)``.
///
/// The loop ticks every ``checkInterval``; between ticks, opening the popover or waking the Mac
/// repeats the check once it is ``staleAfter`` old, and the version chip's refresh button makes
/// one on demand. Each is a single GitHub metadata request, which GitHub itself caches for a
/// minute.
@MainActor
@Observable
final class SilentUpdates {
    static let shared = SilentUpdates()

    static let owner = "kageroumado"
    static let repo = "phosphene"

    /// The chip announces a release within hours of it shipping, so a fix reaches people the
    /// same day; the request is one cached metadata call.
    private static let checkInterval: TimeInterval = 4 * 60 * 60

    /// A check older than this is repeated when the popover opens or the Mac wakes: the loop's
    /// tick may have landed while the Mac slept, or at a launch before the network was up.
    private static let staleAfter: TimeInterval = 60 * 60

    /// The network comes back a beat after the Mac does; asking at the wake notification itself
    /// fails and leaves the next try to the loop.
    private static let wakeGrace: Duration = .seconds(20)

    /// How long ``checkedUpToDate`` stays true after a manual check that found nothing newer.
    private static let upToDateNotice: Duration = .seconds(3)

    /// How often ``refresh()`` copies Tiptoe's in-memory state into the observable properties,
    /// so the menu bar badge appears without the popover being opened. No network involved.
    private static let mirrorInterval: Duration = .seconds(60)

    /// Where the update-failed affordance sends the user.
    static let releasesPageURL = URL(string: "https://github.com/\(owner)/\(repo)/releases/latest")!

    /// Progress of a user-initiated install, for the version chip. A successful install replaces
    /// the process, so the only terminal state this side of the swap is `.failed`.
    enum ManualPhase: Equatable {
        case idle
        case working
        case failed(String)
    }

    private(set) var manualPhase: ManualPhase = .idle

    /// The newest installable release newer than the running app, whether downloaded or not.
    private(set) var availableVersion: String?

    /// The version the automatic path has downloaded and is holding for a quiet moment, if any.
    /// A stronger claim than ``availableVersion``; refreshed by ``refresh()``.
    private(set) var pendingVersion: String?

    /// The version a silent (or manual) install brought us to, until the user has seen the
    /// notice. Read from Tiptoe's store at launch; cleared by ``acknowledgeUpdate()``.
    private(set) var justUpdatedVersion: String?

    /// True while a check the user asked for is in flight, for the version chip.
    private(set) var isChecking = false

    /// True for ``upToDateNotice`` after a check the user asked for found nothing newer. "Nothing
    /// newer" and "couldn't reach GitHub" look the same from here, so this can be a beat
    /// optimistic offline; the loop and the next popover open self-correct.
    private(set) var checkedUpToDate = false

    /// The updater: check loop, plus the quiet-moment install when auto-update is on.
    /// Created up front so its `Tiptoe` reconciles the recorded wait and the post-update notice
    /// against the running bundle (a notice that outlived its version is dropped) before the
    /// loop starts. Notify-only until ``start(autoInstall:)``
    /// applies the user's setting — which never happens in DEBUG, so a development build's
    /// manual check stays a metadata request and cannot download a DMG on the side.
    @ObservationIgnored private let tiptoe: Tiptoe
    @ObservationIgnored private let updater: AppUpdater
    @ObservationIgnored private let activity: UpdateActivity
    @ObservationIgnored private var checkLoop: Task<Void, Never>?
    @ObservationIgnored private var mirrorTask: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?

    /// When the shared check last finished.
    @ObservationIgnored private var lastCheckedAt: Date?
    @ObservationIgnored private var consecutiveCheckFailures = 0

    private init() {
        updater = AppUpdater(owner: Self.owner, repo: Self.repo)
        tiptoe = Tiptoe()
        activity = UpdateActivity(tiptoe: tiptoe, videoWork: .shared)
        justUpdatedVersion = tiptoe.justUpdatedTo
    }

    // MARK: - Automatic installs

    /// Called once at launch with the user's setting.
    func start(autoInstall: Bool) {
        // Never in DEBUG: a development build must not poll GitHub, and must never be swapped
        // out from under Xcode.
        #if !DEBUG
            guard checkLoop == nil else { return }
            activity.autoInstall = autoInstall
            checkLoop = Task(name: "Check for updates periodically") { [weak self] in
                while !Task.isCancelled {
                    await self?.check()
                    try? await Task.sleep(for: .seconds(Self.checkInterval))
                }
            }
            mirrorTask = Task(name: "Mirror update state") { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.mirrorInterval)
                    self?.refresh()
                }
            }
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main,
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.checkAfterWake()
                }
            }
        #endif
    }

    /// Reacts to the Auto-Update toggle. Turning it off keeps the check loop but stops the
    /// quiet-moment watcher; a DMG already downloaded stays downloaded but installs only
    /// via ``updateNow(version:)``.
    func setAutoInstall(_ enabled: Bool) {
        #if !DEBUG
            activity.autoInstall = enabled
            refresh()
            if enabled {
                Task { await check() }
            }
        #endif
    }

    /// Copies Tiptoe's state into the observable properties. Called when the popover appears,
    /// every ``mirrorInterval``, and after update actions — Tiptoe has no change callback.
    func refresh() {
        pendingVersion = activity.pendingVersion
    }

    // MARK: - Checking

    /// The user pressed the chip's refresh: the same request the loop makes, off-schedule, with
    /// the chip saying what it is doing and, briefly, what it found.
    func checkForUpdates() async {
        guard !isChecking else { return }
        isChecking = true
        checkedUpToDate = false
        await check()
        isChecking = false
        guard availableVersion == nil, pendingVersion == nil else { return }
        checkedUpToDate = true
        Task(name: "Clear the up-to-date notice") { [weak self] in
            try? await Task.sleep(for: Self.upToDateNotice)
            self?.checkedUpToDate = false
        }
    }

    /// The check the popover's appearance and the Mac's waking make, when the last one is old
    /// enough to be worth repeating. Quiet: the chip shows its result, never its progress.
    func checkIfStale() {
        // A development build does not poll GitHub on its own; the chip's refresh is the one
        // request it makes, and only when asked.
        #if !DEBUG
            if let lastCheckedAt, Date.now.timeIntervalSince(lastCheckedAt) < Self.staleAfter {
                return
            }
            Task(name: "Check for updates (stale)") { await check() }
        #endif
    }

    private func checkAfterWake() {
        Task(name: "Check for updates after wake") { [weak self] in
            try? await Task.sleep(for: Self.wakeGrace)
            self?.checkIfStale()
        }
    }

    /// Every background check joins the same task, including its preparation.
    private func check() async {
        await activity.check {
            defer {
                self.lastCheckedAt = .now
                self.refresh()
            }
            do {
                if let candidate = try await self.checkCandidate(), self.activity.autoInstall {
                    try await self.activity.prepare(candidate)
                }
                self.consecutiveCheckFailures = 0
            } catch {
                guard !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
                Log.update.debug("update check failed: \(error.localizedDescription, privacy: .public)")
                self.consecutiveCheckFailures += 1
                if self.consecutiveCheckFailures == Int(86_400 / Self.checkInterval) {
                    Log.update.error("update checks have been failing: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func checkForRelease() async throws -> Update? {
        let update = try await updater.check()
        availableVersion = update?.version
        lastCheckedAt = .now
        return update
    }

    private func checkCandidate() async throws -> UpdateActivity.Candidate? {
        guard let update = try await checkForRelease() else { return nil }
        return UpdateActivity.Candidate(version: update.version) {
            let prepared = try await update.prepareInstallation()
            return UpdateActivity.Download(
                install: { try await prepared.installAndRelaunch() },
                discard: { await prepared.discard() },
            )
        }
    }

    // MARK: - Update Now

    /// Download (if needed), verify, and install the version shown to the user.
    /// On success the app relaunches and this never returns to its caller in a meaningful way;
    /// still running a few seconds later means the attempt failed and `manualPhase` says so.
    func updateNow(version: String) async {
        guard manualPhase != .working else { return }
        #if DEBUG
            manualPhase = .failed(String(localized: "In-app updates are disabled in development builds."))
        #else
            manualPhase = .working
            defer { refresh() }
            do {
                switch try await activity.install(version: version, findCandidate: checkCandidate) {
                case .alreadyInstalling:
                    manualPhase = .idle
                case .videoWorkInProgress:
                    manualPhase = .failed(String(localized: "Wait for the current video conversion or optimization to finish, then try again."))
                case .noMatchingDownload:
                    manualPhase = .failed(String(localized: "Couldn't find a download for this update. Get it from the releases page."))
                case .attempted:
                    if activity.isReplacingApp {
                        // Give AppUpdater's scheduled termination time to run.
                        try? await Task.sleep(for: .seconds(4))
                    }
                    manualPhase = .failed(String(localized: "The update couldn't be installed. Try again, or get it from the releases page."))
                }
            } catch {
                Log.update.error("could not prepare Phosphene \(version, privacy: .public): \(error.localizedDescription, privacy: .public)")
                manualPhase = .failed(String(localized: "Couldn't download the update. Check your connection, or get it from the releases page."))
            }
        #endif
    }

    /// The user has seen the failure notice (the version chip was clicked).
    func dismissFailure() {
        if case .failed = manualPhase {
            manualPhase = .idle
        }
    }

    /// The user has seen the post-update notice.
    func acknowledgeUpdate() {
        if tiptoe.justUpdatedTo == justUpdatedVersion {
            tiptoe.acknowledge()
        }
        justUpdatedVersion = nil
    }
}
