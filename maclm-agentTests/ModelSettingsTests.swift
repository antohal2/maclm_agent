import Foundation
@testable import maclm_agent
import XCTest

final class ModelSettingsTests: XCTestCase {
    private func resource(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    /// Synthetic documentation fixtures: local servers were unavailable on 2026-10-05.
    private func fixture(_ name: String) throws -> Data {
        try resource("\(name)-synthetic")
    }

    func testEndpointClassification() {
        for host in ["localhost", "127.0.0.1", "127.5.5.5", "[::1]"] {
            XCTAssertEqual(EndpointClassifier.classify("http://\(host)"), .loopback, host)
        }
        for host in [
            "192.168.1.10",
            "10.0.0.5",
            "172.16.3.4",
            "169.254.1.1",
            "mac-studio.local",
            "[fe80::1]",
            "[fd00::1]",
        ] {
            XCTAssertEqual(EndpointClassifier.classify("http://\(host)"), .lan, host)
        }
        for host in ["172.32.0.1", "8.8.8.8", "example.com"] {
            XCTAssertEqual(EndpointClassifier.classify("http://\(host)"), .external, host)
        }
        for address in ["garbage", "file:///tmp/foo", "http://bad host", "http://user:pass@localhost"] {
            XCTAssertEqual(EndpointClassifier.classify(address), .invalid, address)
        }
    }

    func testEmbeddingFilter() {
        XCTAssertTrue(ModelInfo(id: "model", kind: .embedding).isEmbedding)
        XCTAssertTrue(ModelInfo(id: "NOMIC-EMBED").isEmbedding)
        XCTAssertTrue(ModelInfo(id: "embed", kind: .unknown).isEmbedding)
        XCTAssertFalse(ModelInfo(id: "chat-embed", kind: .chat).isEmbedding)
    }

    func testLMStudioMetadataAndMissingFields() throws {
        for version in ["v0", "v1"] {
            let models = try ModelMetadataParser.lmStudio(fixture("lmstudio-\(version)"))
            XCTAssertEqual(models[0].kind, .chat)
            XCTAssertEqual(models[0].isLoaded, true)
            XCTAssertEqual(models[0].contextLength, 32768)
            XCTAssertEqual(models[1].kind, .embedding)
            XCTAssertEqual(models[1].isLoaded, false)
            XCTAssertNil(models[2].kind)
            XCTAssertNil(models[2].isLoaded)
            XCTAssertNil(models[2].contextLength)
            XCTAssertNil(models[2].supportsTools)
            XCTAssertEqual(models[0].supportsTools, version == "v1" ? true : nil)
        }
    }

    func testLiveLMStudioFixtureAndDuplicateIDs() throws {
        let data = try resource("lmstudio-v1-live-0.4.25")
        let models = try ProviderDiscovery.uniqueModels(ModelMetadataParser.lmStudio(data))
        XCTAssertEqual(models.count, Set(models.map(\.id)).count)
        let embedding = try XCTUnwrap(models.first { $0.id == "text-embedding-nomic-embed-text-v1.5" })
        XCTAssertTrue(embedding.isEmbedding)
        XCTAssertNil(embedding.supportsTools)
        let loaded = try XCTUnwrap(models.first { $0.id == "google/gemma-4-e4b" })
        XCTAssertEqual(loaded.isLoaded, true)
        XCTAssertEqual(loaded.contextLength, 131_072)
        XCTAssertEqual(loaded.supportsTools, true)
    }

    func testOllamaMetadata() throws {
        let models = try ModelMetadataParser.ollamaTags(fixture("ollama-tags"))
        let result = try ModelMetadataParser.enrichOllama(
            models[0],
            show: fixture("ollama-show"),
            running: fixture("ollama-ps")
        )
        XCTAssertEqual(result.kind, .chat)
        XCTAssertEqual(result.contextLength, 32768)
        XCTAssertEqual(result.supportsTools, true)
        XCTAssertEqual(result.isLoaded, true)
        let missing = ModelMetadataParser.enrichOllama(models[1], show: Data("{}".utf8), running: nil)
        XCTAssertNil(missing.kind)
        XCTAssertNil(missing.supportsTools)
        XCTAssertNil(missing.contextLength)
        XCTAssertNil(missing.isLoaded)
    }

    @MainActor
    func testLegacySelectionAndConfirmation() throws {
        let name = "ModelSettingsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("lmStudio", forKey: "llm.selectedProvider")
        defaults.set("http://192.168.1.10:1234", forKey: "llm.baseURL")
        defaults.set("saved-model", forKey: "llm.selectedModel")
        let store = ProviderSelectionStore(defaults: defaults)
        let coordinator = ProviderCoordinator(store: store)
        XCTAssertEqual(coordinator.selection?.model, "saved-model")
        XCTAssertEqual(coordinator.customEndpoints.first?.baseURL.absoluteString, "http://192.168.1.10:1234")
        XCTAssertThrowsError(try coordinator.addEndpoint(provider: .ollama, address: "https://example.com"))
        XCTAssertThrowsError(try coordinator.configureManually(
            provider: .ollama, baseURLText: "https://other.example", model: "manual-model"
        ))
        XCTAssertEqual(coordinator.customEndpoints.count, 1)
        try coordinator.addEndpoint(provider: .ollama, address: "https://example.com", confirmed: true)
        XCTAssertEqual(store.loadEndpoints().count, 2)
        XCTAssertEqual(store.load()?.model, "saved-model")
    }

    @MainActor
    func testLanguagePersistence() throws {
        let name = "LanguageSettingsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.interfaceLanguage, "system")
        settings.interfaceLanguage = "ru"
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["ru"])
        XCTAssertEqual(AppSettings(defaults: defaults).interfaceLanguage, "ru")
        settings.interfaceLanguage = "system"
        XCTAssertNil(defaults.persistentDomain(forName: name)?["AppleLanguages"])
    }

    func testEveryCatalogEntryHasBothLanguages() throws {
        let data = try resource("LocalizableCatalog")
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        XCTAssertFalse(strings.isEmpty)
        for (key, entry) in strings {
            let languages = try XCTUnwrap(entry["localizations"] as? [String: [String: Any]], key)
            for language in ["ru", "en"] {
                let unit = try XCTUnwrap(languages[language]?["stringUnit"] as? [String: Any], "\(key): \(language)")
                XCTAssertEqual(unit["state"] as? String, "translated", key)
                XCTAssertNotNil(unit["value"] as? String, key)
            }
        }
    }
}
