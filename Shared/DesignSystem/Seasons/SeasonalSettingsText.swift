import Foundation

@MainActor
enum SeasonalSettingsText {
    /// « Nuit d'Halloween, du 15 octobre au 2 novembre » — pure: the caller
    /// passes the localized name, the `settings.seasonal.window` template and
    /// the APP's locale (`loc.locale`, Localisation RULE). This year's dates.
    static func windowSummary(for theme: SeasonalTheme, name: String, template: String, locale: Locale, calendar: Calendar) -> String {
        let year = calendar.component(.year, from: Date())
        func text(_ md: MonthDay) -> String {
            let date = calendar.date(from: DateComponents(year: year, month: md.month, day: md.day)) ?? Date()
            var style = Date.FormatStyle(date: .omitted, time: .omitted).day().month(.wide).locale(locale)
            style.timeZone = calendar.timeZone
            return date.formatted(style)
        }
        return String(format: template, locale: locale, name, text(theme.window.start), text(theme.window.end))
    }

    /// Every catalogue season, one line each, in the app's language.
    static func catalogueSummary(loc: LocalizationManager, calendar: Calendar = .autoupdatingCurrent) -> String {
        SeasonalThemeCatalogue.all.map {
            windowSummary(
                for: $0, name: loc.localized($0.nameKey),
                template: loc.localized("settings.seasonal.window"),
                locale: loc.locale, calendar: calendar
            )
        }.joined(separator: "\n")
    }
}
