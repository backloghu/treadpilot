import SwiftUI

/// Első indításkor kötelezően megjelenő biztonsági tájékoztató.
/// Az app valódi futópadot vezérel — enélkül nem engedjük tovább.
struct DisclaimerView: View {
    let onAccept: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BrandWordmark()
                    .padding(.top, 24)

                BrandEyebrow("Biztonsági tudnivalók")
                Text("Ez az app valódi futópadot vezérel")
                    .font(Brand.display(24, .bold))
                    .foregroundStyle(.white)

                VStack(alignment: .leading, spacing: 12) {
                    bullet("A parancsokra a szalag ténylegesen elindul, gyorsul és emelkedik — "
                           + "minden indítás és sebességváltás előtt állj stabilan.")
                    bullet("Használat előtt mindig csíptesd fel a futópad biztonsági kulcsát.")
                    bullet("Kapcsolatvesztéskor a szalag az utolsó beállított sebességgel "
                           + "mehet tovább — vészhelyzetben a pad saját Stop gombja és a "
                           + "biztonsági kulcs az elsődleges védelem.")
                    bullet("Ne engedd, hogy gyermek felügyelet nélkül használja az appot "
                           + "vagy a futópadot.")
                    bullet("Az alkalmazást saját felelősségedre használod. Egészségügyi "
                           + "panasz esetén edzés előtt konzultálj orvossal.")
                }
                .brandBox()

                Button {
                    onAccept()
                } label: {
                    Text("MEGÉRTETTEM ÉS ELFOGADOM").tracking(1.5)
                }
                .buttonStyle(BrandCTAStyle())
            }
            .padding(20)
        }
        .background(Brand.bgDeep)
        .preferredColorScheme(.dark)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("■")
                .font(.system(size: 8))
                .foregroundStyle(Brand.accent)
                .padding(.top, 5)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Brand.fgMid)
        }
    }
}
