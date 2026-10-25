import SwiftUI
import GlowroomCore

// The alias avoids SwiftUI macro discovery on CLT-only installations, matching
// the application's ViewState convention.
private typealias CurveGestureState<Value> = SwiftUI.GestureState<Value>

enum ToneCurvePointEditing {
    static func moving(_ curve: ToneCurve, at position: Int, x: Double, y: Double, clamped: Bool) throws -> ToneCurve {
        guard curve.points.indices.contains(position), x.isFinite, y.isFinite else { throw ToneCurveValidationError.invalidPoints }
        var candidate = curve
        let first = position == 0, last = position == candidate.points.count - 1
        var minX = first ? 0 : candidate.points[position - 1].x + ToneCurve.minimumPointSpacing
        var maxX = last ? 1 : candidate.points[position + 1].x - ToneCurve.minimumPointSpacing
        if !first, minX - candidate.points[position - 1].x < ToneCurve.minimumPointSpacing { minX = minX.nextUp }
        if !last, candidate.points[position + 1].x - maxX < ToneCurve.minimumPointSpacing { maxX = maxX.nextDown }
        let minY = first ? 0 : candidate.points[position - 1].y
        let maxY = last ? 1 : candidate.points[position + 1].y
        candidate.points[position] = .init(x: first ? 0 : (last ? 1 : (clamped ? min(max(x, minX), maxX) : x)),
                                            y: clamped ? min(max(y, minY), maxY) : y)
        try candidate.validate()
        return candidate
    }
}

/// Global curve editing publishes only validated complete settings. A parent
/// supplies the existing editing transaction boundaries for a whole drag.
struct ToneCurveEditor: View {
    @Binding var settings: ToneCurveSettings
    var onEditingChanged: (Bool) -> Void = { _ in }
    @ViewState private var channel: LevelsChannel = .master
    @ViewState private var selected = 0
    @ViewState private var isDragging = false
    @ViewState private var xText = "0.000"
    @ViewState private var yText = "0.000"
    @ViewState private var message: String?
    @ViewState private var coordinateBaseline: ToneCurveSettings?
    @ViewState private var dragExpectedSettings: ToneCurveSettings?
    @ViewState private var dragCancelled = false
    /// Ineffective extra points belong to the editor until a real curve edit.
    /// Publishing them would disagree with the neutral JSON field's omission.
    @ViewState private var neutralDraft: ToneCurveSettings?
    @ViewState private var neutralDraftBaseline: ToneCurveSettings?
    @CurveGestureState private var gestureActive = false
    @FocusState private var focusedCoordinate: Coordinate?
    private enum Coordinate: Hashable { case x, y }

    private var editingSettings: ToneCurveSettings {
        neutralDraftBaseline == settings ? (neutralDraft ?? settings) : settings
    }
    private var curve: ToneCurve { editingSettings[channel] }
    private var index: Int { min(selected, curve.points.count - 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Kurvenkanal", selection: Binding(get: { channel }, set: {
                commitCoordinates(); finishDrag(); focusedCoordinate = nil; channel = $0; selected = 0; synchronizeCoordinates()
            })) {
                Text("RGB").tag(LevelsChannel.master)
                Text("Rot").tag(LevelsChannel.red)
                Text("Grün").tag(LevelsChannel.green)
                Text("Blau").tag(LevelsChannel.blue)
            }
            .accessibilityIdentifier("develop.curves.channel")
            graph.frame(height: 164)
            Picker("Kurvenpunkt", selection: Binding(get: { selected }, set: {
                commitCoordinates(); focusedCoordinate = nil; selected = $0; synchronizeCoordinates()
            })) {
                ForEach(curve.points.indices, id: \.self) { position in
                    Text("Punkt \(position + 1)").tag(position)
                }
            }
            .accessibilityIdentifier("develop.curves.point")
            HStack {
                Text("Eingang")
                TextField("Eingang", text: $xText)
                    .focused($focusedCoordinate, equals: .x)
                    .onSubmit { commitCoordinates(); focusedCoordinate = nil }
                    .disabled(index == 0 || index == curve.points.count - 1)
                    .accessibilityIdentifier("develop.curves.x")
                Text("Ausgang")
                TextField("Ausgang", text: $yText)
                    .focused($focusedCoordinate, equals: .y)
                    .onSubmit { commitCoordinates(); focusedCoordinate = nil }
                    .accessibilityIdentifier("develop.curves.y")
            }
            .font(.system(size: 13)).textFieldStyle(.roundedBorder)
            HStack {
                Stepper("Eingang ändern", onIncrement: { move(dx: 0.001, dy: 0) }, onDecrement: { move(dx: -0.001, dy: 0) })
                    .labelsHidden().disabled(index == 0 || index == curve.points.count - 1)
                    .accessibilityLabel("Eingang von Punkt \(index + 1) ändern")
                Stepper("Ausgang ändern", onIncrement: { move(dx: 0, dy: 0.001) }, onDecrement: { move(dx: 0, dy: -0.001) })
                    .labelsHidden().accessibilityLabel("Ausgang von Punkt \(index + 1) ändern")
                Spacer(minLength: 0)
                Button { addPoint() } label: { Image(systemName: "plus") }
                    .help("Punkt hinzufügen").accessibilityLabel("Kurvenpunkt hinzufügen")
                    .accessibilityIdentifier("develop.curves.add")
                    .disabled(curve.points.count >= ToneCurve.maximumPointCount)
                Button { deletePoint() } label: { Image(systemName: "minus") }
                    .help("Punkt löschen").accessibilityLabel("Kurvenpunkt löschen")
                    .accessibilityIdentifier("develop.curves.delete")
                    .disabled(index == 0 || index == curve.points.count - 1)
                Button("Reset") {
                    if gestureActive { dragCancelled = true }
                    finishDrag(); commitCoordinates()
                    var value = editingSettings; value[channel] = .neutral; publish(value)
                    selected = 0; synchronizeCoordinates()
                }
                .accessibilityLabel("Ausgewählten Kurvenkanal zurücksetzen")
                .accessibilityIdentifier("develop.curves.reset")
            }
            Text("Punkt wählen und ziehen. Doppelklick fügt einen Punkt hinzu. Werte außerhalb 0–1 bleiben mit Steigung 1 erhalten.")
                .font(.caption2).foregroundStyle(.secondary)
            if let message { Text(message).font(.caption).foregroundStyle(.orange).accessibilityLabel(message) }
        }
        .onAppear { synchronizeCoordinates() }
        .onChange(of: settings) { _, _ in
            if isDragging, dragExpectedSettings != settings { dragCancelled = true; finishDrag() }
            if neutralDraftBaseline != settings { neutralDraft = nil; neutralDraftBaseline = nil }
            if focusedCoordinate == nil { synchronizeCoordinates() }
        }
        .onChange(of: gestureActive) { _, active in
            if !active { finishDrag(); dragCancelled = false }
        }
        .onChange(of: focusedCoordinate) { old, new in
            if old != nil && old != new { commitCoordinates() }
            coordinateBaseline = new == nil ? nil : settings
        }
        .onDisappear { commitCoordinates(); finishDrag() }
    }

    private var graph: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.04))
                Path { path in
                    for fraction in [0.25, 0.5, 0.75] {
                        let x = fraction * geometry.size.width, y = fraction * geometry.size.height
                        path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                        path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                    }
                }.stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                Path { path in
                    for step in 0...128 {
                        let x = Double(step) / 128, y = (try? curve.value(for: x)) ?? x
                        let point = CGPoint(x: x * geometry.size.width, y: (1 - y) * geometry.size.height)
                        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                }.stroke(Color.accentColor, lineWidth: 2)
                ForEach(curve.points.indices, id: \.self) { position in
                    let point = curve.points[position]
                    Circle().fill(position == index ? Color.accentColor : Color.secondary)
                        .frame(width: 11, height: 11)
                        .overlay(Circle().stroke(Color.white.opacity(0.7), lineWidth: 1))
                        .padding(5).contentShape(Circle())
                        .position(x: point.x * geometry.size.width, y: (1 - point.y) * geometry.size.height)
                        .onTapGesture { commitCoordinates(); selected = position; synchronizeCoordinates() }
                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("toneCurveEditorGraph"))
                            .updating($gestureActive) { _, active, _ in active = true }.onChanged { value in
                            guard !dragCancelled, curve.points.indices.contains(position) else { return }
                            if !isDragging {
                                commitCoordinates(); focusedCoordinate = nil
                                selected = position; isDragging = true; dragExpectedSettings = settings; onEditingChanged(true)
                            }
                            updatePoint(at: position, x: value.location.x / geometry.size.width,
                                        y: 1 - value.location.y / geometry.size.height, clamped: true)
                        }.onEnded { _ in finishDrag() })
                        .accessibilityHidden(true)
                }
            }
            .coordinateSpace(name: "toneCurveEditorGraph")
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture(count: 2).onEnded { value in
                insertPoint(x: value.location.x / geometry.size.width, y: 1 - value.location.y / geometry.size.height)
            })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Punktkurve, \(curve.points.count) Punkte. Punkte über die Auswahl und Koordinaten darunter bearbeiten.")
        }
    }

    private func finishDrag() {
        if isDragging { isDragging = false; dragExpectedSettings = nil; onEditingChanged(false) }
    }
    private func publish(_ value: ToneCurveSettings) {
        let canonical = value.normalized
        if value.isNeutral, value != .neutral {
            neutralDraft = value; neutralDraftBaseline = canonical
        } else { neutralDraft = nil; neutralDraftBaseline = nil }
        if isDragging { dragExpectedSettings = canonical }
        if canonical != settings { settings = canonical }
    }
    private func synchronizeCoordinates() {
        guard !curve.points.isEmpty else { return }
        xText = String(format: "%.3f", curve.points[index].x)
        yText = String(format: "%.3f", curve.points[index].y)
    }
    private func commitCoordinates() {
        if let coordinateBaseline, coordinateBaseline != settings {
            message = "Die Kurve wurde inzwischen geändert. Bitte den aktuellen Punkt erneut bearbeiten."
            self.coordinateBaseline = settings; synchronizeCoordinates(); return
        }
        defer { if coordinateBaseline != nil { coordinateBaseline = settings } }
        guard let x = Double(xText.replacingOccurrences(of: ",", with: ".")),
              let y = Double(yText.replacingOccurrences(of: ",", with: ".")) else {
            message = "Bitte endliche Zahlen von 0 bis 1 eingeben."; synchronizeCoordinates(); return
        }
        // Formatting an unchanged coordinate must not round a precise point.
        let old = curve.points[index]
        let xx = xText == String(format: "%.3f", old.x) ? old.x : x
        let yy = yText == String(format: "%.3f", old.y) ? old.y : y
        updatePoint(at: index, x: xx, y: yy, clamped: false)
        synchronizeCoordinates()
    }
    private func move(dx: Double, dy: Double) {
        commitCoordinates(); let point = curve.points[index]
        updatePoint(at: index, x: point.x + dx, y: point.y + dy, clamped: true)
    }
    private func updatePoint(at position: Int, x: Double, y: Double, clamped: Bool) {
        guard !isDragging || dragExpectedSettings == settings else { dragCancelled = true; finishDrag(); return }
        guard let candidate = try? ToneCurvePointEditing.moving(curve, at: position, x: x, y: y, clamped: clamped) else {
            message = "Punkte dürfen sich nicht kreuzen; der Eingang braucht mindestens 0,001 Abstand."; return
        }
        var value = editingSettings; value[channel] = candidate
        publish(value); message = nil
        if focusedCoordinate == nil { synchronizeCoordinates() }
    }
    private func addPoint() {
        commitCoordinates()
        let position = (0..<(curve.points.count - 1)).max {
            curve.points[$0 + 1].x - curve.points[$0].x < curve.points[$1 + 1].x - curve.points[$1].x
        }!
        let x = (curve.points[position].x + curve.points[position + 1].x) / 2
        insertPoint(x: x, y: (try? curve.value(for: x)) ?? x)
    }
    private func insertPoint(x: Double, y: Double) {
        commitCoordinates(); finishDrag(); focusedCoordinate = nil
        guard curve.points.count < ToneCurve.maximumPointCount, x > 0, x < 1 else { return }
        var value = editingSettings, candidate = curve
        let position = candidate.points.firstIndex { $0.x > x }!
        candidate.points.insert(.init(x: x, y: min(max(y, candidate.points[position - 1].y), candidate.points[position].y)), at: position)
        guard (try? candidate.validate()) != nil else { message = "Zu wenig Abstand zum Nachbarpunkt."; return }
        value[channel] = candidate; publish(value); selected = position; message = nil; synchronizeCoordinates()
    }
    private func deletePoint() {
        commitCoordinates(); guard index > 0, index < curve.points.count - 1 else { return }
        var value = editingSettings, candidate = curve
        candidate.points.remove(at: index); value[channel] = candidate; publish(value)
        selected = min(selected, candidate.points.count - 1); synchronizeCoordinates()
    }
}
