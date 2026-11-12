import AppServices
import ChartKit
import Foundation
import Observation

/// State and actions of the Charts screen. Row contents and button logic come from
/// `RegionCatalog`/`RegionRow` (AppServices, tested on Linux); this class only wires them to the installer.
@MainActor
@Observable
final class ChartsModel {
    struct PendingDownload: Identifiable, Equatable {
        let id: String
        let confirmation: DownloadConfirmation
    }

    private(set) var rows: [RegionRow] = []
    private(set) var freeBytes: Int64?
    private(set) var installedRegions: [InstalledRegion] = []
    let manifestError: String?

    /// Set to ask the user to confirm a download (shows the size first).
    var pendingDownload: PendingDownload?
    /// Set to ask the user to confirm deleting a region.
    var pendingDeletion: RegionRow?

    /// Called when the set of installed files changes (the map rebuilds its layers).
    @ObservationIgnored var onInstalledChange: (@MainActor ([InstalledRegion]) -> Void)?
    /// Awaited before a region is deleted so the map stops reading its file first.
    @ObservationIgnored var prepareForRemoval: (@MainActor (String) async -> Void)?

    private let library: ChartLibrary
    private let regions: [ChartRegion]
    @ObservationIgnored private var installs: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var preparing: Set<String> = []
    @ObservationIgnored private var messages: [String: String] = [:]
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var lastProgressRefresh: [String: Date] = [:]
    @ObservationIgnored private var started = false

    init(library: ChartLibrary, regions: [ChartRegion], manifestError: String?) {
        self.library = library
        self.regions = regions
        self.manifestError = manifestError
    }

    func start() async {
        guard !started else { return }
        started = true
        await library.start()
        let updates: AsyncStream<RegionStateUpdate> = library.stateUpdates()
        updatesTask = Task { [weak self] in
            for await update in updates {
                guard let self else { return }
                await self.handle(update)
            }
        }
        await refresh()
    }

    // MARK: Actions

    func primaryAction(for row: RegionRow) {
        switch row.primaryAction {
        case .download, .resume, .update:
            askToDownload(row)
        case .cancel:
            cancel(regionID: row.id)
        case .none:
            break
        }
    }

    func askToDownload(_ row: RegionRow) {
        let confirmation = DownloadConfirmation.make(regionTitle: row.title, downloadBytes: row.downloadBytes,
                                                     alreadyDownloaded: row.partialBytes,
                                                     freeBytes: library.freeBytes())
        pendingDownload = PendingDownload(id: row.id, confirmation: confirmation)
    }

    func confirmPendingDownload() {
        guard let pending = pendingDownload else { return }
        pendingDownload = nil
        guard pending.confirmation.canProceed else { return }
        startInstall(regionID: pending.id)
    }

    func cancel(regionID: String) {
        installs[regionID]?.cancel()
    }

    func askToDelete(_ row: RegionRow) {
        pendingDeletion = row
    }

    func confirmPendingDeletion() {
        guard let row = pendingDeletion else { return }
        pendingDeletion = nil
        let regionID: String = row.id
        Task { [weak self] in
            guard let self else { return }
            if let prepare = self.prepareForRemoval {
                await prepare(regionID)
            }
            do {
                try await self.library.remove(regionID: regionID)
                self.messages[regionID] = nil
            } catch let failure as InstallFailure {
                self.messages[regionID] = RegionRow.describe(failure)
            } catch {
                self.messages[regionID] = String(describing: error)
            }
            await self.refresh()
        }
    }

    // MARK: Internals

    private func startInstall(regionID: String) {
        guard installs[regionID] == nil else { return }
        guard let region = regions.first(where: { $0.id == regionID }) else { return }
        messages[regionID] = nil
        preparing.insert(regionID)
        let library: ChartLibrary = self.library
        installs[regionID] = Task { [weak self] in
            var failureText: String? = nil
            do {
                _ = try await library.install(region)
            } catch let failure as InstallFailure {
                if failure != .cancelled {
                    failureText = RegionRow.describe(failure)
                }
            } catch {
                failureText = String(describing: error)
            }
            guard let self else { return }
            self.installs[regionID] = nil
            self.preparing.remove(regionID)
            // Failures inside the installer already show in the row's state; keep a message only for
            // failures before it took over (the NOAA HEAD).
            let state: InstallState = await library.installer.state(for: regionID)
            if case .failed = state {
                self.messages[regionID] = nil
            } else {
                self.messages[regionID] = failureText
            }
            await self.refresh()
        }
        Task { [weak self] in
            await self?.refresh()
        }
    }

    private func handle(_ update: RegionStateUpdate) async {
        if update.state.isBusy {
            preparing.remove(update.regionID)
        }
        if case .downloading = update.state {
            // Progress arrives for every chunk; update just that row, a few times a second.
            let now = Date()
            if let last = lastProgressRefresh[update.regionID], now.timeIntervalSince(last) < 0.25 {
                return
            }
            lastProgressRefresh[update.regionID] = now
            if let index = rows.firstIndex(where: { $0.id == update.regionID }) {
                rows[index].state = update.state
                rows[index].isPreparing = false
                return
            }
        }
        await refresh()
    }

    func refresh() async {
        let installer: ChartInstaller = library.installer
        let installed: [InstalledRegion] = await installer.installedRegions()
        let states: [String: InstallState] = await installer.allStates()
        let pending: [ResumeRecord] = await installer.pendingDownloads()
        freeBytes = library.freeBytes()
        rows = RegionCatalog.rows(regions: regions, installed: installed, states: states, pending: pending,
                                  preparing: preparing, messages: messages, now: Date())
        if installed != installedRegions {
            installedRegions = installed
            onInstalledChange?(installed)
        }
    }
}
