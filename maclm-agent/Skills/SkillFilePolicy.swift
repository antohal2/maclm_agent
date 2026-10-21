/// Shared basename policy for traversal and skill-file reads at every path depth.
enum SkillFilePolicy {
    static func isIgnored(_ name: String) -> Bool {
        name == ".DS_Store" || name.hasPrefix("._")
    }
}
