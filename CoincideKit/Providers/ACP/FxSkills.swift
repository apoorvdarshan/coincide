import Foundation

/// Finds fx skills for the composer's `$` menu by scanning the `SKILL.md` folders fx reads (fx 0.0.13,
/// src/builtins/skills.zig), as T3 Code's `discoverFxSkills` does, so no `fx acp` session starts for a menu.
enum FxSkills {
    /// A folder fx reads skills from. `rank` is its group in fx's menu: the managed `~/.fx/skills`, then the
    /// workspace's `.fx/skills` and `skills`, then every compatibility folder (`skillGroupRank` in
    /// src/core/skills/skill_runtime.zig). fx follows linked skill folders everywhere except in its managed folder.
    private struct Root {
        var relative: String
        var rank: Int
        var followsLinks = true
    }

    private struct Location {
        var directory: String
        var scope: ProviderSkill.Scope
        var rank: Int
        var followsLinks: Bool
    }

    private nonisolated static let workspaceRoots = [
        Root(relative: ".fx/skills", rank: 1), Root(relative: "skills", rank: 1), Root(relative: ".opencode/skills", rank: 2),
        Root(relative: ".codex/skills", rank: 2), Root(relative: ".claude/skills", rank: 2),
        Root(relative: ".agents/skills", rank: 2), Root(relative: ".claw/skills", rank: 2),
    ]
    private nonisolated static let homeRoots = [
        Root(relative: ".fx/skills", rank: 0, followsLinks: false), Root(relative: ".config/opencode/skills", rank: 2),
        Root(relative: ".codex/skills", rank: 2), Root(relative: ".claude/skills", rank: 2),
        Root(relative: ".agents/skills", rank: 2), Root(relative: ".claw/skills", rank: 2),
    ]

    /// fx reads only this much of a `SKILL.md`, so a long body never hides a skill.
    nonisolated static let maxFrontmatterBytes = 64 * 1024
    nonisolated static let maxNameBytes = 256

    /// Skills in fx's menu order. As in fx, a folder reached twice (through a linked folder) counts once. Of two
    /// different skills with the same name, `$name` loads the first in scan order, so that is the one listed;
    /// `$review` and `$Review` each load the skill whose name matches the typed case.
    nonisolated static func discover(workingDirectory: URL, environment: [String: String]) -> [ProviderSkill] {
        // fx reads skills only under a set HOME, and compares HOME and the workspace by their real paths.
        guard let configured = ACPToolCallState.nonEmpty(environment["HOME"] ?? "") else { return [] }
        let home = ACPFileSystem.realPath(configured) ?? configured
        let cwd = ACPFileSystem.realPath(workingDirectory.path) ?? workingDirectory.path
        var seenFolders = Set<[UInt8]>()
        var seenNames = Set<[UInt8]>()
        var found: [(skill: ProviderSkill, rank: Int)] = []
        for location in locations(cwd: cwd, home: home) {
            for (skill, folder) in skills(in: location) {
                guard seenFolders.insert(Array(folder.utf8)).inserted, seenNames.insert(Array(skill.name.utf8)).inserted else {
                    continue
                }
                found.append((skill, location.rank))
            }
        }
        return found.enumerated().sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }.map(\.element.skill)
    }

    /// The workspace folders of each folder from the workspace up to, not including, HOME, then the home folders.
    private nonisolated static func locations(cwd: String, home: String) -> [Location] {
        var locations: [Location] = []
        var current = cwd
        while current != home {
            for root in workspaceRoots {
                locations.append(
                    Location(directory: join(current, root.relative), scope: .project, rank: root.rank, followsLinks: root.followsLinks))
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { break }
            current = parent
        }
        for root in homeRoots {
            locations.append(Location(directory: join(home, root.relative), scope: .user, rank: root.rank, followsLinks: root.followsLinks))
        }
        return locations
    }

    private nonisolated static func skills(in location: Location) -> [(skill: ProviderSkill, folder: String)] {
        let directory = location.directory
        // fx gives its managed folder no read authority through links: it loads nothing through a link to the folder,
        // or to a skill folder or `SKILL.md` in it. HOME is a real path here, so a linked folder changes the real path.
        if !location.followsLinks, let real = ACPFileSystem.realPath(directory), real != directory { return [] }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        var skills: [(ProviderSkill, String)] = []
        // fx reads a folder's entries in UTF-8 byte order.
        for entry in entries.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
            let folder = join(directory, entry)
            if !location.followsLinks, isLink(folder) { continue }
            // A stray file (`.DS_Store`, a README) is no skill folder.
            guard fileType(folder) == S_IFDIR else { continue }
            let path = join(folder, "SKILL.md")
            if !location.followsLinks, isLink(path) { continue }
            guard fileType(path) == S_IFREG, let prefix = readPrefix(path), let metadata = metadata(decode(prefix), folderName: entry)
            else { continue }
            skills.append(
                (
                    ProviderSkill(name: metadata.name, description: metadata.description, path: path, scope: location.scope),
                    ACPFileSystem.realPath(folder) ?? folder
                ))
        }
        return skills
    }

    // MARK: SKILL.md

    private typealias Scalars = [Unicode.Scalar]

    /// fx reads bytes: a byte order mark means no frontmatter, and invalid UTF-8 in a value makes the skill invalid
    /// while a literal U+FFFD is fine. So the mark stays, and a line with invalid UTF-8 ends in a NUL, which the
    /// parser rejects.
    nonisolated static func decode(_ data: Data) -> String {
        data.split(separator: 0x0A, omittingEmptySubsequences: false).map { line in
            String(validating: line, as: UTF8.self) ?? String(decoding: line, as: UTF8.self) + "\u{0}"
        }.joined(separator: "\n")
    }

    /// Reads `SKILL.md` the way fx 0.0.13 does (`parseSkillFile` in src/core/skills/skill_contract.zig): a line-based
    /// header, not YAML. Without frontmatter the folder names the skill; frontmatter fx cannot read (no closing `---`,
    /// a missing or repeated `name`, a value continued on the next line) skips it.
    nonisolated static func metadata(_ contents: String, folderName: String) -> (name: String, description: String?)? {
        let text = Array(contents.unicodeScalars)
        let fallback = isValidName(Array(folderName.unicodeScalars)) ? (folderName, String?.none) : nil
        // `---` followed by a line break or the end of the file opens the frontmatter.
        let dashes = Array("---".unicodeScalars)
        guard text.starts(with: dashes) else { return fallback }
        var opening = 3
        if text.count > 3 {
            if text[3] == "\n" {
                opening = 4
            } else if text[3] == "\r", text.count > 4, text[4] == "\n" {
                opening = 5
            } else {
                return fallback
            }
        }
        let lines = text.count > opening
            ? text[opening...].split(separator: "\n", omittingEmptySubsequences: false).map(Array.init) : [[]]
        // fx drops a line's trailing `\r` only before a line break, and bounds the file at the line after the
        // closing `---`.
        let last = lines.count - 1
        guard let closing = lines.indices.first(where: { ($0 == last ? lines[$0] : withoutReturn(lines[$0])) == dashes }) else {
            return nil
        }
        let bodyStart =
            utf8Count(text[..<opening]) + lines[...closing].reduce(0) { $0 + utf8Count($1) } + closing + (closing == last ? 0 : 1)
        guard bodyStart <= maxFrontmatterBytes else { return nil }
        let header = lines[..<closing].map(withoutReturn)

        var name: Scalars?
        var description: String?
        var sawName = false
        var sawDescription = false
        var previousRecognized = false
        var index = 0
        while index < header.count {
            let line = header[index]
            index += 1
            let trimmed = trimSpaceTab(line)
            if trimmed.isEmpty || trimmed.first == "#" { continue }
            if previousRecognized, line.first == " " || line.first == "\t" { return nil }
            previousRecognized = false
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(scalars: trimSpaceTab(Array(trimmed[..<colon])))
            let raw = trimSpaceTab(Array(trimmed[(colon + 1)...]))
            if key == "name" {
                if sawName { return nil }
                sawName = true
                guard let value = recognizedValue(raw) else { return nil }
                name = value
                previousRecognized = true
            } else if key == "description" {
                if sawDescription { return nil }
                sawDescription = true
                let style = String(scalars: raw)
                if [">", ">-", "|"].contains(style) {
                    // A block runs over the following space-indented lines; fx rejects a tab or a shrinking indent in
                    // it. Blank lines stay part of the block (nil).
                    var block: [Scalars?] = []
                    var baseIndent: Int?
                    while index < header.count {
                        let next = header[index]
                        if trimSpaceTab(next).isEmpty {
                            block.append(nil)
                            index += 1
                            continue
                        }
                        let indent = next.prefix { $0 == " " }.count
                        if next[indent] == "\t" { return nil }
                        if indent == 0 { break }
                        if let baseIndent, indent < baseIndent { return nil }
                        let base = baseIndent ?? indent
                        baseIndent = base
                        let content = Array(next[base...])
                        if hasControl(content) { return nil }
                        block.append(content)
                        index += 1
                    }
                    description = blockDescription(block, style: style)
                } else {
                    guard let value = recognizedValue(raw), !hasControl(value) else { return nil }
                    description = String(scalars: value)
                    previousRecognized = true
                }
            }
        }
        guard let name, isValidName(name) else { return nil }
        return (String(scalars: name), description.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// fx's `parseRecognizedValue`: one quoted or bare scalar, no YAML.
    private nonisolated static func recognizedValue(_ raw: Scalars) -> Scalars? {
        if raw.first == "|" || raw.first == ">" { return nil }
        let quotes: Set<Unicode.Scalar> = ["'", "\""]
        guard raw.first.map(quotes.contains) == true || raw.last.map(quotes.contains) == true else { return raw }
        guard raw.count >= 2, raw.first == raw.last else { return nil }
        return Array(raw.dropFirst().dropLast())
    }

    /// fx's `decode_block_description`: `|` keeps line breaks; `>` and `>-` join neighbouring lines with a space and
    /// turn a blank line into a break. Only `>-` drops the final newline, which the menu trims anyway.
    private nonisolated static func blockDescription(_ lines: [Scalars?], style: String) -> String {
        guard let last = lines.lastIndex(where: { $0 != nil }) else { return "" }
        var text: Scalars = []
        for index in 0...last {
            if index > 0 { text.append(style != "|" && lines[index - 1] != nil && lines[index] != nil ? " " : "\n") }
            text += lines[index] ?? []
        }
        return String(scalars: text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// fx's `invalidSkillNameCause`.
    private nonisolated static func isValidName(_ name: Scalars) -> Bool {
        let text = String(scalars: name)
        return !name.isEmpty && text.utf8.count <= maxNameBytes && !hasControl(name) && text != "." && text != ".."
            && !name.contains("/") && !name.contains("\\")
    }

    /// fx's `invalidTextCause`: no ASCII control character (invalid UTF-8 shows up as one).
    private nonisolated static func hasControl(_ text: Scalars) -> Bool {
        text.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    /// fx trims only spaces and tabs.
    private nonisolated static func trimSpaceTab(_ text: Scalars) -> Scalars {
        let isBlank: (Unicode.Scalar) -> Bool = { $0 == " " || $0 == "\t" }
        guard let first = text.firstIndex(where: { !isBlank($0) }), let last = text.lastIndex(where: { !isBlank($0) }) else {
            return []
        }
        return Array(text[first...last])
    }

    private nonisolated static func withoutReturn(_ line: Scalars) -> Scalars {
        line.last == "\r" ? Array(line.dropLast()) : line
    }

    private nonisolated static func utf8Count(_ scalars: some Sequence<Unicode.Scalar>) -> Int {
        scalars.reduce(0) { $0 + UTF8.width($1) }
    }

    // MARK: Files

    private nonisolated static func join(_ directory: String, _ name: String) -> String {
        (directory as NSString).appendingPathComponent(name)
    }

    /// The file type, following links.
    private nonisolated static func fileType(_ path: String) -> mode_t? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return info.st_mode & S_IFMT
    }

    private nonisolated static func isLink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK
    }

    /// The start of the file fx reads; nil when it cannot be read.
    private nonisolated static func readPrefix(_ path: String) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            // Nil means the file is empty.
            return try handle.read(upToCount: maxFrontmatterBytes + 1) ?? Data()
        } catch {
            return nil
        }
    }
}

extension String {
    fileprivate nonisolated init(scalars: [Unicode.Scalar]) {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        self = String(view)
    }
}
