import AppServices
import Persistence
import SwiftUI

/// Boat profiles: list (default first), add, edit, delete, make default. Pushed from Settings and from the
/// auto-route planner (both have a NavigationStack).
struct BoatProfilesScreen: View {
    let profiles: BoatProfilesModel
    let units: UnitPreferences
    /// Set when the planner pushed this screen: picking a row also selects it for the plan.
    var onChoose: ((BoatProfile) -> Void)? = nil

    @State private var editing: ProfileEditTarget?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Button {
                    editing = ProfileEditTarget(profile: nil)
                } label: {
                    Label("Add a boat", systemImage: "plus")
                }
                .accessibilityIdentifier("profiles.add")
            } footer: {
                Text("The router uses the draft plus safety margin as the depth the boat needs, rounded up to whole feet, and the air draft for bridges and cables.")
            }
            Section("Boats") {
                if profiles.profiles.isEmpty {
                    Text("No boat profiles yet.")
                        .foregroundStyle(Color.secondary)
                }
                ForEach(profiles.profiles, id: \.id) { profile in
                    let row = BoatProfileRow(profile: profile, units: units)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(row.name)
                                    .font(.headline)
                                    .accessibilityIdentifier("profile.name.\(row.name)")
                                if row.isDefault {
                                    Text("Default")
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                                        .accessibilityIdentifier("profile.default.\(row.name)")
                                }
                            }
                            Text(row.detail)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Color.secondary)
                                .accessibilityIdentifier("profile.detail.\(row.name)")
                            if !row.options.isEmpty {
                                Text(row.options.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(Color.orange)
                            }
                        }
                        Spacer()
                        if let onChoose {
                            Button("Use") {
                                onChoose(profile)
                                dismiss()
                            }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("profile.use.\(row.name)")
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        editing = ProfileEditTarget(profile: profile)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("profile.row.\(row.name)")
                }
            }
        }
        .navigationTitle("Boat profiles")
        .task {
            await profiles.reload()
        }
        .sheet(item: $editing) { target in
            BoatProfileEditor(original: target.profile, profiles: profiles, units: units,
                              isFirst: profiles.profiles.isEmpty, onClose: { editing = nil })
        }
    }
}

struct ProfileEditTarget: Identifiable {
    let profile: BoatProfile?
    var id: String { profile?.id.uuidString ?? "new" }
}

/// Add or edit one boat profile.
struct BoatProfileEditor: View {
    let original: BoatProfile?
    let profiles: BoatProfilesModel
    let units: UnitPreferences
    let isFirst: Bool
    let onClose: () -> Void

    @State private var form: BoatProfileForm = BoatProfileForm(profile: nil, units: UnitPreferences())
    @State private var loaded: Bool = false
    @State private var problems: [BoatProfileProblem] = []
    @State private var confirmingDelete: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Boat") {
                    TextField("Name", text: $form.name)
                        .accessibilityIdentifier("profile.edit.name")
                }
                Section {
                    numberRow("Draft", text: $form.draft, unit: form.lengthUnitSymbol, id: "profile.edit.draft")
                    numberRow("Safety margin", text: $form.safetyMargin, unit: form.lengthUnitSymbol, id: "profile.edit.margin")
                    numberRow("Air draft", text: $form.airDraft, unit: form.lengthUnitSymbol, id: "profile.edit.airDraft")
                    numberRow("Beam (optional)", text: $form.beam, unit: form.lengthUnitSymbol, id: "profile.edit.beam")
                    numberRow("Cruising speed (optional)", text: $form.cruisingSpeed, unit: form.speedUnitSymbol, id: "profile.edit.speed")
                } header: {
                    Text("Dimensions")
                } footer: {
                    Text("Air draft is the height of the highest point above the waterline, including antennas. Depths are compared with charted depths at chart datum, with no tide added.")
                }
                Section {
                    Toggle("Use maintained channels", isOn: $form.useMaintainedChannels)
                        .accessibilityIdentifier("profile.edit.maintained")
                    Toggle("Accept unknown clearance", isOn: $form.acceptUnknownClearance)
                        .accessibilityIdentifier("profile.edit.unknownClearance")
                } header: {
                    Text("Routing options")
                } footer: {
                    Text("Both are off by default. Legs that rely on them are always yellow and say why.")
                }
                if !problems.isEmpty {
                    Section {
                        ForEach(Array(problems.enumerated()), id: \.offset) { item in
                            Text(item.element.message)
                                .foregroundStyle(Color.red)
                                .accessibilityIdentifier("profile.edit.problem.\(item.offset)")
                        }
                    }
                }
                if let original {
                    Section {
                        if !original.isDefault {
                            Button {
                                Task {
                                    await profiles.setDefault(original.id)
                                    onClose()
                                }
                            } label: {
                                Label("Make this the default boat", systemImage: "star")
                            }
                            .accessibilityIdentifier("profile.makeDefault")
                        }
                        Button(role: .destructive) {
                            confirmingDelete = true
                        } label: {
                            Label("Delete boat", systemImage: "trash")
                        }
                        .accessibilityIdentifier("profile.delete")
                    }
                }
            }
            .navigationTitle(original == nil ? "New boat" : original?.name ?? "Boat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onClose)
                        .accessibilityIdentifier("profile.edit.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            let found: [BoatProfileProblem] = await profiles.save(form, editing: original)
                            problems = found
                            if found.isEmpty { onClose() }
                        }
                    }
                    .accessibilityIdentifier("profile.edit.save")
                }
            }
            .confirmationDialog("Delete \(original?.name ?? "boat")?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    Task {
                        if let id = original?.id { await profiles.delete(id) }
                        onClose()
                    }
                }
                .accessibilityIdentifier("profile.confirmDelete")
                Button("Cancel", role: .cancel) {}
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                form = BoatProfileForm(profile: original, units: units, makeDefault: original == nil && isFirst)
            }
        }
    }

    private func numberRow(_ title: String, text: Binding<String>, unit: String, id: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 90)
                .accessibilityIdentifier(id)
            Text(unit)
                .foregroundStyle(Color.secondary)
        }
    }
}
