import XCTest
@testable import FlowPeekCore

/// The catalogue, and the one promise it has to keep: routing the existing look through it changes
/// nothing about what the existing look draws.
final class MermaidThemeCatalogueTests: XCTestCase {
    private let appearances: [MacMermaidTheme.Appearance] = [.light, .dark]
    private let contrasts = [false, true]

    /// The whole proof of the first step. If `.system` ever stops being byte-for-byte the theme the
    /// old initialiser built, every reader who has chosen nothing gets a different picture.
    func testTheSystemEntryIsExactlyWhatTheInitialiserBuilt() {
        for appearance in appearances {
            for increaseContrast in contrasts {
                let direct = MacMermaidTheme(
                    appearance: appearance, accentHex: "#0A84FF", increaseContrast: increaseContrast
                )
                let viaCatalogue = MermaidThemeCatalogue.theme(
                    .system, appearance: appearance, accentHex: "#0A84FF", increaseContrast: increaseContrast
                )
                XCTAssertEqual(direct, viaCatalogue, "\(appearance) contrast=\(increaseContrast)")
            }
        }
    }

    func testEveryThemeHasADescriptorAndTheyAreUnique() {
        let described = MermaidThemeCatalogue.all.map(\.id)
        XCTAssertEqual(Set(described).count, described.count, "a theme is listed twice")
        for id in MermaidThemeID.allCases {
            XCTAssertTrue(described.contains(id), "\(id) has no descriptor")
            XCTAssertEqual(MermaidThemeCatalogue.descriptor(id).id, id)
        }
    }

    /// The default is what a reader who has never chosen anything is shown, so calling it an
    /// experiment would be telling almost everybody they are in an experiment.
    func testTheFallbackIsNotExperimental() {
        XCTAssertFalse(MermaidThemeCatalogue.descriptor(.fallbackID).isExperimental)
    }

    /// A stored id comes from a defaults domain the reader can edit and an older build can have
    /// written. Every unreadable answer has to become the default rather than a crash.
    func testAnUnknownStoredIdDegradesToTheDefault() {
        XCTAssertEqual(MermaidThemeCatalogue.id(rawValue: nil), .system)
        XCTAssertEqual(MermaidThemeCatalogue.id(rawValue: ""), .system)
        XCTAssertEqual(MermaidThemeCatalogue.id(rawValue: "a-theme-from-a-later-build"), .system)
        XCTAssertEqual(MermaidThemeCatalogue.id(rawValue: "SYSTEM"), .system, "raw values are case sensitive")
        XCTAssertEqual(MermaidThemeCatalogue.id(rawValue: "system"), .system)
    }

    /// Persisted, so it may never be renamed on a whim.
    func testTheStoredSpellingOfEveryThemeIsPinned() {
        XCTAssertEqual(MermaidThemeID.system.rawValue, "system")
    }

    func testEveryDescriptorNamesKeysInBothCatalogues() {
        for descriptor in MermaidThemeCatalogue.all {
            XCTAssertFalse(descriptor.nameKey.isEmpty)
            XCTAssertFalse(descriptor.blurbKey.isEmpty)
            XCTAssertTrue(MermaidThemeCatalogue.localizationKeys.contains(descriptor.nameKey))
            XCTAssertTrue(MermaidThemeCatalogue.localizationKeys.contains(descriptor.blurbKey))
        }
    }
}

private extension MermaidThemeID {
    static var fallbackID: MermaidThemeID { MermaidThemeCatalogue.fallback }
}

/// The arrangement a theme asks mermaid for.
///
/// The decode test is the load-bearing one. `MermaidRenderPayload` is `Codable` and is decoded in
/// `MermaidRendererTests`, so a member that could only encode would take `Decodable` synthesis down
/// with it and stop the payload compiling at all. A round trip here is what keeps that honest.
final class MermaidArrangementTests: XCTestCase {
    func testAnEmptyArrangementSaysNothing() {
        XCTAssertTrue(MermaidArrangement.unset.isEmpty)
        XCTAssertTrue(MermaidArrangement().isEmpty)
        XCTAssertFalse(MermaidArrangement(nodeSpacing: 32).isEmpty)
    }

    func testItSurvivesARoundTrip() throws {
        let original = MermaidArrangement(
            nodeSpacing: 32, rankSpacing: 40, padding: 16,
            diagramPadding: 40, curve: "rounded", wrappingWidth: 160
        )
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(MermaidArrangement.self, from: data), original)
    }

    /// Every theme that predates arrangements must still encode to exactly what it did before, or
    /// the golden snapshots move for a reason that has nothing to do with how anything looks.
    func testAnEmptyArrangementEncodesToAnEmptyObject() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(data: try encoder.encode(MermaidArrangement.unset), encoding: .utf8)
        XCTAssertEqual(json, "{}")
    }

    func testTheSystemThemeAsksForNoArrangement() {
        for appearance in [MacMermaidTheme.Appearance.light, .dark] {
            let theme = MermaidThemeCatalogue.theme(
                .system, appearance: appearance, accentHex: "#0A84FF", increaseContrast: false
            )
            XCTAssertTrue(theme.arrangement.isEmpty, "\(appearance)")
        }
    }
}

/// A repainted label takes its colour from the theme, not from a constant.
final class ThemeLabelInkTests: XCTestCase {
    func testTheSystemThemeKeepsTheInkItAlwaysHad() {
        let theme = MermaidThemeCatalogue.theme(
            .system, appearance: .light, accentHex: "#0A84FF", increaseContrast: false
        )
        XCTAssertEqual(theme.darkInk, LabelContrast.darkInk)
        XCTAssertEqual(theme.lightInk, LabelContrast.lightInk)
    }

    func testInkingKeepsBothThresholdsAndTheSwitch() {
        let inked = LabelContrast.on.inked(dark: "#111111", light: "#EEEEEE")
        XCTAssertEqual(inked.darkInk, "#111111")
        XCTAssertEqual(inked.lightInk, "#EEEEEE")
        XCTAssertEqual(inked.ratio, LabelContrast.on.ratio)
        XCTAssertEqual(inked.floor, LabelContrast.on.floor)
        XCTAssertEqual(inked.enabled, LabelContrast.on.enabled)
        // And a reader who switched correction off stays switched off whatever the theme says.
        XCTAssertFalse(LabelContrast.off.inked(dark: "#111111", light: "#EEEEEE").enabled)
    }

    func testARequestCarriesTheThemesInkIntoThePayload() throws {
        let theme = MacMermaidTheme(
            appearance: .light,
            variables: [:],
            css: "",
            fontFamily: "X",
            arrangement: .unset,
            darkInk: "#123456",
            lightInk: "#ABCDEF"
        )
        let json = try MermaidRenderRequest(
            source: "flowchart TD\n A --> B", theme: theme, seed: "fp-seed", renderID: "fp-1"
        ).payloadJSON()
        XCTAssertTrue(json.contains("#123456"), "the theme's dark ink never reached the payload")
        XCTAssertTrue(json.contains("#ABCDEF"), "the theme's light ink never reached the payload")
    }
}

/// The editorial theme's own promises. Values, not appearances: what it looks like is Step 8's job
/// and needs eyes, but these are the claims that can be broken silently.
final class EditorialThemeTests: XCTestCase {
    private func theme(_ appearance: MacMermaidTheme.Appearance, contrast: Bool = false) -> MacMermaidTheme {
        MermaidThemeCatalogue.theme(
            .editorial, appearance: appearance, accentHex: "#FF00FF", increaseContrast: contrast
        )
    }

    /// The reader's accent is deliberately not spent here. `#FF00FF` above is a colour no token has,
    /// so if it appears anywhere the accent leaked in.
    func testTheReadersAccentNeverReachesTheDrawing() {
        for appearance in [MacMermaidTheme.Appearance.light, .dark] {
            let built = theme(appearance)
            for (key, value) in built.variables {
                XCTAssertFalse(value.uppercased().contains("FF00FF"), "\(key) took the reader's accent")
            }
            XCTAssertFalse(built.css.uppercased().contains("FF00FF"))
        }
    }

    /// The source reserves coral for the one or two things to look at first. A theme that painted
    /// every border with it would have turned the accent into the body colour.
    func testTheAccentIsNotSprayedOverTheStructure() {
        for appearance in [MacMermaidTheme.Appearance.light, .dark] {
            let accent = appearance == .dark ? "#F08A59" : "#EB6C36"
            let built = theme(appearance)
            for key in ["primaryBorderColor", "nodeBorder", "lineColor", "clusterBorder", "actorBorder"] {
                XCTAssertNotEqual(built.variables[key]?.uppercased(), accent, "\(key) is accent-coloured")
            }
        }
    }

    /// Every label has to clear the source's own Hangul floor, because Korean is first class here.
    func testNoTypeSizeIsBelowTheHangulFloor() {
        let built = theme(.light)
        XCTAssertEqual(built.variables["fontSize"], "12px")
        // And nothing in the stylesheet quietly sets something smaller.
        for match in built.css.ranges(of: try! Regex(#"font-size:\s*(\d+(?:\.\d+)?)px"#)) {
            let size = Double(built.css[match].replacingOccurrences(of: "font-size:", with: "")
                .replacingOccurrences(of: "px", with: "")
                .trimmingCharacters(in: .whitespaces)) ?? 99
            XCTAssertGreaterThanOrEqual(size, 12, "a rule sets type below the 12px Hangul floor")
        }
    }

    func testItAsksForGapsFromTheSourcesOwnRamp() {
        let allowed: Set<Int> = [20, 24, 32, 40, 48]
        let arrangement = theme(.light).arrangement
        XCTAssertTrue(allowed.contains(arrangement.nodeSpacing ?? -1))
        XCTAssertTrue(allowed.contains(arrangement.rankSpacing ?? -1))
        XCTAssertTrue(allowed.contains(arrangement.diagramPadding ?? -1))
        XCTAssertFalse(arrangement.isEmpty)
    }

    /// `look` is deliberately never set: it would replace the padding above with per-shape
    /// constants baked into mermaid's shape functions, which nothing can reach or override.
    func testItHoldsItsOwnPaddingRatherThanHandingItToALook() {
        XCTAssertEqual(theme(.light).arrangement.padding, 16)
    }

    func testLightAndDarkAreGenuinelyDifferentAndBothComplete() {
        let light = theme(.light), dark = theme(.dark)
        XCTAssertNotEqual(light.variables["background"], dark.variables["background"])
        XCTAssertNotEqual(light.variables["primaryTextColor"], dark.variables["primaryTextColor"])
        XCTAssertEqual(Set(light.variables.keys), Set(dark.variables.keys), "one appearance is missing a key")
        for (key, value) in light.variables {
            XCTAssertFalse(value.isEmpty, "\(key) is empty in light")
            XCTAssertFalse(dark.variables[key]!.isEmpty, "\(key) is empty in dark")
        }
    }

    /// A hairline at rest, the solid rule when the reader has asked for more contrast.
    func testIncreasedContrastStrengthensTheHairline() {
        for appearance in [MacMermaidTheme.Appearance.light, .dark] {
            let soft = theme(appearance).variables["nodeBorder"]!
            let strong = theme(appearance, contrast: true).variables["nodeBorder"]!
            XCTAssertTrue(soft.hasPrefix("rgba"), "the resting border should be a hairline")
            XCTAssertFalse(strong.hasPrefix("rgba"), "increased contrast should go solid")
        }
    }

    func testTheStoredSpellingIsPinned() {
        XCTAssertEqual(MermaidThemeID.editorial.rawValue, "editorial")
        XCTAssertTrue(MermaidThemeCatalogue.descriptor(.editorial).isExperimental)
    }
}
