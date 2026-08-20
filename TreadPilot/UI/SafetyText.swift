import Foundation

/// Biztonságkritikus felhasználói szövegek egy helyen.
///
/// Ezek az utasítások testi épséget védenek, ezért MINDEN előfordulásukban
/// szó szerint azonosnak kell lenniük — ha képernyőnként külön literálként
/// élnének, előbb-utóbb szétcsúsznának (a lokalizáció során pontosan ez
/// történt: ugyanaz a mondat négy különböző angol változatban jelent meg).
/// Számított property, nem `let`: így nyelvváltás után is újraértékelődik.
enum Safety {

    /// Indítás előtti alaputasítás. A „not on the belt" tagmondat szándékos:
    /// a szalag magától indul, ezért nem elég a széleket említeni.
    static var standClear: String {
        String(localized: "Stand on the side rails, not on the belt, and clip on the safety key.")
    }
}
