import SwiftUI

/// Backlog.hu arculati tokenek — forrás: backlog_landing/docs/brand/tokens.json.
/// Elv: „Mérnöki Minimalizmus / Future Industrial” — sötét alapértelmezés,
/// neon sárga akcentus, Space Grotesk display, dobozokba rendezett tartalom.
enum Brand {
    // Színek (tokens.json → color)
    static let bgDeep = Color(hex: 0x030303)
    static let bgElev1 = Color(hex: 0x0A0A0A)
    static let bgElev2 = Color(hex: 0x111111)
    static let ink = Color(hex: 0x1A1A1A)
    static let fgMid = Color(hex: 0xD6D6D6)
    static let fgDim = Color(hex: 0xB3B3B3)
    static let grey = Color(hex: 0x888888)
    static let accent = Color(hex: 0xFFEB3B)   // Neon Yellow — sötét háttéren
    static let gold = Color(hex: 0xC7A008)     // Industrial Gold — világoson
    static let gridLine = Color.white.opacity(0.10)
    static let danger = Color(hex: 0xFF5347)

    // Sugarak (tokens.json → radius; sűrű felületen 6)
    static let radius: CGFloat = 6

    // Display-tipográfia: Space Grotesk (bundle-özött TTF-ek)
    enum DisplayWeight: String {
        case light = "SpaceGrotesk-Light"
        case regular = "SpaceGrotesk-Regular"
        case medium = "SpaceGrotesk-Medium"
        case semibold = "SpaceGrotesk-SemiBold"
        case bold = "SpaceGrotesk-Bold"
    }

    static func display(_ size: CGFloat, _ weight: DisplayWeight = .medium) -> Font {
        .custom(weight.rawValue, size: size)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - Újrafelhasználható arculati elemek

/// „Box logo”: fekete, lekerekített doboz, fehér felirat + sárga pont.
/// A doboz a brand-szabály szerint világos háttéren is fekete marad.
struct BrandWordmark: View {
    var size: CGFloat = 13

    var body: some View {
        HStack(spacing: 0) {
            Text("TUNTURIRUN")
                .font(Brand.display(size, .semibold))
                .tracking(1.5)
                .foregroundStyle(.white)
            Text(".")
                .font(Brand.display(size, .bold))
                .foregroundStyle(Brand.accent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Brand.ink, in: RoundedRectangle(cornerRadius: Brand.radius))
        .overlay(RoundedRectangle(cornerRadius: Brand.radius).stroke(Brand.gridLine))
        .fixedSize() // a zsúfolt toolbar ne csonkolja a wordmarkot
    }
}

/// Szekciócím („eyebrow”): nagybetűs, ritkított, szürke.
struct BrandEyebrow: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(Brand.display(11, .medium))
            .tracking(1.8)
            .foregroundStyle(Brand.grey)
    }
}

/// Tartalmi doboz: enyhén emelt háttér, 1px-es rácsvonal-keret.
struct BrandBox: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.bgElev1, in: RoundedRectangle(cornerRadius: Brand.radius))
            .overlay(RoundedRectangle(cornerRadius: Brand.radius).stroke(Brand.gridLine))
    }
}

extension View {
    func brandBox(padding: CGFloat = 16) -> some View {
        modifier(BrandBox(padding: padding))
    }
}

/// Fő CTA: neon sárga doboz, fekete, nagybetűs Space Grotesk felirat.
struct BrandCTAStyle: ButtonStyle {
    var fill: Color = Brand.accent
    var textColor: Color = Brand.ink

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Brand.display(14, .semibold))
            .tracking(1.5)
            .textCase(.uppercase)
            .foregroundStyle(textColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(fill, in: RoundedRectangle(cornerRadius: Brand.radius))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Másodlagos gomb: körvonalas („stroke”) stílus.
struct BrandStrokeStyle: ButtonStyle {
    var color: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Brand.display(14, .semibold))
            .tracking(1.5)
            .textCase(.uppercase)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Brand.bgElev1, in: RoundedRectangle(cornerRadius: Brand.radius))
            .overlay(RoundedRectangle(cornerRadius: Brand.radius)
                .stroke(color.opacity(0.35), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
