import Foundation

/// A declarative, data-only description of an extra subscription quota
/// endpoint.  Plugins are JSON files, never code: there is no script, shell,
/// dynamic library, or expression evaluation anywhere in this path, so adding
/// a subscription cannot execute anything the owner did not already run.
///
/// A descriptor names one GET endpoint and, for each quota window, the JSON
/// paths of the numbers CodeCaps should show.  Secrets are never in the file:
/// authentication is either absent or the *name* of an environment variable
/// whose value is sent as a Bearer token and never logged.
public struct EndpointPluginDescriptor: Codable, Equatable, Sendable {
    public struct Auth: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case none
            case bearerEnv
        }

        public var type: Kind
        /// Environment variable holding the Bearer token (`bearerEnv` only).
        public var env: String?

        public init(type: Kind, env: String? = nil) {
            self.type = type
            self.env = env
        }
    }

    public struct Window: Codable, Equatable, Sendable {
        /// Suffix appended to the provider key to form the window id.
        public var idSuffix: String
        public var label: String
        /// Cadence name shown by the app, e.g. `5h`, `weekly`, `monthly`.
        public var window: String?
        /// JSON path of a 0-100 *remaining* percentage.
        public var remainingPercentPath: String?
        /// JSON path of a 0-100 *used* percentage (the complement is shown).
        public var usedPercentPath: String?
        public var absoluteRemainingPath: String?
        public var absoluteLimitPath: String?
        public var quotaUnit: String?
        /// JSON path of an ISO-8601 reset stamp or an epoch seconds/ms number.
        public var resetAtPath: String?
        public var planNamePath: String?

        public init(idSuffix: String, label: String, window: String? = nil,
                    remainingPercentPath: String? = nil, usedPercentPath: String? = nil,
                    absoluteRemainingPath: String? = nil, absoluteLimitPath: String? = nil,
                    quotaUnit: String? = nil, resetAtPath: String? = nil, planNamePath: String? = nil) {
            self.idSuffix = idSuffix
            self.label = label
            self.window = window
            self.remainingPercentPath = remainingPercentPath
            self.usedPercentPath = usedPercentPath
            self.absoluteRemainingPath = absoluteRemainingPath
            self.absoluteLimitPath = absoluteLimitPath
            self.quotaUnit = quotaUnit
            self.resetAtPath = resetAtPath
            self.planNamePath = planNamePath
        }
    }

    /// Registration id, always `plugin:<slug>` so it can never shadow a
    /// built-in reader in Settings, ranking, or source toggles.
    public var id: String
    public var displayName: String
    /// Quota provider key the windows are filed under, e.g. `acme-plan`.
    public var providerKey: String
    /// GET endpoint.  HTTPS only, except loopback HTTP with `allowLoopback`.
    public var endpoint: String
    public var allowLoopback: Bool?
    public var auth: Auth
    public var windows: [Window]

    public init(id: String, displayName: String, providerKey: String, endpoint: String,
                allowLoopback: Bool? = nil, auth: Auth, windows: [Window]) {
        self.id = id
        self.displayName = displayName
        self.providerKey = providerKey
        self.endpoint = endpoint
        self.allowLoopback = allowLoopback
        self.auth = auth
        self.windows = windows
    }

    /// Provider keys a plugin may not claim, so a descriptor can never
    /// impersonate a built-in subscription row.
    static let reservedProviderKeys: Set<String> = [
        "anthropic", "openai", "google-antigravity", "cursor", "github-copilot",
        "xai", "grok", "grok-bot", "minimax", "muse-assist", "muse-code",
        "kimi", "zcode", "alibaba-token-plan", "alibaba-coding-plan",
        "mimo-token-plan", "opencode-go",
    ]

    /// Why a descriptor was refused.  The text is shown nowhere with the file
    /// contents; it exists for tests and for a one-line Settings note.
    public enum ValidationError: Error, Equatable, Sendable {
        case badID, badDisplayName, badProviderKey, reservedProviderKey, badEndpoint, badAuth, badWindows, badPath(String)
    }

    /// The only environment variables a plugin may send: a plugin file can
    /// name a purpose-made variable, never a general-purpose secret that
    /// happens to be in the app's environment.
    public static func isPluginEnvName(_ name: String) -> Bool {
        name.range(of: "^CODECAPS_PLUGIN_[A-Z0-9_]{1,100}$", options: .regularExpression) != nil
    }

    public func validated() throws -> EndpointPluginDescriptor {
        guard Self.isSlug(id, prefix: "plugin:") else { throw ValidationError.badID }
        guard Self.isSlug(providerKey, prefix: "") else { throw ValidationError.badProviderKey }
        guard !Self.reservedProviderKeys.contains(providerKey) else { throw ValidationError.reservedProviderKey }
        guard (1...200).contains(displayName.count), !displayName.contains("\n") else { throw ValidationError.badDisplayName }
        guard let url = Self.validatedEndpoint(endpoint, allowLoopback: allowLoopback ?? false) else {
            throw ValidationError.badEndpoint
        }
        _ = url
        switch auth.type {
        case .none:
            if auth.env != nil { throw ValidationError.badAuth }
        case .bearerEnv:
            guard let env = auth.env, Self.isPluginEnvName(env)
            else { throw ValidationError.badAuth }
        }
        guard (1...10).contains(windows.count) else { throw ValidationError.badWindows }
        var suffixes = Set<String>()
        for window in windows {
            let percentPaths = [window.remainingPercentPath, window.usedPercentPath].compactMap { $0 }.count
            guard Self.isSlug(window.idSuffix, prefix: ""), suffixes.insert(window.idSuffix).inserted,
                  (1...80).contains(window.label.count),
                  percentPaths <= 1,
                  percentPaths == 1
                    || (window.absoluteRemainingPath != nil && window.absoluteLimitPath != nil)
            else { throw ValidationError.badWindows }
            for path in [window.remainingPercentPath, window.usedPercentPath, window.absoluteRemainingPath,
                         window.absoluteLimitPath, window.resetAtPath, window.planNamePath].compactMap({ $0 }) {
                guard EndpointJSONPath.isValid(path) else { throw ValidationError.badPath(path) }
            }
        }
        return self
    }

    public var endpointURL: URL? {
        Self.validatedEndpoint(endpoint, allowLoopback: allowLoopback ?? false)
    }

    static func isSlug(_ value: String, prefix: String) -> Bool {
        guard value.hasPrefix(prefix) else { return false }
        let slug = value.dropFirst(prefix.count)
        guard (1...63).contains(slug.count),
              let first = slug.unicodeScalars.first,
              (97...122).contains(first.value) || (48...57).contains(first.value) else { return false }
        return slug.unicodeScalars.allSatisfy {
            (97...122).contains($0.value) || (48...57).contains($0.value) || $0.value == 45
        } && !slug.hasSuffix("-") && !slug.contains("--")
    }

    /// The plugin SSRF gate, deliberately stricter than the user-endpoint
    /// gate in `QuotaClient`: no userinfo, query, or fragment; HTTPS only
    /// (loopback HTTP needs the explicit opt-in); and a literal host may
    /// never be a private, loopback, link-local, or metadata address.  A
    /// hostname that *resolves* to such an address is refused by
    /// `BoundedHTTPFetch`'s no-redirect rule only at connect time, so DNS
    /// rebinding remains a documented residual risk of declarative plugins:
    /// a descriptor is trusted configuration the owner placed on disk, in
    /// the same trust class as the push/pull endpoint in Settings.
    static func validatedEndpoint(_ raw: String, allowLoopback: Bool) -> URL? {
        guard let components = URLComponents(string: raw),
              let rawHost = components.host?.lowercased(), !rawHost.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return nil }
        // An IPv6 literal may still carry its brackets depending on the
        // URL parser; compare the bare address either way.
        let host = rawHost.hasPrefix("[") && rawHost.hasSuffix("]")
            ? String(rawHost.dropFirst().dropLast()) : rawHost
        let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        // The port relaxation belongs to loopback only; an external host
        // keeps the default-or-443 rule even when the opt-in is set.
        if let port = components.port, port != 443 {
            guard allowLoopback, loopback else { return nil }
        }
        if components.scheme == "http" {
            guard allowLoopback, loopback else { return nil }
        } else {
            guard components.scheme == "https" else { return nil }
        }
        if loopback { return allowLoopback ? components.url : nil }
        if isPrivateLiteralIP(host) || isNonCanonicalIPLiteral(host) { return nil }
        return components.url
    }

    /// A host written like an IP address but not as a strict decimal
    /// dotted quad — hex (`0x7f.0.0.1`), octal (`0177.0.0.1`), a bare
    /// integer (`2130706433`), or a leading-zero octet — can be resolved
    /// by the network stack as the private address it disguises, so it is
    /// refused outright rather than classified as a public hostname.
    static func isNonCanonicalIPLiteral(_ host: String) -> Bool {
        let segments = host.split(separator: ".", omittingEmptySubsequences: false)
        let numericLike = segments.allSatisfy { segment in
            !segment.isEmpty && segment.range(of: "^(0[xX][0-9a-fA-F]+|[0-9]+)$", options: .regularExpression) != nil
        }
        guard numericLike, segments.contains(where: { Int($0) != nil || $0.lowercased().hasPrefix("0x") }) else { return false }
        guard segments.count == 4 else { return true }
        return segments.contains { segment in
            guard let value = Int(segment), String(value) == segment, (0...255).contains(value) else { return true }
            return false
        }
    }

    static func isPrivateLiteralIP(_ host: String) -> Bool {
        let ipv4 = host.split(separator: ".").map { Int($0) }
        if ipv4.count == 4, ipv4.allSatisfy({ $0 != nil }) {
            let octets = ipv4.map { $0! }
            guard octets.allSatisfy({ (0...255).contains($0) }) else { return false }
            switch octets[0] {
            case 0, 10, 127: return true
            case 100: return (64...127).contains(octets[1])
            case 169: return octets[1] == 254
            case 172: return (16...31).contains(octets[1])
            case 192: return octets[1] == 168 || (octets[1] == 0 && octets[2] == 0)
            case 198: return octets[1] == 18 || octets[1] == 19
            case 224...255: return true
            default: return false
            }
        }
        let lower = host.lowercased()
        if lower == "::1" || lower.hasPrefix("fe8") || lower.hasPrefix("fe9")
            || lower.hasPrefix("fea") || lower.hasPrefix("feb")
            || lower.hasPrefix("fc") || lower.hasPrefix("fd") || lower.hasPrefix("ff") {
            return true
        }
        return false
    }
}

/// A restricted JSON path: dot-separated keys with optional `[index]`
/// steps, e.g. `usage.rolling.percent` or `items[0].remaining`.  There is
/// no wildcard, filter, or expression syntax, by design.
public enum EndpointJSONPath {
    public static func isValid(_ path: String) -> Bool {
        guard (1...200).contains(path.count), !path.hasPrefix("."), !path.hasSuffix("."),
              !path.contains(".."), !path.contains(" ") else { return false }
        return path.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { segment in
            !segment.isEmpty && segment.range(of: "^[A-Za-z0-9_-]+(\\[[0-9]{1,4}\\])*$", options: .regularExpression) != nil
        }
    }

    public static func resolve(_ root: Any, path: String) -> Any? {
        var current: Any = root
        for segment in path.split(separator: ".", omittingEmptySubsequences: false) {
            let parts = segment.split(separator: "[", omittingEmptySubsequences: false)
            guard let key = parts.first, !key.isEmpty,
                  let dict = current as? [String: Any], let next = dict[String(key)] else { return nil }
            current = next
            for indexPart in parts.dropFirst() {
                guard indexPart.hasSuffix("]"), let index = Int(indexPart.dropLast()),
                      let array = current as? [Any], array.indices.contains(index) else { return nil }
                current = array[index]
            }
        }
        return current
    }

    public static func number(_ root: Any, path: String?) -> Double? {
        guard let path, let value = resolve(root, path: path) else { return nil }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.utf8.count <= 32,
                  trimmed.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == "-") }),
                  let parsed = Double(trimmed), parsed.isFinite else { return nil }
            return parsed
        }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    public static func string(_ root: Any, path: String?) -> String? {
        guard let path, let value = resolve(root, path: path) as? String,
              !value.isEmpty, value.utf8.count <= 160 else { return nil }
        return value
    }
}
