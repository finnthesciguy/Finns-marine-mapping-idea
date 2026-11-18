import AppServices
import Foundation
import Observation
import Persistence

/// Boat profiles from the Persistence store (kept current through its change feed): list, add, edit, delete,
/// set default. Parsing and checks are `AppServices.BoatProfileForm`; the store keeps exactly one default.
@MainActor
@Observable
final class BoatProfilesModel {
    /// Default first, then by name (the store's order).
    private(set) var profiles: [BoatProfile] = []
    var errorText: String?

    let store: PersistenceStore
    @ObservationIgnored private var feedTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var reloadCounter: Int = 0

    init(store: PersistenceStore) {
        self.store = store
    }

    func start() async {
        guard !started else { return }
        started = true
        let changes: AsyncStream<StoreChange> = store.changes([.boatProfile])
        feedTask = Task { [weak self] in
            for await _ in changes {
                guard let self else { return }
                await self.reload()
            }
        }
        await reload()
    }

    func reload() async {
        reloadCounter += 1
        let mine: Int = reloadCounter
        do {
            let loaded: [BoatProfile] = try await store.boatProfiles()
            // A reload that started earlier and finishes later must not overwrite a newer list.
            if mine == reloadCounter { profiles = loaded }
        } catch {
            errorText = "Boat profiles could not be read: \(error)"
        }
    }

    var defaultProfile: BoatProfile? { profiles.first { $0.isDefault } ?? profiles.first }

    func profile(_ id: UUID?) -> BoatProfile? {
        guard let id else { return nil }
        return profiles.first { $0.id == id }
    }

    /// Saves the form (new when `editing` is nil). Returns the problems; empty on success.
    @discardableResult
    func save(_ form: BoatProfileForm, editing: BoatProfile?) async -> [BoatProfileProblem] {
        switch form.profile(updating: editing) {
        case .failure(let failed):
            return failed.problems
        case .success(let profile):
            do {
                _ = try await store.save(profile)
                await reload()
                return []
            } catch {
                errorText = "The boat profile could not be saved: \(error)"
                return [BoatProfileProblem(field: .name, message: "The boat profile could not be saved: \(error)")]
            }
        }
    }

    func setDefault(_ id: UUID) async {
        do {
            try await store.setDefaultBoatProfile(id)
        } catch {
            errorText = "The default boat could not be changed: \(error)"
        }
        await reload()
    }

    func delete(_ id: UUID) async {
        do {
            _ = try await store.deleteBoatProfile(id)
        } catch {
            errorText = "The boat profile could not be deleted: \(error)"
        }
        await reload()
    }

    /// `profiles=2; defaultProfile=Alpha` for `app.status`.
    var statusValue: String {
        "profiles=\(profiles.count); defaultProfile=\(profiles.first(where: { $0.isDefault })?.name ?? "none")"
    }
}
