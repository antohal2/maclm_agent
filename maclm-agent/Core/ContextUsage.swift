import Foundation

struct ContextUsage {
    enum Level { case normal, warning, critical }
    let used: Int?
    let limit: Int
    let approximate: Bool
    init(used: Int?, model: ModelInfo?, fallback: Int) {
        self.used = used
        limit = max(1, model?.loadedContextLength ?? fallback)
        approximate = model?.loadedContextLength == nil
    }

    var level: Level {
        let ratio = Double(used ?? 0) / Double(limit)
        return ratio >= 0.9 ? .critical : ratio >= 0.7 ? .warning : .normal
    }

    static func format(
        _ number: Int,
        locale: Locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? Locale.current.identifier)
    ) -> String {
        let divisor = number >= 1_000_000 ? 1_000_000.0 : number >= 1000 ? 1000.0 : 1
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.maximumFractionDigits = divisor == 1 ? 0 : 1
        let value = formatter.string(from: NSNumber(value: Double(number) / divisor)) ?? String(number)
        let russian = locale.language.languageCode?.identifier == "ru"
        return value + (divisor == 1 ? "" : divisor == 1000 ? (russian ? " тыс." : "K") : (russian ? " млн" : "M"))
    }
}
