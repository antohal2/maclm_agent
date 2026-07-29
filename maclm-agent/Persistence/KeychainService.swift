import Foundation
import Security

enum KeychainServiceError: Error, Equatable, LocalizedError {
    case unexpectedData
    case operationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedData:
            "Keychain вернул данные в неожиданном формате."
        case let .operationFailed(status):
            SecCopyErrorMessageString(status, nil) as String?
                ?? "Операция Keychain завершилась с кодом \(status)."
        }
    }
}

struct KeychainService: Sendable {
    private let service: String

    init(service: String = Bundle.main.bundleIdentifier ?? "local.maclm-agent") {
        self.service = service
    }

    func save(key: String, value: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(for: key)
        let attributes = [kSecValueData: data] as CFDictionary
        let status = SecItemUpdate(query as CFDictionary, attributes)

        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = query
            attributes[kSecValueData] = data
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainServiceError.operationFailed(addStatus)
            }
        default:
            throw KeychainServiceError.operationFailed(status)
        }
    }

    func read(key: String) throws -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard
                let data = result as? Data,
                let value = String(data: data, encoding: .utf8)
            else {
                throw KeychainServiceError.unexpectedData
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainServiceError.operationFailed(status)
        }
    }

    func delete(key: String) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainServiceError.operationFailed(status)
        }
    }

    private func baseQuery(for key: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
    }
}
