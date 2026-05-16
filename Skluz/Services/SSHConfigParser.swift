import Foundation

nonisolated struct SSHConfigHost: Sendable, Identifiable, Hashable {
    let aliasOrPattern: String
    let hostname: String?
    let user: String?
    let port: Int?
    let identityFile: String?

    var id: String { aliasOrPattern }

    /// Un alias proposable en autocomplete : pas de wildcard ni de négation.
    var isSelectableAlias: Bool {
        !aliasOrPattern.contains(where: { $0 == "*" || $0 == "?" || $0 == "!" })
    }
}

actor SSHConfigParser {
    private let configURL: URL
    private var cache: [SSHConfigHost]?

    init(configURL: URL = SSHConfigParser.defaultURL()) {
        self.configURL = configURL
    }

    static func defaultURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh/config")
    }

    func loadHosts(forceReload: Bool = false) -> [SSHConfigHost] {
        if !forceReload, let cache { return cache }
        let hosts = Self.readAndParse(url: configURL, depth: 0)
        cache = hosts
        return hosts
    }

    func host(for alias: String) -> SSHConfigHost? {
        loadHosts().first { $0.aliasOrPattern == alias }
    }

    // MARK: - Reading (with Include support)

    private static let maxIncludeDepth = 8

    private static func readAndParse(url: URL, depth: Int) -> [SSHConfigHost] {
        guard depth <= maxIncludeDepth,
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return parse(text: text, includeBaseDir: url.deletingLastPathComponent(), depth: depth)
    }

    // MARK: - Pure parser

    /// Parse passive du contenu ssh_config. Ne modifie jamais le fichier.
    static func parse(
        text: String,
        includeBaseDir: URL = SSHConfigParser.defaultURL().deletingLastPathComponent(),
        depth: Int = 0
    ) -> [SSHConfigHost] {
        var hosts: [SSHConfigHost] = []
        var patterns: [String] = []
        var settings: [String: String] = [:]
        var inMatchBlock = false

        func flush() {
            guard !patterns.isEmpty else { return }
            for pattern in patterns {
                hosts.append(SSHConfigHost(
                    aliasOrPattern: pattern,
                    hostname: settings["hostname"],
                    user: settings["user"],
                    port: settings["port"].flatMap { Int($0) },
                    identityFile: settings["identityfile"]
                ))
            }
            patterns = []
            settings = [:]
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let (keyword, value) = tokenize(String(rawLine)) else { continue }

            switch keyword {
            case "host":
                flush()
                inMatchBlock = false
                patterns = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            case "match":
                flush()
                inMatchBlock = true
            case "include":
                let included = resolveIncludes(value, baseDir: includeBaseDir)
                    .flatMap { readAndParse(url: $0, depth: depth + 1) }
                hosts.append(contentsOf: included)
            default:
                guard !inMatchBlock, !patterns.isEmpty else { continue }
                // ssh_config : la première occurrence d'une clé gagne.
                if settings[keyword] == nil {
                    settings[keyword] = value
                }
            }
        }
        flush()
        return hosts
    }

    /// Sépare `Keyword Value` ou `Keyword=Value`, gère les guillemets et commentaires.
    static func tokenize(_ line: String) -> (keyword: String, value: String)? {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }

        // Séparateur : '=' ou espace(s)/tab.
        guard let sepIndex = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else {
            return nil
        }
        let keyword = trimmed[trimmed.startIndex..<sepIndex].lowercased()
        var rest = String(trimmed[trimmed.index(after: sepIndex)...]).trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("=") {
            rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if rest.hasPrefix("\""), rest.hasSuffix("\""), rest.count >= 2 {
            rest = String(rest.dropFirst().dropLast())
        }
        trimmed = rest
        guard !keyword.isEmpty, !trimmed.isEmpty else { return nil }
        return (keyword, trimmed)
    }

    private static func resolveIncludes(_ value: String, baseDir: URL) -> [URL] {
        let expanded = NSString(string: value).expandingTildeInPath
        let pattern: String
        if expanded.hasPrefix("/") {
            pattern = expanded
        } else {
            pattern = baseDir.appendingPathComponent(expanded).path
        }

        var result = glob_t()
        defer { globfree(&result) }
        guard glob(pattern, 0, nil, &result) == 0 else { return [] }
        return (0..<Int(result.gl_pathc)).compactMap { i in
            result.gl_pathv[i].flatMap { String(validatingUTF8: $0) }
        }.map { URL(fileURLWithPath: $0) }
    }
}
