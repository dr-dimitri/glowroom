import AppKit
import Testing
@testable import Glowroom

@Suite("Resettable native sliders")
struct ResettableSliderTests {
    @Test @MainActor
    func bindingRefreshCannotReplaceTheNativeValueBeforeTheDragThreshold() {
        let probe = SliderEditProbe(value: 6_500)
        let slider = nativeSlider(probe)
        slider.beginPointerTracking(at: NSPoint(x: 40, y: 10))
        slider.doubleValue = 8_000
        slider.continuedTracking(at: NSPoint(x: 41, y: 10))
        slider.synchronizeValueFromBinding()
        #expect(slider.doubleValue == 8_000,
                "A view refresh must preserve AppKit's position while the pointer is held")
        #expect(probe.value == 6_500 && probe.history.isEmpty)

        slider.continuedTracking(at: NSPoint(x: 50, y: 10))
        slider.endPointerTracking()
        slider.synchronizeValueFromBinding()
        #expect(slider.doubleValue == 8_000 && probe.value == 8_000)
        #expect(probe.history == [6_500])
    }

    @Test @MainActor
    func firstDragPublishesTheCurrentCellPositionWithoutRestoringTheBufferedMouseDownValue() {
        let probe = SliderEditProbe(value: 6_500)
        let slider = nativeSlider(probe)
        slider.beginPointerTracking(at: NSPoint(x: 40, y: 10))
        slider.doubleValue = 8_000
        slider.continuedTracking(at: NSPoint(x: 41, y: 10))
        slider.doubleValue = 9_000
        slider.continuedTracking(at: NSPoint(x: 60, y: 10))
        slider.endPointerTracking()
        #expect(probe.events == ["begin", "value:9000.0", "end"])
        #expect(probe.value == 9_000 && probe.history == [6_500])
    }

    @Test @MainActor
    func nativeTrackClickWithoutTargetActionCapturesAndQuantizesItsFinalValue() {
        let probe = SliderEditProbe(value: 6_500)
        let slider = nativeSlider(probe)
        slider.beginPointerTracking(at: NSPoint(x: 40, y: 10))
        // Reproduce the native-cell behavior observed during a real track
        // click: the knob changes while no target/action reaches the wrapper.
        slider.doubleValue = 10_145.695
        slider.endPointerTracking()
        #expect(slider.doubleValue == 10_150)
        #expect(probe.value == 6_500)
        #expect(slider.interaction.hasUncommittedClick)
        slider.interaction.commitClick()
        #expect(probe.value == 10_150)
        #expect(probe.history == [6_500])
    }

    @Test @MainActor
    func nativeCellTrackingPublishesQuantizedLiveDragAndCapturesMouseUpWithoutActions() throws {
        let probe = SliderEditProbe(value: 6_500)
        let slider = nativeSlider(probe)
        let cell = try #require(slider.cell as? NSSliderCell)
        slider.beginPointerTracking(at: NSPoint(x: 40, y: 10))
        slider.doubleValue = 8_976.9
        _ = cell.continueTracking(last: NSPoint(x: 40, y: 10), current: NSPoint(x: 90, y: 10), in: slider)
        // AppKit's cell recalculates its own position from currentPoint. The
        // regression concerns publication/quantization, not a platform-specific
        // knob inset or the value assigned before native tracking runs.
        #expect(probe.value == slider.doubleValue && probe.value != 6_500,
                "The cell hook must capture the live native value, without an action")
        #expect(probe.value.truncatingRemainder(dividingBy: 50) == 0)
        slider.doubleValue = 9_126.2
        _ = cell.continueTracking(last: NSPoint(x: 90, y: 10), current: NSPoint(x: 100, y: 10), in: slider)
        #expect(probe.value == slider.doubleValue && probe.value != 6_500)
        #expect(probe.value.truncatingRemainder(dividingBy: 50) == 0)
        slider.doubleValue = 9_374.8
        slider.endPointerTracking()
        #expect(probe.value == 9_350)
        #expect(probe.history == [6_500])
        #expect(!slider.interaction.hasUncommittedClick && !slider.interaction.isTracking)
    }

    @Test @MainActor
    func cancelledNativeTrackingCannotPublishLateCellOrMouseUpValues() throws {
        let probe = SliderEditProbe(value: 6_500)
        let slider = nativeSlider(probe)
        let cell = try #require(slider.cell as? NSSliderCell)
        slider.beginPointerTracking(at: NSPoint(x: 40, y: 10))
        slider.doubleValue = 9_000
        slider.cancelInput()
        _ = cell.continueTracking(last: NSPoint(x: 40, y: 10), current: NSPoint(x: 90, y: 10), in: slider)
        slider.doubleValue = 9_374.8
        slider.endPointerTracking()
        slider.interaction.commitClick()
        #expect(probe.value == 6_500)
        #expect(probe.history.isEmpty && probe.events.isEmpty)
        #expect(!slider.interaction.hasUncommittedClick && !slider.interaction.isTracking)
    }

    @Test @MainActor
    func undoDuringDragRejectsLateNativeActionsAndAllowsTheNextGesture() throws {
        let probe = SliderEditProbe(value: 6_500)
        let slider = nativeSlider(probe)
        let cell = try #require(slider.cell as? NSSliderCell)
        let content = NSView(), container = NSView()
        content.addSubview(container); container.addSubview(slider)
        slider.target = slider; slider.action = NSSelectorFromString("valueChanged")
        slider.beginPointerTracking(at: NSPoint(x: 40, y: 10))
        slider.doubleValue = 9_000
        slider.continuedTracking(at: NSPoint(x: 90, y: 10))
        #expect(probe.value == 9_000 && slider.interaction.isTracking)

        ResettableNativeSlider.cancelInputs(in: content)
        probe.undo()
        #expect(probe.value == 6_500 && probe.history.isEmpty)
        slider.doubleValue = 11_000
        _ = slider.sendAction(try #require(slider.action), to: slider.target)
        _ = cell.continueTracking(last: NSPoint(x: 90, y: 10), current: NSPoint(x: 120, y: 10), in: slider)
        slider.endPointerTracking()
        slider.interaction.commitClick()
        #expect(probe.value == 6_500 && probe.history.isEmpty,
                "A canceled drag cannot replace the value restored by Command-Z")
        #expect(!slider.interaction.isTracking && !slider.interaction.hasUncommittedClick)

        slider.beginPointerTracking(at: NSPoint(x: 40, y: 10))
        slider.doubleValue = 8_000
        slider.continuedTracking(at: NSPoint(x: 90, y: 10))
        slider.endPointerTracking()
        #expect(probe.value == 8_000 && probe.history == [6_500])
        ResettableNativeSlider.cancelInputs(in: content)
        #expect(slider.accessibilityPerformIncrement())
        #expect(probe.value == 8_050 && probe.history == [6_500, 8_000],
                "An explicit accessibility action starts fresh input after cancellation")
    }

    @Test @MainActor
    func dismantledSliderRejectsLateTargetActionAndAccessibilityWrites() throws {
        let probe = SliderEditProbe(value: 6_500)
        let slider = nativeSlider(probe)
        slider.target = slider
        slider.action = NSSelectorFromString("valueChanged")
        slider.invalidate()
        slider.doubleValue = 9_000
        _ = slider.sendAction(try #require(slider.action), to: slider.target)
        #expect(!slider.accessibilityPerformIncrement())
        #expect(probe.value == 6_500 && probe.history.isEmpty)
    }

    @Test @MainActor
    func nativeFirstClickCaptureStillCannotLeakIntoDoubleClickUndo() {
        let probe = SliderEditProbe(value: 9_000)
        let slider = nativeSlider(probe)
        slider.beginPointerTracking(at: NSPoint(x: 40, y: 10))
        slider.doubleValue = 10_145.695
        slider.endPointerTracking()
        slider.interaction.reset(to: 6_500)
        slider.interaction.commitClick()
        #expect(probe.value == 6_500)
        #expect(probe.history == [9_000])
    }

    @Test @MainActor
    func shiftDoubleClickRequestsAutomaticValueWithoutPublishingItsFirstClick() throws {
        let probe = SliderEditProbe(value: 9_000)
        let slider = nativeSlider(probe)
        slider.beginPointerTracking(at: NSPoint(x: 40, y: 10))
        slider.doubleValue = 10_150
        slider.endPointerTracking()
        var requestedValues: [Double] = []
        slider.onAutomaticValue = { [weak slider] in
            requestedValues.append(probe.value)
            #expect(slider?.doubleValue == 9_000,
                    "The deferred first click must be removed from the native knob before calculation")
            #expect(slider?.interaction.hasUncommittedClick == false)
        }

        slider.mouseDown(with: try doubleClickEvent(modifiers: .shift))
        slider.interaction.commitClick()
        #expect(requestedValues == [9_000])
        #expect(probe.value == 9_000 && probe.history.isEmpty)
        #expect(probe.events == ["end"])

        // An asynchronous result starts its own edit from the pre-click value.
        slider.interaction.nativeValueChanged(7_500)
        #expect(probe.value == 7_500 && probe.history == [9_000])
    }

    @Test @MainActor
    func shiftDoubleClickFinishesTextEditingBeforeAutomaticValueCallback() throws {
        let probe = SliderEditProbe(value: 6_500)
        let slider = nativeSlider(probe)
        probe.begin()
        probe.write(7_500)
        slider.onAutomaticValue = {
            #expect(probe.history == [6_500])
            probe.interaction.nativeValueChanged(8_000)
        }

        slider.mouseDown(with: try doubleClickEvent(modifiers: .shift))
        #expect(probe.value == 8_000 && probe.history == [6_500, 7_500])
        probe.undo()
        #expect(probe.value == 7_500)
        probe.undo()
        #expect(probe.value == 6_500)
    }

    @Test @MainActor
    func shiftDoubleClickFinishesNativeDraggingBeforeAutomaticValueCallback() throws {
        let probe = SliderEditProbe(value: 6_500)
        let slider = nativeSlider(probe)
        slider.beginPointerTracking(at: NSPoint(x: 40, y: 10))
        slider.doubleValue = 7_500
        slider.continuedTracking(at: NSPoint(x: 90, y: 10))
        slider.onAutomaticValue = { [weak slider] in
            #expect(slider?.interaction.isTracking == false)
            #expect(slider?.interaction.pointerDown == false)
            #expect(probe.history == [6_500])
            probe.interaction.nativeValueChanged(8_000)
        }

        slider.mouseDown(with: try doubleClickEvent(modifiers: [.control, .shift]))
        slider.doubleValue = 11_000
        slider.endPointerTracking()
        #expect(probe.value == 8_000 && probe.history == [6_500, 7_500])
    }

    @Test @MainActor
    func doubleClickWithoutShiftStillResetsEvenWithAutomaticValueCallback() throws {
        for modifiers in [NSEvent.ModifierFlags(), .option, .command, .control] {
            let probe = SliderEditProbe(value: 9_000)
            let slider = nativeSlider(probe)
            slider.resetNeutralValue = 6_500
            var automaticRequests = 0
            slider.onAutomaticValue = { automaticRequests += 1 }
            slider.beginPointerTracking(at: NSPoint(x: 40, y: 10))
            slider.doubleValue = 10_150
            slider.endPointerTracking()

            slider.mouseDown(with: try doubleClickEvent(modifiers: modifiers))
            slider.interaction.commitClick()
            #expect(automaticRequests == 0)
            #expect(probe.value == 6_500 && slider.doubleValue == 6_500)
            #expect(probe.history == [9_000])
        }
    }

    @Test @MainActor
    func shiftDoubleClickWithoutAutomaticValueCallbackRetainsResetBehavior() throws {
        let probe = SliderEditProbe(value: 9_000)
        let slider = nativeSlider(probe)
        slider.resetNeutralValue = 6_500

        slider.mouseDown(with: try doubleClickEvent(modifiers: .shift))
        #expect(probe.value == 6_500 && slider.doubleValue == 6_500)
        #expect(probe.history == [9_000])
    }

    @Test @MainActor
    func disabledAndDismantledSlidersRejectAutomaticValueRequests() throws {
        for tornDown in [false, true] {
            let probe = SliderEditProbe(value: 9_000)
            let slider = nativeSlider(probe)
            var automaticRequests = 0
            slider.onAutomaticValue = { automaticRequests += 1 }
            if tornDown { slider.invalidate() }
            else { slider.isEnabled = false }

            slider.mouseDown(with: try doubleClickEvent(modifiers: .shift))
            #expect(automaticRequests == 0)
            #expect(probe.value == 9_000 && probe.history.isEmpty)
        }
    }

    @Test @MainActor
    func doubleClickDiscardsFirstClickAndCreatesOneResetUndoStep() {
        let probe = SliderEditProbe(value: 36)
        let input = probe.interaction
        input.beginPointer()
        input.nativeValueChanged(-72)
        input.endPointer()
        #expect(probe.value == 36)
        #expect(input.hasUncommittedClick)
        #expect(probe.history.isEmpty)
        input.reset(to: 0)
        input.commitClick() // A cancelled timer cannot apply the first click later.
        #expect(probe.value == 0)
        #expect(probe.history == [36])
        #expect(probe.events == ["end", "begin", "value:0.0", "end"])
        probe.undo()
        #expect(probe.value == 36)
    }

    @Test @MainActor
    func resetFinishesAnExistingTextEntryBeforeOpeningItsOwnGroup() {
        let probe = SliderEditProbe(value: 5)
        probe.begin()
        probe.write(24)
        probe.interaction.reset(to: 0)
        #expect(probe.history == [5, 24])
        probe.undo()
        #expect(probe.value == 24)
        probe.undo()
        #expect(probe.value == 5)
    }

    @Test @MainActor
    func dragPublishesImmediatelyAndAllPositionsShareOneUndoStep() {
        let probe = SliderEditProbe(value: 10)
        let input = probe.interaction
        input.beginPointer()
        input.nativeValueChanged(11)
        #expect(probe.value == 10)
        input.beginDragging()
        #expect(probe.value == 11)
        input.nativeValueChanged(32)
        input.nativeValueChanged(48)
        #expect(probe.value == 48)
        input.endPointer()
        input.commitClick()
        #expect(probe.history == [10])
        #expect(probe.events == ["begin", "value:11.0", "value:32.0", "value:48.0", "end"])
    }

    @Test @MainActor
    func ordinaryTrackClickCommitsOnceAndKeyboardKeepsNativeActionGrouping() {
        let probe = SliderEditProbe(value: 0)
        let input = probe.interaction
        input.beginPointer()
        input.nativeValueChanged(20)
        input.endPointer()
        input.commitClick()
        input.commitClick()
        #expect(probe.value == 20)
        #expect(probe.history == [0])
        input.beginKeyboard()
        input.nativeValueChanged(21)
        input.nativeValueChanged(22)
        input.endKeyboard()
        #expect(probe.value == 22)
        #expect(probe.history == [0, 20])
    }

    @Test @MainActor
    func teardownDiscardsUncommittedClickAndEndsAnActiveDrag() {
        let probe = SliderEditProbe(value: 100)
        let input = probe.interaction
        input.beginPointer()
        input.nativeValueChanged(30)
        input.endPointer()
        input.cancel()
        input.commitClick()
        #expect(probe.value == 100)
        #expect(probe.history.isEmpty)
        input.beginPointer()
        input.beginDragging()
        input.nativeValueChanged(64)
        input.cancel()
        #expect(probe.history == [100])
        #expect(!input.isTracking)
    }

    @Test @MainActor
    func newerExternalValueWinsOverBufferedClick() {
        let probe = SliderEditProbe(value: 0)
        probe.interaction.beginPointer()
        probe.interaction.nativeValueChanged(20)
        probe.interaction.endPointer()
        probe.value = 10
        probe.interaction.commitClick()
        #expect(probe.value == 10)
        #expect(probe.history.isEmpty)
    }

    @Test @MainActor
    func semanticNeutralNeedNotBeZeroAndRepeatedResetCreatesNoUndoEntry() {
        let probe = SliderEditProbe(value: 74)
        probe.interaction.reset(to: 50)
        probe.interaction.reset(to: 50)
        #expect(probe.value == 50)
        #expect(probe.history == [74])
    }

    @MainActor private func nativeSlider(_ probe: SliderEditProbe) -> ResettableNativeSlider {
        let slider = ResettableNativeSlider(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
        slider.minValue = 2_000; slider.maxValue = 12_000; slider.valueStep = 50
        slider.doubleValue = probe.value
        slider.interaction.readValue = probe.interaction.readValue
        slider.interaction.writeValue = probe.interaction.writeValue
        slider.interaction.onEditingChanged = probe.interaction.onEditingChanged
        // The regression must exercise the cell callbacks rather than relying
        // on an action that AppKit was observed not to send during tracking.
        slider.target = nil; slider.action = nil
        return slider
    }

    @MainActor private func doubleClickEvent(modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 40, y: 10),
                                       modifierFlags: modifiers,
                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: 0, context: nil, eventNumber: 2,
                                       clickCount: 2, pressure: 1))
    }
}

@MainActor
private final class SliderEditProbe {
    var value: Double
    var history: [Double] = []
    var events: [String] = []
    private var initialValue: Double?
    lazy var interaction: ResettableSliderInteraction = {
        let input = ResettableSliderInteraction()
        input.readValue = { [unowned self] in value }
        input.writeValue = { [unowned self] in write($0) }
        input.onEditingChanged = { [unowned self] active in
            events.append(active ? "begin" : "end")
            if active { begin() }
            else { end() }
        }
        return input
    }()

    init(value: Double) { self.value = value }
    func begin() { if initialValue == nil { initialValue = value } }
    func write(_ newValue: Double) { value = newValue; events.append("value:\(newValue)") }
    func end() {
        if let initialValue, initialValue != value { history.append(initialValue) }
        initialValue = nil
    }
    func undo() { if let previous = history.popLast() { value = previous } }
}
