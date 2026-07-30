import Foundation

enum ClipboardActionTemplate {
    static let inputPlaceholder = "{{input}}"

    enum TemplateError: Error, Equatable {
        case emptyTemplate
        case missingInputPlaceholder
    }

    static func validate(_ template: String) -> Result<Void, TemplateError> {
        guard !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.emptyTemplate)
        }
        guard template.contains(inputPlaceholder) else {
            return .failure(.missingInputPlaceholder)
        }
        return .success(())
    }

    static func render(_ template: String, input: String) -> String {
        template.replacingOccurrences(of: inputPlaceholder, with: input)
    }
}
