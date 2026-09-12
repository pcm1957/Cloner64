import SwiftUI
import AppKit

// MARK: - Compact Sequence Panel
// A lightweight sequence view used in the GraphicalMapWindow split view.
// It intentionally omits save, find, translation, and print controls.
// For those, and for the full editing experience, use the dedicated Sequence Editor window.

struct CompactSequencePanel: View {
    @ObservedObject var sequence: DNASequence

    @State private var isLocked: Bool = true
    @State private var showFeatures: Bool = true
    @State private var selectedTab: PanelTab = .sequence
    @State private var sequenceFontSize: CGFloat = 12
    @State private var selectionStart: Int = 0
    @State private var selectionEnd: Int = 0
    @State private var dynamicBasesPerLine: Int = 40
    @State private var showLockedWarning: Bool = false
    @State private var featureCount: Int = 0

    enum PanelTab: String, CaseIterable {
        case sequence    = "Sequence"
        case comments    = "Comments"
        case extremities = "Extremities"
        case features    = "Features"
    }

    var body: some View {
        VStack(spacing: 0) {
            infoBanner
            Divider()
            controlsRow
            Divider()
            tabBar
            Divider()
            tabContent
        }
        .background(Color(.windowBackgroundColor))
        .alert("Sequence is Locked", isPresented: $showLockedWarning) {
            Button("OK") {}
        } message: {
            Text("Uncheck Locked to make edits.")
        }
        .onAppear {
            isLocked = true
            featureCount = sequence.features.count
        }
        .onChange(of: sequence.features.count) { newCount in
            featureCount = newCount
        }
        .onChange(of: sequence.id) { _ in
            selectionStart = 0
            selectionEnd = 0
            isLocked = true
        }
    }

    // MARK: - Info Banner

    private var infoBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .foregroundColor(.blue)
                .font(.system(size: 12))
            Text("Split view — basic editing only. For save, find, translation, and full tools, use the dedicated Sequence Editor window.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(.controlBackgroundColor))
    }

    // MARK: - Controls Row

    private var controlsRow: some View {
        HStack(spacing: 16) {
            Toggle(isOn: $isLocked) {
                Text("Locked")
                    .font(.system(size: 12))
            }
            .toggleStyle(.checkbox)

            Toggle(isOn: $showFeatures) {
                Text("Show features")
                    .font(.system(size: 12))
            }
            .toggleStyle(.checkbox)

            Spacer()

            HStack(spacing: 4) {
                Text("Font:")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Button(action: { sequenceFontSize = max(8, sequenceFontSize - 1) }) {
                    Image(systemName: "minus").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                Text("\(Int(sequenceFontSize))")
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 20)
                Button(action: { sequenceFontSize = min(24, sequenceFontSize + 1) }) {
                    Image(systemName: "plus").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(.windowBackgroundColor))
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(PanelTab.allCases, id: \.self) { tab in
                Button(action: { selectedTab = tab }) {
                    Text(tab.rawValue)
                        .font(.system(size: 12))
                        .fontWeight(selectedTab == tab ? .semibold : .regular)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(
                            selectedTab == tab
                                ? tabColor(for: tab)
                                : Color(.controlBackgroundColor)
                        )
                        .foregroundColor(selectedTab == tab ? .white : .primary)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.leading, 8)
        .padding(.top, 4)
        .background(Color(.windowBackgroundColor))
    }

    private func tabColor(for tab: PanelTab) -> Color {
        switch tab {
        case .sequence:    return .blue
        case .comments:    return .green
        case .extremities: return .orange
        case .features:    return .purple
        }
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .sequence:    sequenceTabContent
        case .comments:    commentsTabContent
        case .extremities: extremitiesTabContent
        case .features:    featuresTabContent
        }
    }

    // MARK: - Sequence Tab

    private var sequenceTabContent: some View {
        GeometryReader { geometry in
            let computed = computeBasesPerLine(availableWidth: geometry.size.width)
            ScrollView {
                SequenceTextView(
                    sequence: sequence,
                    features: showFeatures ? sequence.features : [],
                    featureCount: showFeatures ? featureCount : 0,
                    selectionStart: $selectionStart,
                    selectionEnd: $selectionEnd,
                    basesPerLine: computed,
                    isLocked: isLocked,
                    fontSize: sequenceFontSize,
                    showLockedWarning: $showLockedWarning,
                    highlightRanges: []
                )
                .padding(8)
            }
            .background(Color(.textBackgroundColor))
            .onAppear { dynamicBasesPerLine = computed }
            .onChange(of: geometry.size.width) { _ in
                dynamicBasesPerLine = computeBasesPerLine(availableWidth: geometry.size.width)
            }
            .onChange(of: sequenceFontSize) { _ in
                dynamicBasesPerLine = computeBasesPerLine(availableWidth: geometry.size.width)
            }
        }
    }

    private func computeBasesPerLine(availableWidth: CGFloat) -> Int {
        let lineNumberWidth: CGFloat = sequenceFontSize * 5 + 6
        let font = NSFont.monospacedSystemFont(ofSize: sequenceFontSize, weight: .regular)
        let charWidth = font.advancement(forGlyph: font.glyph(withName: "A")).width
        let groupSpaceWidth: CGFloat = 5.0
        let padding: CGFloat = 16
        let usable = availableWidth - lineNumberWidth - padding
        guard usable > 0 else { return 10 }
        let groupWidth = 10.0 * charWidth + groupSpaceWidth
        let numGroups = Int((usable + groupSpaceWidth) / groupWidth)
        return max(10, numGroups * 10)
    }

    // MARK: - Comments Tab

    private var commentsTabContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $sequence.description)
                .font(.system(.body, design: .monospaced))
                .padding(4)
                .disabled(isLocked)
            HStack {
                Spacer()
                Text("Characters: \(sequence.description.count)")
                    .font(.system(size: 11))
                    .foregroundColor(sequence.description.count > 255 ? .red : .secondary)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
        }
    }

    // MARK: - Extremities Tab (summary only)

    private var extremitiesTabContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if sequence.isCircular {
                Text("Circular sequence — no defined extremities.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .italic()
            } else {
                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("5′ end")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.secondary)
                        Text(sequence.cohesive5Prime.isEmpty
                             ? "Blunt"
                             : "Overhang: \(sequence.cohesive5Prime)")
                            .font(.system(size: 12, design: .monospaced))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("3′ end")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.secondary)
                        Text(sequence.cohesive3Prime.isEmpty
                             ? "Blunt"
                             : "Overhang: \(sequence.cohesive3Prime)")
                            .font(.system(size: 12, design: .monospaced))
                    }
                }
                Text("For full extremity editing, use the Sequence Editor window.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .italic()
            }
            Spacer()
        }
        .padding(12)
    }

    // MARK: - Features Tab

    private var featuresTabContent: some View {
        FeaturesTabView(
            sequence: sequence,
            isLocked: isLocked,
            selectionStart: $selectionStart,
            selectionEnd: $selectionEnd
        )
    }
}
