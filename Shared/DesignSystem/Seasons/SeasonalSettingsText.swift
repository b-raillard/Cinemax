import Foundation

@MainActor
enum SeasonalSettingsText {
    /// « Nuit d'Halloween, du 1er octobre au 2 novembre » — pure: the caller
    /// passes the localized name, the `settings.seasonal.window` template and
    /// the APP's locale (`loc.locale`, Localisation RULE). This year's dates.
    static func windowSummary(for theme: SeasonalTheme, name: String, template: String, locale: Locale, calendar: Calendar) -> String {
        String(
            format: template, locale: locale, name,
            dayMonth(theme.window.start, locale: locale, calendar: calendar),
            dayMonth(theme.window.end, locale: locale, calendar: calendar)
        )
    }

    /// « 1er octobre » / « October 1 » (« 1er oct. » / « Oct 1 » abbreviated),
    /// in the app's language.
    static func dayMonth(
        _ md: MonthDay, locale: Locale, calendar: Calendar = .autoupdatingCurrent, abbreviated: Bool = false
    ) -> String {
        let year = calendar.component(.year, from: Date())
        let date = calendar.date(from: DateComponents(year: year, month: md.month, day: md.day)) ?? Date()
        var style = Date.FormatStyle(date: .omitted, time: .omitted).day().month(abbreviated ? .abbreviated : .wide).locale(locale)
        style.timeZone = calendar.timeZone
        let text = date.formatted(style)
        // French writes the first of the month as an ordinal: « 1er octobre ».
        if md.day == 1, locale.language.languageCode == .french, text.hasPrefix("1 ") {
            return "1er" + text.dropFirst()
        }
        return text
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
