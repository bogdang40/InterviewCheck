/// Keeps a slider's tracking values out of its saved binding until editing ends.
/// Discrete keyboard and accessibility changes can commit without a drag session.
struct SettingsSliderEditingState<Value: BinaryFloatingPoint> {
    private var isEditing = false
    private var initialValue: Value?
    private var draft: Value?

    func displayedValue(committed: Value) -> Value {
        draft ?? committed
    }

    mutating func begin(committed: Value) {
        guard !isEditing else { return }
        isEditing = true
        initialValue = committed
        draft = committed
    }

    mutating func update(_ proposed: Value, committed: Value, range: ClosedRange<Value>) -> Value? {
        guard proposed.isFinite else { return nil }
        let bounded = min(range.upperBound, max(range.lowerBound, proposed))
        if isEditing {
            guard initialValue == committed else {
                invalidate()
                return nil
            }
            draft = bounded
            return nil
        }
        return bounded == committed ? nil : bounded
    }

    mutating func end(committed: Value, range: ClosedRange<Value>) -> Value? {
        defer { cancel() }
        guard isEditing, initialValue == committed, let draft else { return nil }
        let bounded = min(range.upperBound, max(range.lowerBound, draft))
        return bounded == committed ? nil : bounded
    }

    /// A reset or range change wins over a pending drag. Keep suppressing writes
    /// until release so subsequent pointer samples cannot undo that change.
    mutating func invalidate() {
        initialValue = nil
        draft = nil
    }

    mutating func cancel() {
        isEditing = false
        invalidate()
    }
}
