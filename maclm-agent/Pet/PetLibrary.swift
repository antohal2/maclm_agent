import Foundation
import Observation

@MainActor @Observable
final class PetLibrary {
    private let settings: AppSettings
    let store: PetStore
    private(set) var entries: [PetEntry] = []
    var errorMessage: String?
    @ObservationIgnored var onReload: ((PetSprite?) -> Void)?

    init(settings: AppSettings, store: PetStore) {
        self.settings = settings
        self.store = store
        refresh(reload: false)
    }

    func activeSprite() -> PetSprite? {
        guard settings.petSelectedID != "bronya" else { return nil }
        do { return try store.load(settings.petSelectedID) } catch {
            NSLog("Active pet rejected; restoring builtin: %@", String(reflecting: error))
            settings.petSelectedID = "bronya"
            return nil
        }
    }

    func select(_ id: String) {
        if id == "bronya" {
            settings.petSelectedID = id
            onReload?(nil)
            return
        }
        do {
            let sprite = try store.load(id)
            settings.petSelectedID = id
            onReload?(sprite)
        } catch { errorMessage = PetStorageError.message(error) }
    }

    func refresh(reload: Bool = true) {
        do { entries = try store.entries() } catch {
            entries = []
            errorMessage = PetStorageError.message(error)
        }
        if reload {
            let sprite = activeSprite()
            onReload?(sprite)
        }
    }

    func install(_ imported: PetImport, replacing: Bool) {
        do {
            try store.install(imported, replacing: replacing)
            refresh(reload: false)
            select(imported.sprite.manifest.id)
        } catch { errorMessage = PetStorageError.message(error) }
    }

    func delete(_ id: String) {
        do {
            try store.delete(id)
            if settings.petSelectedID.caseInsensitiveCompare(id) == .orderedSame {
                select("bronya")
            }
            refresh(reload: false)
        } catch { errorMessage = PetStorageError.message(error) }
    }
}
