import AppServices
import NavCore
import Persistence
import SwiftUI

/// The auto-route planner: the notice (until acknowledged), start / destination / boat, the routing pack that
/// will be used, Plan with progress and Cancel, then the result (summary, legs with reasons, Save, Save and
/// follow, Discard) or the explanation of why there is no route (blocked places, hint actions).
struct AutoRouteScreen: View {
    let model: AutoRouteModel
    let units: UnitPreferences
    /// Closes the sheet (the planned route stays on the chart).
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                switch model.noticeNeeded {
                case .none:
                    ProgressView("Loading…")
                case .some(true):
                    AutoRouteNoticeView(onAccept: { Task { await model.acknowledgeNotice() } })
                case .some(false):
                    planner
                }
            }
            .navigationTitle("Auto-route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose)
                        .accessibilityIdentifier("autoroute.done")
                }
            }
        }
        .task {
            await model.open()
        }
        .alert(model.pendingCaution?.confirmation.title ?? "Caution", isPresented: cautionShown,
               presenting: model.pendingCaution) { pending in
            Button(pending.confirmation.confirmLabel) {
                let follow: Bool = pending.follow
                Task {
                    await model.confirmCaution()
                    if follow { onClose() }
                }
            }
            .accessibilityIdentifier("autoroute.confirmCaution")
            Button("Cancel", role: .cancel) { model.pendingCaution = nil }
        } message: { pending in
            Text(pending.confirmation.fullText)
        }
    }

    private var cautionShown: Binding<Bool> {
        Binding(get: { model.pendingCaution != nil },
                set: { shown in
                    if !shown { model.pendingCaution = nil }
                })
    }

    private var planner: some View {
        List {
            Section {
                NavigationLink {
                    EndpointChoiceList(model: model, end: .start, onPickOnChart: onClose)
                } label: {
                    LabeledContent("Start", value: model.label(model.startChoice))
                }
                .accessibilityIdentifier("autoroute.start")
                NavigationLink {
                    EndpointChoiceList(model: model, end: .goal, onPickOnChart: onClose)
                } label: {
                    LabeledContent("Destination", value: model.label(model.goalChoice))
                }
                .accessibilityIdentifier("autoroute.goal")
                // One stable link (its destination must not disappear when the first profile is added).
                NavigationLink {
                    BoatProfilesScreen(profiles: model.profiles, units: units, onChoose: { chosen in
                        model.selectProfile(chosen.id)
                    })
                } label: {
                    LabeledContent("Boat", value: model.profile?.name ?? "Add a boat profile")
                }
                .accessibilityIdentifier("autoroute.profile")
                Text(model.packText)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .accessibilityIdentifier("autoroute.pack")
            } header: {
                Text("Route")
            } footer: {
                Text("A suggestion from charted data. Review every leg; depths are at chart datum with no tide allowance.")
            }

            Section {
                if model.isPlanning {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(model.progress?.text ?? "Planning…")
                            .accessibilityIdentifier("autoroute.progress")
                    }
                    Button("Cancel", role: .cancel) { model.cancel() }
                        .accessibilityIdentifier("autoroute.cancel")
                } else {
                    Button {
                        model.plan()
                    } label: {
                        Label(model.outcome == nil ? "Plan" : "Plan again", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    }
                    .disabled(!model.canPlan)
                    .accessibilityIdentifier("autoroute.plan")
                }
                if let message = model.message {
                    Text(message)
                        .foregroundStyle(Color.red)
                        .accessibilityIdentifier("autoroute.message")
                }
                if model.lastSavedName != "none" && model.outcome == nil && !model.isPlanning {
                    Text("Saved as “\(model.lastSavedName)” in Routes.")
                        .font(.footnote)
                        .accessibilityIdentifier("autoroute.savedMessage")
                }
            }

            switch model.outcome {
            case .none:
                EmptyView()
            case .some(.proposal(let proposal)):
                ProposalSections(model: model, proposal: proposal, onClose: onClose)
            case .some(.noRoute(let noRoute)):
                NoRouteSections(model: model, noRoute: noRoute)
            case .some(.snapFailed(let problem)):
                Section {
                    Text(problem.title)
                        .font(.headline)
                        .accessibilityIdentifier("autoroute.failure.title")
                    Text(problem.message)
                        .accessibilityIdentifier("autoroute.failure.message")
                }
            case .some(.failed(let failure)):
                Section {
                    Text(failure.title)
                        .font(.headline)
                        .accessibilityIdentifier("autoroute.failure.title")
                    Text(failure.message)
                        .accessibilityIdentifier("autoroute.failure.message")
                    ForEach(Array(failure.details.enumerated()), id: \.offset) { item in
                        Text(item.element)
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                }
            }

            Section {
                Toggle("Use maintained channels", isOn: Binding(get: { model.useMaintainedChannels },
                                                                set: { model.options.useMaintainedChannels = $0 }))
                    .accessibilityIdentifier("autoroute.option.maintained")
                Toggle("Accept unknown clearance", isOn: Binding(get: { model.acceptUnknownClearance },
                                                                 set: { model.options.acceptUnknownClearance = $0 }))
                    .accessibilityIdentifier("autoroute.option.unknownClearance")
                Toggle("Inside route only", isOn: Binding(get: { model.options.avoidOpenGulf },
                                                          set: { model.options.avoidOpenGulf = $0 }))
                    .accessibilityIdentifier("autoroute.option.inside")
            } header: {
                Text("Options for this plan")
            } footer: {
                Text("Changes apply to the next plan only; the boat profile keeps its own settings. Legs relying on maintained channels or unknown clearances are yellow.")
            }
        }
    }
}

/// The notice that must be acknowledged before the first plan (and again when its text changes).
struct AutoRouteNoticeView: View {
    let onAccept: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(AutoRouteNotice.title)
                    .font(.title2.weight(.bold))
                    .accessibilityIdentifier("autoroute.notice.title")
                ForEach(Array(AutoRouteNotice.points.enumerated()), id: \.offset) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(Color.orange)
                            .accessibilityHidden(true)
                        Text(item.element)
                    }
                }
                Button(action: onAccept) {
                    Text(AutoRouteNotice.acceptLabel)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("autoroute.notice.accept")
            }
            .padding()
        }
    }
}

/// Choosing the start or destination: the boat (start only), a point picked on the chart, or a waypoint.
struct EndpointChoiceList: View {
    let model: AutoRouteModel
    let end: AutoRouteModel.End
    let onPickOnChart: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                if end == .start {
                    Button("Boat position") {
                        model.choose(.boat, for: end)
                        dismiss()
                    }
                    .accessibilityIdentifier("autoroute.choice.boat")
                }
                Button("Pick a point on the chart") {
                    model.beginPicking(end)
                    onPickOnChart()
                }
                .accessibilityIdentifier("autoroute.choice.chart")
            }
            Section("Waypoints") {
                if model.plotter.data.waypoints.isEmpty {
                    Text("No waypoints.")
                        .foregroundStyle(Color.secondary)
                }
                ForEach(model.plotter.data.waypoints, id: \.id) { waypoint in
                    Button(waypoint.name) {
                        model.choose(.waypoint(waypoint.id), for: end)
                        dismiss()
                    }
                    .accessibilityIdentifier("autoroute.choice.wp.\(waypoint.name)")
                }
            }
        }
        .navigationTitle(end == .start ? "Start" : "Destination")
    }
}

/// A computed route: actions first, then the summary card and the legs.
struct ProposalSections: View {
    let model: AutoRouteModel
    let proposal: AutoRouteProposal
    let onClose: () -> Void

    var body: some View {
        Section {
            switch proposal.safety {
            case .refused(let reason):
                Text(reason)
                    .foregroundStyle(Color.red)
                    .accessibilityIdentifier("autoroute.refused")
            case .needsConfirmation(let c):
                Text("\(c.title): you will be asked to confirm the reasons before saving or following.")
                    .font(.footnote)
                    .foregroundStyle(Color.orange)
                    .accessibilityIdentifier("autoroute.cautionNote")
                actions
            case .allowed:
                actions
            }
            Button(role: .destructive) {
                model.discard()
            } label: {
                Label("Discard", systemImage: "xmark.circle")
            }
            .accessibilityIdentifier("autoroute.discard")
        } header: {
            Text("Suggested route: \(proposal.greenLegs) green, \(proposal.yellowLegs) yellow")
        }
        Section("Summary") {
            ForEach(proposal.summary) { line in
                HStack(alignment: .firstTextBaseline) {
                    Text(line.label)
                        .font(.subheadline)
                    Spacer(minLength: 12)
                    Text(line.value)
                        .font(.subheadline)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(line.isWarning ? Color.orange : Color.primary)
                        .accessibilityIdentifier("autoroute.summary.\(line.id)")
                }
            }
        }
        Section("Legs") {
            ForEach(proposal.legs) { leg in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(LegGradeStyle.color(leg.grade.rawValue))
                            .frame(width: 10, height: 10)
                            .accessibilityHidden(true)
                        Text("\(leg.title) · \(leg.grade.rawValue)")
                            .font(.subheadline.weight(.semibold))
                    }
                    Text(leg.detail)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.secondary)
                    ForEach(Array(leg.reasons.enumerated()), id: \.offset) { item in
                        Text("\(item.element.title): \(item.element.detail)")
                            .font(.caption)
                            .foregroundStyle(Color.orange)
                    }
                    ForEach(Array(leg.overheads.enumerated()), id: \.offset) { item in
                        Text(item.element)
                            .font(.caption)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("autoroute.leg.\(leg.index)")
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        TextField("Route name", text: Binding(get: { model.routeName }, set: { model.routeName = $0 }))
            .accessibilityIdentifier("autoroute.name")
        Button {
            Task { await model.requestSave(follow: false) }
        } label: {
            Label("Save", systemImage: "square.and.arrow.down")
        }
        .accessibilityIdentifier("autoroute.save")
        Button {
            Task {
                await model.requestSave(follow: true)
                if model.pendingCaution == nil && model.outcome == nil { onClose() }
            }
        } label: {
            Label("Save and follow", systemImage: "location.north.line")
        }
        .accessibilityIdentifier("autoroute.saveFollow")
        Button {
            onClose()
        } label: {
            Label("Show on the chart", systemImage: "map")
        }
        .accessibilityIdentifier("autoroute.showOnChart")
    }
}

/// No route: the explanation, the option changes that would help (as buttons), the blocked places.
struct NoRouteSections: View {
    let model: AutoRouteModel
    let noRoute: AutoRouteNoRoute

    var body: some View {
        Section {
            Text(noRoute.title)
                .font(.headline)
                .accessibilityIdentifier("autoroute.noRoute.title")
            Text(noRoute.message)
                .accessibilityIdentifier("autoroute.noRoute.message")
            ForEach(noRoute.hints) { hint in
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        model.apply(hint)
                    } label: {
                        Label("\(hint.title) and plan again", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .accessibilityIdentifier("autoroute.hint.\(hint.kind.rawValue)")
                    Text(hint.explanation)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
            }
            if let noHint = noRoute.noHintText {
                Text(noHint)
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                    .accessibilityIdentifier("autoroute.noHint")
            }
        }
        if !noRoute.blocked.isEmpty {
            Section("Blocked (marked red on the chart)") {
                ForEach(Array(noRoute.blocked.enumerated()), id: \.offset) { item in
                    Text(item.element.description)
                        .font(.caption)
                        .accessibilityIdentifier("autoroute.blocked.\(item.offset)")
                }
            }
        }
    }
}
