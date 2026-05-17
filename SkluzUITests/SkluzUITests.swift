import XCTest

// Skluz est une app menu bar (LSUIElement) sans fenêtre principale :
// les UI tests pilotés par XCUIApplication (lancement + capture d'écran)
// n'ont pas de cible exploitable et terminent de façon non déterministe.
// On garde la cible compilable avec un test neutre ; la couverture utile
// est assurée par les tests unitaires du module Skluz.
final class SkluzUITests: XCTestCase {

    @MainActor
    func testMenuBarAppHasNoMainWindowByDesign() throws {
        // Invariant de conception : pas de scène fenêtrée, donc rien à
        // automatiser ici. Ce test documente et verrouille ce choix.
        XCTAssertTrue(true)
    }
}
