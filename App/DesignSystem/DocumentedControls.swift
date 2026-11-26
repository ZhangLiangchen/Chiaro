import ChiaroAppCore
import ChiaroCore
import SwiftUI

struct ParameterHelpButton: View {
    let parameterID: ParameterID
    let language: ResolvedLanguage
    private var isPresented = State(initialValue: false)

    var body: some View {
        Button {
            isPresented.wrappedValue.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(ParameterDocumentationRegistry.doc(for: parameterID).shortSummary.localized(for: language))
        .popover(isPresented: isPresented.projectedValue, arrowEdge: .leading) {
            ParameterDocPopoverView(
                doc: ParameterDocumentationRegistry.doc(for: parameterID),
                language: language
            )
        }
    }
}

struct ParameterDocPopoverView: View {
    let doc: ParameterDoc
    let language: ResolvedLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(doc.title.localized(for: language))
                    .font(.headline)
                Text(doc.shortSummary.localized(for: language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            docSection(
                label: ChiaroStrings.docControlsWhat(language),
                text: doc.controlsWhat.localized(for: language),
                icon: "slider.horizontal.3",
                tint: .accentColor
            )
            docSection(
                label: ChiaroStrings.docLeftEffect(language),
                text: doc.leftOrLowEffect.localized(for: language),
                icon: "arrow.left.circle",
                tint: .blue
            )
            docSection(
                label: ChiaroStrings.docRightEffect(language),
                text: doc.rightOrHighEffect.localized(for: language),
                icon: "arrow.right.circle",
                tint: .orange
            )
            docSection(
                label: ChiaroStrings.docRecommendedRange(language),
                text: doc.recommendedRange.localized(for: language),
                icon: "checkmark.seal",
                tint: .green
            )
            docSection(
                label: ChiaroStrings.docProTip(language),
                text: doc.proTip.localized(for: language),
                icon: "lightbulb.fill",
                tint: .yellow
            )
        }
        .padding(14)
        .frame(width: 340)
        .chiaroGlassSurface(cornerRadius: 12)
    }

    private func docSection(label: String, text: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(tint)
                Text(label)
                    .font(.caption.weight(.semibold))
            }
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct DocumentedSlider: View {
    let parameterID: ParameterID
    let language: ResolvedLanguage
    let showInlineSummary: Bool
    let value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    let format: String
    var displayOverrideText: String? = nil
    var onEditingChanged: ((Bool) -> Void)? = nil
    let onChange: (Double) -> Void

    private var doc: ParameterDoc {
        ParameterDocumentationRegistry.doc(for: parameterID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(doc.title.localized(for: language))
                    .font(.caption)
                ParameterHelpButton(parameterID: parameterID, language: language)
                Spacer()
                Text(displayOverrideText ?? String(format: format, value))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let step {
                Slider(
                    value: Binding(
                        get: { min(max(value, range.lowerBound), range.upperBound) },
                        set: { onChange($0) }
                    ),
                    in: range,
                    step: step,
                    onEditingChanged: { editing in
                        onEditingChanged?(editing)
                    }
                )
                .controlSize(.small)
            } else {
                Slider(
                    value: Binding(
                        get: { min(max(value, range.lowerBound), range.upperBound) },
                        set: { onChange($0) }
                    ),
                    in: range,
                    onEditingChanged: { editing in
                        onEditingChanged?(editing)
                    }
                )
                .controlSize(.small)
            }

            if showInlineSummary {
                Text(doc.shortSummary.localized(for: language))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct DocumentedPicker<SelectionValue: Hashable, Content: View>: View {
    let parameterID: ParameterID
    let language: ResolvedLanguage
    let showInlineSummary: Bool
    let selection: Binding<SelectionValue>
    var pickerStyleSegmented: Bool = false
    var pickerWidth: CGFloat? = nil
    @ViewBuilder let content: () -> Content

    private var doc: ParameterDoc {
        ParameterDocumentationRegistry.doc(for: parameterID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(doc.title.localized(for: language))
                    .font(.caption)
                ParameterHelpButton(parameterID: parameterID, language: language)
                Spacer()
                pickerView
            }

            if showInlineSummary {
                Text(doc.shortSummary.localized(for: language))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var pickerView: some View {
        if pickerStyleSegmented {
            Picker(doc.title.localized(for: language), selection: selection) {
                content()
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: pickerWidth)
        } else {
            Picker(doc.title.localized(for: language), selection: selection) {
                content()
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
        }
    }
}

struct DocumentedToggle: View {
    let parameterID: ParameterID
    let language: ResolvedLanguage
    let showInlineSummary: Bool
    let isOn: Binding<Bool>

    private var doc: ParameterDoc {
        ParameterDocumentationRegistry.doc(for: parameterID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Toggle(isOn: isOn) {
                    Text(doc.title.localized(for: language))
                        .font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                ParameterHelpButton(parameterID: parameterID, language: language)
            }

            if showInlineSummary {
                Text(doc.shortSummary.localized(for: language))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
