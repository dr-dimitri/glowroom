import AppKit
import SwiftUI

/// A native slider whose double click restores the control's semantic default.
/// A plain click is held until AppKit's double-click interval has elapsed. This
/// prevents the first click of a reset from becoming an unwanted undo entry;
/// dragging and keyboard input still publish their values immediately.
struct ResettableSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double?
    let neutralValue: Double
    let onEditingChanged: (Bool) -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double? = nil,
         neutralValue: Double = 0, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        _value = value
        self.range = range
        self.step = step
        self.neutralValue = neutralValue
        self.onEditingChanged = onEditingChanged
    }

    func makeNSView(context: Context) -> ResettableNativeSlider {
        let slider = ResettableNativeSlider(frame: .zero)
        updateNSView(slider, context: context)
        return slider
    }

    func updateNSView(_ slider: ResettableNativeSlider, context: Context) {
        if slider.minValue != range.lowerBound { slider.minValue = range.lowerBound }
        if slider.maxValue != range.upperBound { slider.maxValue = range.upperBound }
        slider.resetNeutralValue = min(range.upperBound, max(range.lowerBound, neutralValue))
        slider.valueStep = step
        slider.isEnabled = isEnabled
        if !isEnabled { slider.cancelInput() }
        slider.controlSize = switch controlSize {
        case .mini: .mini
        case .small: .small
        case .large: .large
        default: .regular
        }
        slider.interaction.readValue = { value }
        slider.interaction.writeValue = { value = $0 }
        slider.interaction.onEditingChanged = onEditingChanged
        slider.synchronizeValueFromBinding()
    }

    static func dismantleNSView(_ slider: ResettableNativeSlider, coordinator: ()) {
        slider.invalidate()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ResettableNativeSlider, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 100, height: nsView.intrinsicContentSize.height)
    }
}

/// Input bookkeeping is independent of AppKit tracking so reset/undo ordering
/// can be checked without timing-sensitive pointer automation.
@MainActor
final class ResettableSliderInteraction {
    var readValue: () -> Double = { 0 }
    var writeValue: (Double) -> Void = { _ in }
    var onEditingChanged: (Bool) -> Void = { _ in }
    private var pointerValue: Double?
    private var pendingClick: Double?
    private var pendingBaseline: Double?
    private(set) var pointerDown = false
    private(set) var isTracking = false
    var hasUncommittedClick: Bool { pendingClick != nil }

    func beginPointer() {
        commitClick()
        pointerDown = true
        pointerValue = nil
    }

    func beginDragging() {
        guard pointerDown, !isTracking else { return }
        beginEditing()
        if let value = pointerValue { publish(value) }
    }

    func nativeValueChanged(_ value: Double) {
        if pointerDown {
            pointerValue = value
            if isTracking { publish(value) }
        } else if isTracking {
            publish(value)
        } else {
            atomicChange(value)
        }
    }

    func endPointer() {
        guard pointerDown else { return }
        pointerDown = false
        if isTracking { endEditing() }
        else if let value = pointerValue, value != readValue() { pendingClick = value; pendingBaseline = readValue() }
        pointerValue = nil
    }

    func beginKeyboard() {
        commitClick()
        beginEditing()
    }

    func endKeyboard() { endEditing() }

    func commitClick() {
        guard let value = pendingClick else { return }
        let baseline = pendingBaseline
        pendingClick = nil; pendingBaseline = nil
        // A newer undo, reset or accepted look wins over a deferred click.
        guard readValue() == baseline else { return }
        atomicChange(value)
    }

    func reset(to value: Double) {
        pendingClick = nil; pendingBaseline = nil
        pointerValue = nil
        pointerDown = false
        // A numeric field may own an open editing group even when this native
        // slider has not started tracking. Close it before the reset's group.
        if isTracking { endEditing() }
        else { onEditingChanged(false) }
        atomicChange(value)
    }

    func cancel() {
        pendingClick = nil; pendingBaseline = nil
        pointerValue = nil
        pointerDown = false
        endEditing()
    }

    private func atomicChange(_ value: Double) {
        guard value != readValue() else { return }
        beginEditing()
        publish(value)
        endEditing()
    }

    private func beginEditing() {
        guard !isTracking else { return }
        isTracking = true
        onEditingChanged(true)
    }

    private func endEditing() {
        guard isTracking else { return }
        isTracking = false
        onEditingChanged(false)
    }

    private func publish(_ value: Double) {
        if value != readValue() { writeValue(value) }
    }
}

@MainActor
final class ResettableNativeSlider: NSSlider {
    let interaction = ResettableSliderInteraction()
    var resetNeutralValue: Double = 0
    var valueStep: Double?
    private var clickWork: DispatchWorkItem?
    private var initialPoint: NSPoint?
    private var isTornDown = false
    private var ignoresNativeChangesUntilNewInput = false

    /// End native input before an undo or function change. Views are a small,
    /// main-actor-owned tree; parallel traversal would race native controls.
    static func cancelInputs(in view: NSView?) {
        guard let view else { return }
        (view as? ResettableNativeSlider)?.cancelInput()
        for child in view.subviews { cancelInputs(in: child) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = ResettableSliderCell()
        isContinuous = true
        target = self
        action = #selector(valueChanged)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, !isTornDown else { return }
        ignoresNativeChangesUntilNewInput = false
        clickWork?.cancel()
        clickWork = nil
        if event.clickCount == 2 {
            interaction.reset(to: resetNeutralValue)
            doubleValue = resetNeutralValue
            return
        }
        beginPointerTracking(at: convert(event.locationInWindow, from: nil))
        super.mouseDown(with: event)
        endPointerTracking()
        guard interaction.hasUncommittedClick else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.interaction.commitClick()
            self.doubleValue = self.interaction.readValue()
            self.clickWork = nil
        }
        clickWork = work
        let remaining = min(NSEvent.doubleClickInterval,
            max(0, event.timestamp + NSEvent.doubleClickInterval - ProcessInfo.processInfo.systemUptime))
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled, !isTornDown else { return }
        ignoresNativeChangesUntilNewInput = false
        clickWork?.cancel()
        clickWork = nil
        interaction.beginKeyboard()
        if let step = valueStep, step.isFinite, step > 0,
           let direction = [123: -1.0, 124: 1.0, 125: -1.0, 126: 1.0][Int(event.keyCode)] {
            let multiplier = event.modifierFlags.contains(.option) ? 10.0 : 1.0
            doubleValue = min(maxValue, max(minValue, doubleValue + direction * step * multiplier))
            valueChanged()
        } else {
            super.keyDown(with: event)
            captureNativeValue()
        }
        interaction.endKeyboard()
    }

    override func accessibilityPerformIncrement() -> Bool {
        guard isEnabled, !isTornDown else { return false }
        ignoresNativeChangesUntilNewInput = false
        if let step = valueStep, step.isFinite, step > 0 {
            doubleValue = min(maxValue, doubleValue + step)
            valueChanged()
            return true
        }
        let changed = super.accessibilityPerformIncrement()
        if changed { captureNativeValue() }
        return changed
    }

    override func accessibilityPerformDecrement() -> Bool {
        guard isEnabled, !isTornDown else { return false }
        ignoresNativeChangesUntilNewInput = false
        if let step = valueStep, step.isFinite, step > 0 {
            doubleValue = max(minValue, doubleValue - step)
            valueChanged()
            return true
        }
        let changed = super.accessibilityPerformDecrement()
        if changed { captureNativeValue() }
        return changed
    }

    func beginPointerTracking(at point: NSPoint) {
        guard !isTornDown else { return }
        ignoresNativeChangesUntilNewInput = false
        initialPoint = point
        interaction.beginPointer()
    }

    func continuedTracking(at point: NSPoint) {
        guard let initialPoint else { return }
        // NSSliderCell can move without a target/action. Capture its current
        // position before beginning the drag; publishing the buffered mouse-down
        // position first would restore an old value and trigger a stale preview.
        captureNativeValue()
        if hypot(point.x - initialPoint.x, point.y - initialPoint.y) > 2 {
            interaction.beginDragging()
        }
    }

    func synchronizeValueFromBinding() {
        // AppKit owns the knob from mouse-down, including the small movement
        // before it qualifies as a drag. SwiftUI can update for unrelated image
        // work during that interval, while the binding still has the old value.
        guard !interaction.pointerDown, !interaction.isTracking,
              !interaction.hasUncommittedClick else { return }
        doubleValue = interaction.readValue()
    }

    func endPointerTracking() {
        guard initialPoint != nil else { return }
        // Also capture a plain track click and the final mouse-up position.
        // Neither may have produced a target/action on the native cell.
        captureNativeValue()
        initialPoint = nil
        interaction.endPointer()
    }

    func cancelInput() {
        // AppKit may still deliver a target/action after its tracking was
        // canceled. Only an explicitly new user input may publish again.
        ignoresNativeChangesUntilNewInput = true
        clickWork?.cancel()
        clickWork = nil
        initialPoint = nil
        interaction.cancel()
    }

    func invalidate() {
        isTornDown = true
        cancelInput()
    }

    @objc private func valueChanged() {
        captureNativeValue()
    }

    private func captureNativeValue() {
        guard !isTornDown else { return }
        guard !ignoresNativeChangesUntilNewInput else {
            doubleValue = interaction.readValue()
            return
        }
        var next = doubleValue
        if let step = valueStep, step.isFinite, step > 0 {
            next = min(maxValue, max(minValue, minValue + ((next - minValue) / step).rounded() * step))
        }
        doubleValue = next
        interaction.nativeValueChanged(next)
    }
}

@MainActor
private final class ResettableSliderCell: NSSliderCell {
    override func continueTracking(last lastPoint: NSPoint, current currentPoint: NSPoint, in controlView: NSView) -> Bool {
        let continues = super.continueTracking(last: lastPoint, current: currentPoint, in: controlView)
        (controlView as? ResettableNativeSlider)?.continuedTracking(at: currentPoint)
        return continues
    }
}
