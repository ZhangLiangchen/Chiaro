import ChiaroAppCore
import SwiftUI

struct PublishingGuideView: View {
    var language: ResolvedLanguage = .zhHans
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let cards = ChiaroStrings.guideCards(lang: language)
        let tints: [Color] = [.blue, .pink, .orange]
        let icons = ["airplayaudio", "sparkles.rectangle.stack", "video.badge.checkmark"]

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ChiaroStrings.guideTitle(language))
                        .font(.title2.bold())
                    Text(ChiaroStrings.guideSubtitle(language))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(ChiaroStrings.guideDoneButton(language)) {
                    dismiss()
                }
                .chiaroGlassButtonStyle(prominent: true)
                .keyboardShortcut(.defaultAction)
            }

            ScrollView {
                ChiaroGlassContainer(spacing: 14) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(cards.enumerated()), id: \.offset) { index, card in
                            guideCard(
                                icon: icons[index % icons.count],
                                tint: tints[index % tints.count],
                                title: card.title,
                                summary: card.summary,
                                dos: card.dos,
                                donts: card.donts
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(18)
        .frame(minWidth: 720, minHeight: 540)
    }

    private func guideCard(
        icon: String,
        tint: Color,
        title: String,
        summary: String,
        dos: [String],
        donts: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.headline)
            }

            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(dos, id: \.self) { line in
                    HStack(alignment: .top, spacing: 6) {
                        Text("✅")
                        Text(line)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(donts, id: \.self) { line in
                    HStack(alignment: .top, spacing: 6) {
                        Text("⛔️")
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .chiaroGlassSurface(cornerRadius: 10, tint: tint.opacity(0.14))
    }
}
