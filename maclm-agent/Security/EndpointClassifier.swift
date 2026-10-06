import Darwin
import Foundation

enum EndpointExposure: Equatable { case loopback, lan, external, invalid }

enum EndpointClassifier {
    static func classify(_ address: String) -> EndpointExposure {
        guard let components = URLComponents(string: address),
              ["http", "https"].contains(components.scheme?.lowercased()),
              components.user == nil, components.password == nil,
              let raw = components.host, !raw.isEmpty,
              components.port.map({ (1 ... 65535).contains($0) }) ?? true else { return .invalid }
        let host = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" {
            return .loopback
        }
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            let value = UInt32(bigEndian: ipv4.s_addr)
            let first = value >> 24
            let second = (value >> 16) & 255
            if first == 127 {
                return .loopback
            }
            if first == 10 || (first == 172 && (16 ... 31).contains(second)) || (first == 192 && second == 168) ||
                (first == 169 && second == 254)
            {
                return .lan
            }
            return .external
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, host, &ipv6) == 1 {
            let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
            if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 {
                return .loopback
            }
            if bytes[0] & 0xFE == 0xFC || (bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80) {
                return .lan
            }
            return .external
        }
        guard host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
            !label.isEmpty && label.first != "-" && label.last != "-" && label
                .allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }) else { return .invalid }
        return host.hasSuffix(".local") ? .lan : .external
    }
}
