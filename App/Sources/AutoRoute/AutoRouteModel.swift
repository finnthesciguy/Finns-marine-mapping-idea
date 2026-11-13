import AppServices
import Foundation
import NavCore
import Observation
import Persistence

/// State of the auto-route planner screen. All routing, wording and safety rules are in AppServices
/// (`AutoRoutePlanner`, `AutoRoutePresenter`, `AutoRouteSafety`, `AutoRouteSaving`); this class holds the
/// user's choices, runs a plan as a cancellable task, and passes results to the map and the store.
@MainActor
@Observable
final class AutoRouteModel {
    /// One end as chosen in the planner.
    enum EndChoice: Equatable {
        case boat
        case waypoint(UUID)
        case chartPoint(Coordinate)
    }

    enum End: String {
        case start, goal
    }

    /// A save or follow waiting for the yellow-leg confirmation.
    struct PendingCaution: Identifiable, Equatable {
        let confirmation: AutoRouteCautionConfirmation
        let follow: Bool
        var id: String { confirmation.title + (follow ? "-follow" : "-save") }
    }

    var startChoice: EndChoice? = .boat
    var goalChoice: EndChoice?
    var selectedProfileID: UUID?
    /// This plan's options (overrides of the profile's flags, "inside route only").
    var options: AutoRouteOptions = AutoRouteOptions()
    /// The route name for saving (starts as the suggested name).
    var routeName: String = ""

    /// Nil until read from the store.
    private(set) var noticeNeeded: Bool?
    private(set) var isPlanning: Bool = false
    private(set) var progress: AutoRouteProgress?
    private(set) var outcome: AutoRoutePlanOutcome?
    /// "pilot-sarasota (side-loaded) · chart data 23 Oct 2026 · 216 KB", or why no pack fits.
    private(set) var packText: String = "Choose a start and a destination."
    private(set) var packID: String = "none"
    private(set) var catalog: RoutingPackCatalog = RoutingPackCatalog(entries: [], problems: [])
    /// Set while the user picks an end on the chart (the planner sheet is closed meanwhile).
    var picking: End?
    var pendingCaution: PendingCaution?
    private(set) var lastSavedName: String = "none"
    var message: String?

    let planner: AutoRoutePlanner
    let library: RoutingPackLibrary
    let noticeGate: AutoRouteNoticeGate
    let plotter: PlotterModel
    let profiles: BoatProfilesModel
    @ObservationIgnored var currentPosition: @MainActor () -> Coordinate? = { nil }
    /// Frames coordinates on the chart (`ChartMapModel.focus(on:)`).
    @ObservationIgnored var focusMap: @MainActor ([Coordinate]) -> Void = { _ in }
    @ObservationIgnored private var planTask: Task<Void, Never>?
    @ObservationIgnored private var planCounter: Int = 0

    init(planner: AutoRoutePlanner, store: PersistenceStore, plotter: PlotterModel, profiles: BoatProfilesModel) {
        self.planner = planner
        self.library = planner.library
        self.noticeGate = AutoRouteNoticeGate(store: store)
        self.plotter = plotter
        self.profiles = profiles
    }

    // MARK: Opening and the notice

    /// Called when the planner screen appears: notice state, installed packs, profiles.
    func open() async {
        noticeNeeded = await noticeGate.needsAcknowledgement()
        await profiles.reload()
        if profile == nil { selectedProfileID = profiles.defaultProfile?.id }
        await refreshPacks()
    }

    func acknowledgeNotice() async {
        do {
            try await noticeGate.acknowledge(now: Date())
        } catch {
            message = "The acknowledgement could not be saved: \(error)"
        }
        noticeNeeded = await noticeGate.needsAcknowledgement()
    }

    // MARK: Choices

    var profile: BoatProfile? {
        profiles.profile(selectedProfileID) ?? (selectedProfileID == nil ? profiles.defaultProfile : nil)
    }

    func selectProfile(_ id: UUID) {
        selectedProfileID = id
        // Option overrides belong to the profile they were made for.
        options.useMaintainedChannels = nil
        options.acceptUnknownClearance = nil
    }

    func choose(_ choice: EndChoice, for end: End) {
        switch end {
        case .start: startChoice = choice
        case .goal: goalChoice = choice
        }
        Task { await refreshPacks() }
    }

    /// Starts picking a point on the chart (the screen closes the sheet).
    func beginPicking(_ end: End) {
        picking = end
    }

    /// A tap on the chart while picking.
    func picked(_ coordinate: Coordinate) {
        guard let end = picking else { return }
        picking = nil
        choose(.chartPoint(coordinate), for: end)
    }

    func endpoint(_ choice: EndChoice?) -> AutoRouteEndpoint? {
        guard let choice else { return nil }
        switch choice {
        case .boat:
            guard let position = currentPosition() else { return nil }
            return AutoRouteEndpoint.boat(position)
        case .waypoint(let id):
            guard let waypoint = plotter.data.waypoint(id) else { return nil }
            return AutoRouteEndpoint.waypoint(waypoint)
        case .chartPoint(let c):
            return AutoRouteEndpoint.chartPoint(c)
        }
    }

    func label(_ choice: EndChoice?) -> String {
        guard let choice else { return "Choose" }
        switch choice {
        case .boat:
            return currentPosition() == nil ? "Boat position (no fix yet)" : "Boat position"
        case .waypoint(let id):
            return plotter.data.waypoint(id)?.name ?? "Deleted waypoint"
        case .chartPoint(let c):
            return "Chart point " + CoordinateFormat.ddm(c, fractionDigits: 2)
        }
    }

    /// Effective values of the two profile options for this plan.
    var useMaintainedChannels: Bool { options.useMaintainedChannels ?? profile?.useMaintainedChannels ?? false }
    var acceptUnknownClearance: Bool { options.acceptUnknownClearance ?? profile?.acceptUnknownClearance ?? false }

    var canPlan: Bool {
        noticeNeeded == false && !isPlanning && profile != nil && endpoint(startChoice) != nil && endpoint(goalChoice) != nil
    }

    /// Which pack the plan will use (shown before Plan).
    func refreshPacks() async {
        catalog = await library.catalog()
        guard let start = endpoint(startChoice), let goal = endpoint(goalChoice) else {
            packID = "none"
            if catalog.entries.isEmpty {
                packText = "No routing pack is installed."
            } else {
                packText = "Installed: " + catalog.entries.map(\.descriptionLine).joined(separator: "; ")
            }
            return
        }
        let selection: RoutingPackSelection = RoutingPackSelection.choose(from: catalog.entries, start: start.coordinate,
                                                                          goal: goal.coordinate)
        switch selection {
        case .pack(let entry):
            packID = entry.packRegionID
            packText = entry.descriptionLine
        case .noPacksInstalled:
            packID = "none"
            packText = "No routing pack is installed."
        case .notCovered:
            packID = "none"
            packText = "No installed routing pack covers both ends."
        case .differentPacks:
            packID = "none"
            packText = "Start and destination are in different routing packs."
        }
    }

    // MARK: Planning

    func plan() {
        guard let profile, let start = endpoint(startChoice), let goal = endpoint(goalChoice) else {
            message = "Choose a start, a destination and a boat first."
            return
        }
        planTask?.cancel()
        planCounter += 1
        let mine: Int = planCounter
        let request = AutoRoutePlanRequest(start: start, goal: goal, profile: profile, options: options)
        let units: UnitPreferences = plotter.data.settings.units
        let planner: AutoRoutePlanner = self.planner
        isPlanning = true
        progress = AutoRouteProgress(phase: .openingPack)
        outcome = nil
        message = nil
        plotter.setPlannedLayer(.empty)
        // The model is main-actor isolated (so Sendable); the planner calls `sink` from its routing thread.
        let sink: @Sendable (AutoRouteProgress) -> Void = { (p: AutoRouteProgress) -> Void in
            Task { @MainActor in self.receive(p, plan: mine) }
        }
        planTask = Task { @MainActor in
            let result: AutoRoutePlanOutcome = await planner.plan(request, units: units, now: Date(), progress: sink)
            guard self.planCounter == mine else { return }
            self.finish(result)
        }
    }

    private func receive(_ p: AutoRouteProgress, plan: Int) {
        guard planCounter == plan, isPlanning else { return }
        progress = p
    }

    private func finish(_ result: AutoRoutePlanOutcome) {
        isPlanning = false
        progress = nil
        outcome = result
        if let proposal = result.proposal {
            routeName = proposal.suggestedName
        }
        plotter.setPlannedLayer(PlannedRouteLayer(outcome: result))
        let frame: [Coordinate] = PlannedRouteLayer.focusCoordinates(result)
        if !frame.isEmpty { focusMap(frame) }
        if case .failed(let failure) = result, failure.kind == .noticeNotAcknowledged {
            noticeNeeded = true
        }
    }

    func cancel() {
        planTask?.cancel()
    }

    /// A hint action: re-plans with that option on, for this plan only (the profile is not changed).
    func apply(_ hint: AutoRouteHintAction) {
        options = hint.apply(to: options)
        plan()
    }

    func discard() {
        planTask?.cancel()
        planCounter += 1
        isPlanning = false
        progress = nil
        outcome = nil
        plotter.setPlannedLayer(.empty)
    }

    // MARK: Saving and following

    /// Save (and optionally follow). Routes with yellow legs ask for confirmation first (`pendingCaution`).
    func requestSave(follow: Bool) async {
        guard let proposal = outcome?.proposal else { return }
        switch AutoRouteSafety.decide(legs: proposal.storedLegs) {
        case .refused(let reason):
            message = reason
        case .needsConfirmation(let confirmation):
            pendingCaution = PendingCaution(confirmation: confirmation, follow: follow)
        case .allowed:
            await save(proposal, follow: follow, confirmed: false)
        }
    }

    /// The user confirmed the yellow legs.
    func confirmCaution() async {
        guard let pending = pendingCaution, let proposal = outcome?.proposal else { return }
        pendingCaution = nil
        await save(proposal, follow: pending.follow, confirmed: true)
    }

    private func save(_ proposal: AutoRouteProposal, follow: Bool, confirmed: Bool) async {
        // The safety rules again, on the stored legs, immediately before writing.
        let decision: AutoRouteSafety.Decision = AutoRouteSafety.decide(legs: proposal.storedLegs)
        if case .refused(let reason) = decision {
            message = reason
            return
        }
        if decision.confirmation != nil && !confirmed {
            message = "Confirm the yellow legs first."
            return
        }
        var name: String = routeName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = proposal.suggestedName }
        let route: Route
        do {
            route = try AutoRouteSaving.route(proposal, name: name, units: plotter.data.settings.units, now: Date())
        } catch {
            message = "The route could not be prepared: \(error)"
            return
        }
        guard let saved = await plotter.data.save(route) else { return }
        lastSavedName = saved.name
        outcome = nil
        plotter.setPlannedLayer(.empty)
        plotter.setRouteShown(saved.id, true)
        if follow {
            plotter.follow(saved)
        }
    }

    // MARK: Status for the UI tests

    /// `notice=… planState=… planLegs=… planGreen=… planYellow=… planBlocked=… planHints=… planPack=… planSaved=…`.
    var statusValue: String {
        var parts: [String] = []
        switch noticeNeeded {
        case .none: parts.append("notice=unknown")
        case .some(let needed): parts.append("notice=" + (needed ? "needed" : "ok"))
        }
        let state: String
        if isPlanning {
            state = "planning"
        } else if let outcome {
            state = outcome.statusCode
        } else {
            state = "idle"
        }
        parts.append("planState=\(state)")
        let proposal: AutoRouteProposal? = outcome?.proposal
        parts.append("planLegs=\(proposal?.legs.count ?? 0)")
        parts.append("planGreen=\(proposal?.greenLegs ?? 0)")
        parts.append("planYellow=\(proposal?.yellowLegs ?? 0)")
        let noRoute: AutoRouteNoRoute? = outcome?.noRoute
        parts.append("planBlocked=\(noRoute?.blocked.count ?? 0)")
        let hints: [String] = noRoute?.hints.map(\.kind.rawValue) ?? []
        parts.append("planHints=" + (hints.isEmpty ? "none" : hints.joined(separator: ",")))
        parts.append("planPack=\(packID)")
        parts.append("routingPacks=\(catalog.entries.count)")
        parts.append("planSaved=\(lastSavedName)")
        parts.append("picking=\(picking?.rawValue ?? "none")")
        return parts.joined(separator: "; ")
    }
}
