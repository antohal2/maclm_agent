import Foundation
import Observation

@MainActor @Observable
final class PetLibrary {
    private let settings: AppSettings
    let store: PetStore
    private(set) var entries: [PetEntry] = []
    var errorMessage: String?
    @ObservationIgnored var onReload: ((PetSprite?) -> Void)?

    let builtinSprite: PetSprite?

    init(
        settings: AppSettings, store: PetStore,
        builtinLoader: () throws -> PetSprite = {
            guard let root = Bundle.main.resourceURL else { throw PetValidationError.imageDecode }
            return try PetLoader.load(directory: root.appendingPathComponent("Pets/scout"))
        },
        log: (String) -> Void = { NSLog("%@", $0) }
    ) {
        self.settings = settings
        self.store = store
        do { builtinSprite = try builtinLoader() } catch {
            builtinSprite = nil
            log("Builtin pet rejected: " + String(reflecting: error))
        }
        refresh(reload: false)
    }

    func activeSprite() -> PetSprite? {
        guard settings.petSelectedID != "scout" else { return builtinSprite }
        do { return try store.load(settings.petSelectedID) } catch {
            NSLog("Active pet rejected; restoring builtin: %@", String(reflecting: error))
            settings.petSelectedID = "scout"
            return builtinSprite
        }
    }

    func select(_ id: String) {
        if id == "scout" {
            settings.petSelectedID = id
            onReload?(builtinSprite)
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
                select("scout")
            }
            refresh(reload: false)
        } catch { errorMessage = PetStorageError.message(error) }
    }
}
