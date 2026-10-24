import AppKit
import SwiftUI
import GlowroomCore

/// A small, synchronous validation boundary shared by numeric and slider input.
/// The caller publishes the complete returned settings through EditingModel once;
/// invalid endpoints retain the previous value instead of being normalized away.
enum LevelsUIParameter: String, CaseIterable, Identifiable {
    case inputBlack, inputWhite, gamma, outputBlack, outputWhite
    var id: String { rawValue }
    var title: String {
        switch self {
        case .inputBlack: "Eingang Schwarz"
        case .inputWhite: "Eingang Weiß"
        case .gamma: "Gamma"
        case .outputBlack: "Ausgang Schwarz"
        case .outputWhite: "Ausgang Weiß"
        }
    }
    var keyPath: WritableKeyPath<LevelsCurve, Double> {
        switch self {
        case .inputBlack: \.inputBlack
        case .inputWhite: \.inputWhite
        case .gamma: \.gamma
        case .outputBlack: \.outputBlack
        case .outputWhite: \.outputWhite
        }
    }
    var range: ClosedRange<Double> { self == .gamma ? LevelsCurve.gammaRange : LevelsCurve.parameterRange }
    var neutral: Double { LevelsCurve.neutral[keyPath: keyPath] }
    var step: Double { self == .gamma ? 0.01 : 0.0001 }
    var fractionDigits: Int { self == .gamma ? 3 : 4 }

    func applying(_ value: Double, channel: LevelsChannel, to settings: EditSettings) throws -> EditSettings {
        guard value.isFinite, range.contains(value) else { throw LevelsValidationError.invalidCurve }
        var result = settings
        result.levels[channel][keyPath: keyPath] = value
        try result.levels.validate()
        _ = try EditingSnapshot(settings: result)
        return result
    }

    /// Leave a Float ulp of margin for a dragged input endpoint. Existing valid
    /// endpoints remain reachable even when they occupy that rounding margin.
    /// This constant-size range calculation does not warrant parallel work.
    func sliderRange(for curve: LevelsCurve) -> ClosedRange<Double> {
        let margin = LevelsCurve.minimumInputSpan + Double(Float.ulpOfOne)
        switch self {
        case .inputBlack: return 0...max(curve.inputBlack, max(0, curve.inputWhite - margin))
        case .inputWhite: return min(curve.inputWhite, min(1, curve.inputBlack + margin))...1
        case .outputBlack: return 0...curve.outputWhite
        case .outputWhite: return curve.outputBlack...1
        case .gamma: return range
        }
    }
}

struct LevelsInspector: View {
    let assetID: String
    @ObservedObject var library: LibraryModel
    @ObservedObject var workspace: DevelopWorkspace
    @EnvironmentObject private var editor: EditingModel
    @ViewState private var selectedChannel: LevelsChannel = .master
    @ViewState private var expanded = true
    @ViewState private var validationMessage: String?
    @ViewState private var pickerMode: LevelsPickerMode = .setTone
    @StateObject private var numericInput = LevelsNumericInput()

    private var levels: LevelsSettings { editor.settings(for: assetID).levels }
    private var readOnly: Bool {
        !editor.canEdit || !library.canModify || library.selectedID != assetID ||
            library.comparesOriginal || library.comparesCurrentSourceWithoutSettings
    }
    private var pickerContextIsCurrent: Bool {
        guard !readOnly, library.isDeveloping, library.previewComparisonLayout == .single,
              let asset = library.selectedAsset, asset.id == assetID,
              let source = try? editor.resolvedSource(for: asset, intent: .currentEditing) else { return false }
        return source.identity == workspace.sourceIdentity
    }

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { expanded }, set: { value in
            if !value { finishInput(); workspace.endLevelsPicker() }
            expanded = value
        })) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Kanal")
                    LevelsChannelPicker(selection: Binding(get: { selectedChannel }, set: { channel in
                        finishInput(); workspace.endLevelsPicker(); selectedChannel = channel; validationMessage = nil
                    }), titles: LevelsChannel.allCases.map { title($0) + (levels[$0].isNeutral ? "" : " •") })
                }.font(.system(size: 11))
                if !otherActiveChannels.isEmpty {
                    Text("Weitere aktive Kanäle: " + otherActiveChannels.map(title).joined(separator: ", "))
                        .font(.system(size: 10)).foregroundStyle(Theme.accent)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("develop.levels.other-active-channels")
                }
                Button {
                    finishInput()
                    let selection = DevelopSelectionIdentity(sessionID: library.aiSelectionSessionID,
                                                            generation: library.aiSelectionGeneration)
                    workspace.applyAutomaticLevels(assetID: assetID, editor: editor, selection: selection,
                        isCurrent: {
                            pickerContextIsCurrent && selection.matches(library)
                        })
                } label: {
                    HStack(spacing: 6) {
                        Text("Tonwertbereich automatisch")
                        if workspace.automaticLevelsBusy { ProgressView().controlSize(.mini) }
                    }
                }
                .accessibilityIdentifier("develop.levels.automatic")
                .help("Ersetzt alle Levels: gemeinsame Eingangsgrenzen, Gamma 1 und Ausgang 0–1; Rot, Grün, Blau und alle Begrenzungen werden zurückgesetzt. Andere Bearbeitungen bleiben erhalten. Nur bei einem sicheren SDR-Vorschlag.")
                pickerControls
                ForEach(LevelsUIParameter.allCases) { parameter in
                    parameterRow(parameter, channel: selectedChannel)
                }
                Toggle("Eingang auf 0–1 begrenzen", isOn: clampBinding(\.clampInput))
                    .help("Begrenzt den normalisierten Eingang vor Gamma. Ausgeschaltet bleiben Werte außerhalb des Eingangsbereichs erhalten.")
                    .accessibilityIdentifier("develop.levels.clamp-input")
                Toggle("Ausgang auf 0–1 begrenzen", isOn: clampBinding(\.clampOutput))
                    .help("Begrenzt das Ergebnis dieses Kanals nach Gamma und Ausgangsabbildung.")
                    .accessibilityIdentifier("develop.levels.clamp-output")
                HStack {
                    Button("Kanal zurücksetzen") { atomicChange { $0[selectedChannel] = .neutral } }
                        .disabled(levels[selectedChannel].isNeutral && !numericInput.hasPendingChanges)
                        .accessibilityIdentifier("develop.levels.reset-channel")
                    Spacer(minLength: 4)
                    Button("Alle zurücksetzen") {
                        atomicChange {
                            $0.master = .neutral; $0.red = .neutral; $0.green = .neutral; $0.blue = .neutral
                        }
                    }.disabled(levels.isNeutral && !numericInput.hasPendingChanges).accessibilityIdentifier("develop.levels.reset-all")
                }.buttonStyle(.plain).foregroundStyle(Theme.accent).padding(.top, 3)
                Text("Gamma über 1 hellt Mitteltöne auf. RGB gemeinsam folgt den Einzelkanälen und kann den Farbton verändern. Beide Begrenzungen sind standardmäßig aus.")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if let validationMessage {
                    Text(validationMessage).font(.system(size: 10)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("develop.levels.validation")
                }
                if let error = workspace.errorMessage {
                    Text(error).font(.system(size: 10)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("develop.levels.picker-message")
                }
                if let description = workspace.levelsSampleDescription {
                    Text(description).font(.system(size: 10)).foregroundStyle(Theme.muted)
                }
            }.font(.system(size: 10)).toggleStyle(.checkbox).controlSize(.mini)
                .padding(.top, 5).disabled(readOnly)
        } label: {
            Text("Tonwertkorrektur").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted)
                // A group identifier is inherited by SwiftUI's virtual AX
                // children and would replace their individual control IDs.
                .accessibilityIdentifier("develop.levels")
        }
        .padding(.vertical, 6)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        .onDisappear { finishInput(); workspace.endLevelsPicker() }
        .onChange(of: readOnly) { _, value in if value { workspace.endLevelsPicker() } }
        .onChange(of: editor.localRevision(for: assetID)) { _, _ in workspace.endLevelsPicker() }
    }

    private var pickerControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            Picker("Pipettenmodus", selection: Binding(get: { pickerMode }, set: {
                finishInput(); workspace.endLevelsPicker(); pickerMode = $0
            })) {
                Text("Tonwert setzen").tag(LevelsPickerMode.setTone)
                Text("RGB neutralisieren").tag(LevelsPickerMode.neutralizeRGB)
            }.pickerStyle(.segmented).accessibilityIdentifier("develop.levels.picker-mode")
            if pickerMode == .neutralizeRGB {
                Text("Ändert Rot, Grün und Blau gemeinsam. Zusätzlich wird nur der passende gemeinsame Parameter neutralisiert: Schwarz → 0, Weiß → 1 oder Gamma → 1. Andere Parameter bleiben erhalten; unterschiedliche RGB-Ausgangsgrenzen werden abgelehnt.")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach([LevelsPickerPoint.black, .gray, .white], id: \.self) { point in
                let picker = DevelopLevelsPickerSelection(point: point, mode: pickerMode, channel: selectedChannel)
                Button {
                    finishInput()
                    if workspace.levelsPicker == picker { workspace.endLevelsPicker() }
                    else {
                        workspace.beginLevelsPicker(picker, assetID: assetID, editor: editor,
                            selection: DevelopSelectionIdentity(sessionID: library.aiSelectionSessionID,
                                                                generation: library.aiSelectionGeneration),
                            isCurrent: pickerContextIsCurrent)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "eyedropper")
                        Text(point == .black ? "Schwarzpunkt setzen" : point == .gray ? "Mittelton auf 50 % setzen" : "Weißpunkt setzen")
                        Spacer(minLength: 0)
                        if workspace.levelsPicker == picker { Text("Aktiv · Esc") }
                    }
                }.buttonStyle(.plain).foregroundStyle(workspace.levelsPicker == picker ? Theme.accent : Theme.text)
                    .accessibilityIdentifier("develop.levels.pick-\(point.rawValue)")
            }
            Text("5 × 5 Pixel der angezeigten Eingangsauflösung; am Rand beschnitten. Gemessen wird vor Levels. Nachfolgende Looks bleiben aktiv. RGB gemeinsam verwendet den größten Kanalwert und verspricht keine neutrale Farbe.")
                .font(.system(size: 10)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 4)
    }

    private var otherActiveChannels: [LevelsChannel] {
        LevelsChannel.allCases.filter { $0 != selectedChannel && !levels[$0].isNeutral }
    }
    private func title(_ channel: LevelsChannel) -> String {
        switch channel { case .master: "RGB gemeinsam"; case .red: "Rot"; case .green: "Grün"; case .blue: "Blau" }
    }

    private func parameterRow(_ parameter: LevelsUIParameter, channel: LevelsChannel) -> some View {
        let value = Binding<Double>(get: { editor.settings(for: assetID).levels[channel][keyPath: parameter.keyPath] }, set: { amount in
            guard !readOnly else { return }
            do {
                let next = try parameter.applying(amount, channel: channel, to: editor.settings(for: assetID))
                publish(next); validationMessage = nil
            } catch { validationMessage = "Ungültige Tonwertgrenzen. Der letzte gültige Wert bleibt erhalten; der Eingangsabstand muss mindestens 0,0001 betragen." }
        })
        return LevelsParameterRow(parameter: parameter, value: value,
            sliderRange: parameter.sliderRange(for: levels[channel]),
            numericInput: numericInput, onEditingChanged: editingChanged, onInvalidNumber: {
                validationMessage = "Bitte eine endliche Zahl im erlaubten Bereich eingeben. Der letzte gültige Wert bleibt erhalten."
            })
            .id("\(channel.rawValue)-\(parameter.rawValue)")
    }

    private func clampBinding(_ keyPath: WritableKeyPath<LevelsCurve, Bool>) -> Binding<Bool> {
        Binding(get: { editor.settings(for: assetID).levels[selectedChannel][keyPath: keyPath] }, set: { enabled in
            atomicChange { $0[selectedChannel][keyPath: keyPath] = enabled }
        })
    }
    private func atomicChange(_ change: (inout LevelsSettings) -> Void) {
        guard !readOnly else { return }
        finishInput()
        var next = editor.settings(for: assetID)
        change(&next.levels)
        do {
            try next.levels.validate(); _ = try EditingSnapshot(settings: next)
            publish(next); validationMessage = nil
        } catch { validationMessage = "Die Tonwertkorrektur ist ungültig. Der bisherige Stand bleibt erhalten." }
    }
    private func publish(_ settings: EditSettings) {
        guard !readOnly else { return }
        workspace.endLevelsPicker()
        editor.selectEditingFunction(.adjustments, assetID: assetID, cancelsActiveInput: false)
        editor.setSettings(settings, for: assetID)
    }
    private func editingChanged(_ editing: Bool) {
        if editing {
            guard !readOnly else { return }
            editor.selectEditingFunction(.adjustments, assetID: assetID, cancelsActiveInput: false)
            editor.beginEditing(assetID: assetID)
        } else { editor.endEditing(assetID: assetID) }
    }
    private func finishInput() {
        // Consume the draft before changing channel/resetting; SwiftUI focus
        // notifications can otherwise arrive after those state mutations.
        numericInput.commit()
        NSApp.keyWindow?.makeFirstResponder(nil)
        ResettableNativeSlider.cancelInputs(in: NSApp.keyWindow?.contentView)
        editor.endEditing(assetID: assetID)
    }
}

/// Keep the compact channel menu on the same native-control boundary as the
/// numeric fields. Target/action commits their ordered draft before changing
/// the typed selection; programmatic view updates never send that action.
private struct LevelsChannelPicker: NSViewRepresentable {
    @Binding var selection: LevelsChannel
    let titles: [String]
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .mini
        button.font = .systemFont(ofSize: 11)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setAccessibilityLabel("Kanal")
        button.setAccessibilityIdentifier("develop.levels.channel")
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        updateNSView(button, context: context)
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        if button.numberOfItems != titles.count {
            button.removeAllItems()
            button.addItems(withTitles: titles)
        } else {
            for (index, title) in titles.enumerated() { button.item(at: index)?.title = title }
        }
        button.selectItem(at: LevelsChannel.allCases.firstIndex(of: selection)!)
        button.isEnabled = isEnabled
    }
    static func dismantleNSView(_ button: NSPopUpButton, coordinator: Coordinator) {
        coordinator.active = false
        button.target = nil
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: LevelsChannelPicker
        var active = true
        init(_ parent: LevelsChannelPicker) { self.parent = parent }
        @objc func changed(_ button: NSPopUpButton) {
            guard active, button.isEnabled, LevelsChannel.allCases.indices.contains(button.indexOfSelectedItem) else { return }
            parent.selection = LevelsChannel.allCases[button.indexOfSelectedItem]
        }
    }
}

private struct LevelsParameterRow: View {
    let parameter: LevelsUIParameter
    @Binding var value: Double
    let sliderRange: ClosedRange<Double>
    let numericInput: LevelsNumericInput
    let onEditingChanged: (Bool) -> Void
    let onInvalidNumber: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 6) {
            Text(parameter.title).font(.system(size: 10)).foregroundStyle(Theme.muted)
                .frame(width: 78, alignment: .trailing).lineLimit(1).minimumScaleFactor(0.8)
                .onTapGesture(count: 2) {
                    guard isEnabled else { return }
                    numericInput.commit()
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    ResettableNativeSlider.cancelInputs(in: NSApp.keyWindow?.contentView)
                    onEditingChanged(false); onEditingChanged(true)
                    value = parameter.neutral; onEditingChanged(false)
                }.help("Doppelklick setzt diesen Wert zurück")
            ResettableSlider(value: $value, in: sliderRange, step: parameter.step,
                neutralValue: parameter.neutral, onEditingChanged: { editing in
                    if editing {
                        numericInput.commit()
                        NSApp.keyWindow?.makeFirstResponder(nil)
                    }
                    onEditingChanged(editing)
                })
                .controlSize(.mini).accessibilityLabel(parameter.title)
                .accessibilityIdentifier("develop.levels.\(parameter.rawValue).slider")
            LevelsNumericField(parameter: parameter, value: $value, input: numericInput,
                onEditingChanged: onEditingChanged, onInvalidNumber: onInvalidNumber)
                .frame(width: 54)
                .accessibilityLabel("\(parameter.title) Wert")
                .accessibilityIdentifier("develop.levels.\(parameter.rawValue).value")
                .help("Mit Eingabetaste oder beim Verlassen übernehmen")
        }.frame(minHeight: 20)
    }
}

/// One ordered draft belongs to the inspector, rather than to disappearing
/// channel rows. Native callbacks update its text synchronously; a channel or
/// reset action consumes the draft before any delayed end-editing callback.
@MainActor
final class LevelsNumericInput: ObservableObject {
    /// A dirty native draft is actionable even while its persisted curve is
    /// neutral: reset first accepts that draft, then creates its own undo step.
    @Published private(set) var hasPendingChanges = false
    private struct Draft {
        let id: UUID
        let baseline: Double
        let baselineText: String
        var text: String
        var hasEditingGroup = false
        let readValue: () -> Double?
        let publish: (Double) -> Void
        let editingChanged: (Bool) -> Void
        let invalid: () -> Void
    }
    private var draft: Draft?

    func isActive(_ id: UUID) -> Bool { draft?.id == id }
    func begin(id: UUID, value: Double, display: String, readValue: @escaping () -> Double?,
               publish: @escaping (Double) -> Void, editingChanged: @escaping (Bool) -> Void,
               invalid: @escaping () -> Void) {
        guard draft?.id != id else { return }
        commit()
        draft = Draft(id: id, baseline: value, baselineText: display, text: display,
                      readValue: readValue, publish: publish, editingChanged: editingChanged, invalid: invalid)
    }
    func change(id: UUID, text: String) {
        guard var current = draft, current.id == id else { return }
        current.text = text
        hasPendingChanges = text != current.baselineText
        let begins = !current.hasEditingGroup && text != current.baselineText
        if begins { current.hasEditingGroup = true }
        draft = current
        if begins { current.editingChanged(true) }
    }
    func commit(id: UUID? = nil) {
        guard let current = draft, id == nil || current.id == id else { return }
        // Retire first: publishing may synchronously rebuild a row or trigger
        // a native end-editing callback. Neither may replay a consumed draft.
        draft = nil
        hasPendingChanges = false
        defer { if current.hasEditingGroup { current.editingChanged(false) } }
        guard current.text != current.baselineText, current.readValue() == current.baseline else { return }
        let text = current.text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard let number = Double(text), number.isFinite else { current.invalid(); return }
        current.publish(number)
    }
}

/// Native text delegates establish a synchronous boundary before the inspector
/// switches channel or resets. Only dirty text publishes a settings transaction.
private struct LevelsNumericField: NSViewRepresentable {
    let parameter: LevelsUIParameter
    @Binding var value: Double
    let input: LevelsNumericInput
    let onEditingChanged: (Bool) -> Void
    let onInvalidNumber: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false; field.drawsBackground = false
        field.alignment = .right; field.focusRingType = .none
        field.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        context.coordinator.field = field
        field.delegate = context.coordinator
        field.target = context.coordinator; field.action = #selector(Coordinator.submit(_:))
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        updateNSView(field, context: context)
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.isEnabled = isEnabled
        field.textColor = value == parameter.neutral ? .secondaryLabelColor : .controlAccentColor
        field.setAccessibilityLabel("\(parameter.title) Wert")
        field.setAccessibilityIdentifier("develop.levels.\(parameter.rawValue).value")
        if !input.isActive(context.coordinator.id) { field.stringValue = display(value) }
        if !isEnabled { context.coordinator.commit(field) }
    }
    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.dismantle(field)
    }
    private func display(_ value: Double) -> String { String(format: "%.*f", parameter.fractionDigits, value) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        private enum Lifecycle { case idle, editing, dismantled }
        var parent: LevelsNumericField
        let id = UUID()
        weak var field: NSTextField?
        private var lifecycle = Lifecycle.idle
        init(_ parent: LevelsNumericField) { self.parent = parent }
        private func begin() {
            parent.input.begin(id: id, value: parent.value, display: parent.display(parent.value),
                readValue: { [weak self] in self?.parent.value }, publish: { [weak self] in self?.parent.value = $0 },
                editingChanged: { [weak self] in self?.parent.onEditingChanged($0) },
                invalid: { [weak self] in self?.parent.onInvalidNumber() })
        }
        private func editingField(_ notification: Notification) -> NSTextField? {
            guard lifecycle != .dismantled, let field = notification.object as? NSTextField,
                  field === self.field else { return nil }
            return field
        }
        private func ownsCurrentEditor(_ field: NSTextField) -> Bool {
            guard lifecycle != .dismantled, field.isEnabled,
                  field.delegate as AnyObject? === self,
                  let window = field.window, let editor = field.currentEditor(),
                  window.firstResponder === editor else { return false }
            return true
        }
        func controlTextDidBeginEditing(_ notification: Notification) {
            guard lifecycle == .idle, let field = editingField(notification), ownsCurrentEditor(field) else { return }
            lifecycle = .editing
            begin()
        }
        func controlTextDidChange(_ notification: Notification) {
            // A changed-text notification cannot authorize a new session. A
            // reset may have consumed this draft while AppKit still has queued
            // callbacks; reopening it could flush a newer field's draft.
            guard lifecycle == .editing, parent.input.isActive(id),
                  let field = editingField(notification), ownsCurrentEditor(field) else { return }
            parent.input.change(id: id, text: field.currentEditor()?.string ?? field.stringValue)
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            guard lifecycle == .editing, let field = editingField(notification) else { return }
            lifecycle = .idle
            commit(field)
        }
        @objc func submit(_ field: NSTextField) {
            // A reset/channel boundary may already have consumed this draft.
            // A delayed action must not reopen it or flush another field.
            guard lifecycle == .editing, parent.input.isActive(id),
                  field === self.field, ownsCurrentEditor(field) else { return }
            commit(field)
            // Return can keep AppKit's field editor attached. Start a clean
            // baseline for the next real edit, with a separate undo group.
            if lifecycle == .editing, ownsCurrentEditor(field) { begin() }
        }
        func commit(_ field: NSTextField) {
            parent.input.commit(id: id)
            let text = parent.display(parent.value)
            field.stringValue = text
            if ownsCurrentEditor(field) { field.currentEditor()?.string = text }
        }
        func dismantle(_ field: NSTextField) {
            lifecycle = .dismantled
            commit(field)
            field.delegate = nil; self.field = nil
        }
    }
}
