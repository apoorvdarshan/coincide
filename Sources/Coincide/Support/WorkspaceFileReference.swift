import Foundation

enum WorkspaceFileReference {
    /// Canonical relative file links also remain readable to providers without mention support.
    static func markdown(path: String) -> String {
        let basename = (path as NSString).lastPathComponent
        let label = basename.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
        let destination = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return "[\(label)](\(destination))"
    }
}
