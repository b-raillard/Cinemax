import Testing
import Foundation
@testable import Cinemax

/// Verrouille l'apparence des sous-titres sur le chemin VLC (#162).
///
/// La propriété load-bearing est la PREMIÈRE : tant que l'utilisateur n'a rien
/// changé, aucun argument n'est émis. C'est elle qui permet au lecteur de
/// continuer à utiliser `VLCInstance.shared` — une instance dédiée coûte un scan
/// des plugins ET un second abonnement au flux de journal — donc la
/// fonctionnalité ne coûte rien du tout à qui n'ouvre jamais le réglage.
@Suite("Apparence des sous-titres")
struct SubtitleStyleOptionsTests {

    private func argument(_ name: String, in arguments: [String]) -> String? {
        arguments.first { $0.hasPrefix("--\(name)=") }?
            .split(separator: "=", maxSplits: 1).last
            .map(String.init)
    }

    // MARK: - La propriété qui porte tout

    @Test("Configuration par défaut : AUCUN argument")
    func defaultEmitsNothing() {
        #expect(SubtitleStyleOptions.engineDefault.isEngineDefault)
        #expect(SubtitleStyleOptions.engineDefault.libVLCArguments.isEmpty)
    }

    @Test("Le moindre changement suffit à émettre la couleur et les trois opacités")
    func anyChangeEmitsTheBaseline() {
        var style = SubtitleStyleOptions.engineDefault
        style.color = .yellow
        let arguments = style.libVLCArguments
        #expect(arguments.isEmpty == false)
        #expect(argument("freetype-color", in: arguments) == "16776960")   // 0xFFFF00
        // Le texte reste pleinement opaque : les choix de l'utilisateur ne
        // déplacent que le contour et le cadre.
        #expect(argument("freetype-opacity", in: arguments) == "255")
        #expect(argument("freetype-outline-opacity", in: arguments) == "255")
        #expect(argument("freetype-background-opacity", in: arguments) == "0")
    }

    // MARK: - Couleurs

    @Test("Les trois couleurs valent bien leur RGB")
    func colourValues() {
        #expect(SubtitleColorOption.white.rgb == 0xFF_FF_FF)
        #expect(SubtitleColorOption.yellow.rgb == 0xFF_FF_00)
        #expect(SubtitleColorOption.cyan.rgb == 0x00_FF_FF)
        // Décimal, pas hexadécimal : l'item de configuration est un entier, et
        // un littéral décimal ne peut pas être mal lu par l'analyseur
        // d'arguments comme le serait un `FFFF00` nu.
        var style = SubtitleStyleOptions.engineDefault
        style.color = .cyan
        #expect(argument("freetype-color", in: style.libVLCArguments) == "65535")
    }

    // MARK: - Contour

    @Test("Contour désactivé : opacité à 0, ET l'épaisseur est envoyée")
    func outlineOff() {
        var style = SubtitleStyleOptions.engineDefault
        style.outline = .none
        let arguments = style.libVLCArguments
        // C'est l'opacité qui porte le comportement on/off — les entiers
        // d'épaisseur sont la seule chose que le binaire ne m'a pas donnée, donc
        // ils ne sont qu'un raffinement par-dessus.
        #expect(argument("freetype-outline-opacity", in: arguments) == "0")
        #expect(argument("freetype-outline-thickness", in: arguments) == "0")
    }

    @Test("Contour normal : aucune épaisseur envoyée, on laisse le défaut du moteur")
    func outlineNormalSendsNoThickness() {
        var style = SubtitleStyleOptions.engineDefault
        style.background = .opaque        // pour sortir du défaut
        let arguments = style.libVLCArguments
        #expect(arguments.contains { $0.hasPrefix("--freetype-outline-thickness=") } == false)
        #expect(argument("freetype-outline-opacity", in: arguments) == "255")
    }

    @Test("Contour épais : opacité pleine et épaisseur supérieure à la normale")
    func outlineThick() {
        var style = SubtitleStyleOptions.engineDefault
        style.outline = .thick
        let arguments = style.libVLCArguments
        #expect(argument("freetype-outline-opacity", in: arguments) == "255")
        #expect(SubtitleOutlineOption.thick.thickness > SubtitleOutlineOption.normal.thickness)
        #expect(argument("freetype-outline-thickness", in: arguments) == "6")
    }

    // MARK: - Cadre

    @Test("Sans cadre : opacité 0 et AUCUNE couleur de fond envoyée")
    func backgroundNone() {
        var style = SubtitleStyleOptions.engineDefault
        style.color = .yellow
        let arguments = style.libVLCArguments
        #expect(argument("freetype-background-opacity", in: arguments) == "0")
        #expect(arguments.contains { $0.hasPrefix("--freetype-background-color=") } == false)
    }

    @Test("Cadre demandé : toujours noir, jamais coloré")
    func backgroundIsAlwaysBlack() {
        for option in [SubtitleBackgroundOption.translucent, .opaque] {
            var style = SubtitleStyleOptions.engineDefault
            style.background = option
            let arguments = style.libVLCArguments
            #expect(argument("freetype-background-opacity", in: arguments) == String(option.opacity))
            // Un cadre coloré derrière un texte coloré est un piège de
            // lisibilité, pas un choix.
            #expect(argument("freetype-background-color", in: arguments) == "0")
        }
        #expect(SubtitleBackgroundOption.translucent.opacity < SubtitleBackgroundOption.opaque.opacity)
    }

    // MARK: - Lecture des préférences

    @Test("Une valeur absente ou inconnue retombe sur le défaut du moteur")
    func unknownStoredValuesFallBack() throws {
        let defaults = try #require(UserDefaults(suiteName: "SubtitleStyleOptionsTests.unknown"))
        defaults.removePersistentDomain(forName: "SubtitleStyleOptionsTests.unknown")
        // Rien de stocké.
        #expect(SubtitleStyleOptions.current(defaults: defaults) == .engineDefault)
        // Stocké mais illisible : ne doit jamais faire échouer la lecture.
        defaults.set("chartreuse", forKey: SettingsKey.subtitleColor)
        defaults.set("gras", forKey: SettingsKey.subtitleOutline)
        defaults.set("", forKey: SettingsKey.subtitleBackground)
        #expect(SubtitleStyleOptions.current(defaults: defaults) == .engineDefault)
        defaults.removePersistentDomain(forName: "SubtitleStyleOptionsTests.unknown")
    }

    @Test("Des valeurs stockées valides sont relues telles quelles")
    func storedValuesAreRead() throws {
        let suite = "SubtitleStyleOptionsTests.stored"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(SubtitleColorOption.yellow.rawValue, forKey: SettingsKey.subtitleColor)
        defaults.set(SubtitleOutlineOption.thick.rawValue, forKey: SettingsKey.subtitleOutline)
        defaults.set(SubtitleBackgroundOption.translucent.rawValue, forKey: SettingsKey.subtitleBackground)
        let style = SubtitleStyleOptions.current(defaults: defaults)
        #expect(style.color == .yellow)
        #expect(style.outline == .thick)
        #expect(style.background == .translucent)
        #expect(style.isEngineDefault == false)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test("Les défauts stockés décrivent exactement le défaut du moteur")
    func storedDefaultsMatchTheEngineDefault() {
        // Sans cette égalité, une installation neuve passerait des arguments à
        // libVLC pour rien — et paierait le scan des plugins d'une instance
        // dédiée sans que personne n'ait rien demandé.
        #expect(SettingsKey.Default.subtitleColor == SubtitleColorOption.white.rawValue)
        #expect(SettingsKey.Default.subtitleOutline == SubtitleOutlineOption.normal.rawValue)
        #expect(SettingsKey.Default.subtitleBackground == SubtitleBackgroundOption.none.rawValue)
    }
}
