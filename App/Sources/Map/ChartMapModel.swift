import AppServices
import ChartKit
import Foundation
import NavCore
import Observation

/// What the chart map draws: one raster layer per installed region (ChartKit's `MapLibreSources.layerPlan`),
/// plus the camera options the user controls.
@MainActor
@Observable
final class ChartMapModel {
    private(set) var plan: [ChartLayerPlan] = []
    /// Bumped whenever `plan` changes; the map view rebuilds its layers when it sees a new revision.
    private(set) var planRevision: Int = 0
    private(set) var badge: ChartAgeBadge?
    private(set) var hasCharts: Bool = false
    var follow: Bool = true
    var orientation: MapOrientationMode = .northUp
    /// A camera position to move to once (framing a planned route); applied when `focusRevision` changes.
    private(set) var focus: MapFocus?
    private(set) var focusRevision: Int = 0

    /// Last revision the map view reported as applied (not observed: it is written from map callbacks).
    @ObservationIgnored private var appliedRevision: Int = -1
    @ObservationIgnored private var installed: [InstalledRegion] = []
    @ObservationIgnored private var hidden: Set<String> = []
    private let library: ChartLibrary

    init(library: ChartLibrary) {
        self.library = library
    }

    func update(installed regions: [InstalledRegion]) {
        installed = regions
        hidden = []
        rebuild()
    }

    /// Takes a region off the map and waits (up to two seconds) until the map has applied that, so its
    /// file can be deleted without MapLibre reading it afterwards.
    func hideRegionAndWait(_ regionID: String) async {
        hidden.insert(regionID)
        rebuild()
        let target: Int = planRevision
        var waited = 0
        while appliedRevision < target && waited < 40 {
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return
            }
            waited += 1
        }
    }

    /// Called by the map view once a revision's layers are in the style. Releases package files that an
    /// update replaced, now that the map no longer reads them.
    func planApplied(revision: Int) {
        appliedRevision = max(appliedRevision, revision)
        guard revision == planRevision else { return }
        let applied: [ChartLayerPlan] = plan
        let library: ChartLibrary = self.library
        Task {
            _ = await library.releaseSupersededFiles(notReferencedBy: applied)
        }
    }

    /// Frames `coordinates` on the chart (follow mode off so the camera stays there).
    func focus(on coordinates: [Coordinate]) {
        guard let next = MapFocus.framing(coordinates) else { return }
        follow = false
        focus = next
        focusRevision += 1
    }

    func toggleOrientation() {
        orientation = orientation.toggled
    }

    private func rebuild() {
        var visible: [InstalledRegion] = []
        for region in installed where !hidden.contains(region.id) {
            visible.append(region)
        }
        let installer: ChartInstaller = library.installer
        let next: [ChartLayerPlan] = MapLibreSources.layerPlan(for: visible, resolveURL: { region in
            installer.fileURL(for: region.chart)
        })
        badge = ChartAgeBadge.make(installed: installed, now: Date())
        hasCharts = !visible.isEmpty
        if next != plan {
            plan = next
            planRevision += 1
        }
    }
}
