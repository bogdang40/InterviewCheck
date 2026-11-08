/// Keeps fine numeric steps without asking native Slider to lay out a tick for each one.
struct SettingsSliderQuantization<Value: BinaryFloatingPoint> {
    let range: ClosedRange<Value>
    let step: Value

    init?(range: ClosedRange<Value>, step: Value) {
        guard range.lowerBound.isFinite, range.upperBound.isFinite,
              step.isFinite, step > 0,
              ((range.upperBound - range.lowerBound) / step).isFinite else { return nil }
        self.range = range
        self.step = step
    }

    var usesContinuousSlider: Bool {
        // At most 32 marks are useful in the row's 220pt control area.
        (range.upperBound - range.lowerBound) / step > 31
    }

    func snapped(_ proposed: Value) -> Value? {
        guard proposed.isFinite else { return nil }
        if proposed <= range.lowerBound { return range.lowerBound }
        if proposed >= range.upperBound { return range.upperBound }
        let index = ((proposed - range.lowerBound) / step).rounded()
        return bounded(range.lowerBound + index * step)
    }

    /// Arrow keys and accessibility actions retain one numeric step per action.
    /// Rebuild from the grid index instead of accumulating floating point error.
    func adjusted(_ current: Value, increment: Bool) -> Value? {
        guard current.isFinite else { return nil }
        let index = (bounded(current) - range.lowerBound) / step
        let nearest = index.rounded()
        // Subtracting an offset such as 1.0 before dividing by 0.001 loses
        // precision relative to the small index. Include both operands' scale.
        let operandScale = max(abs(current), abs(range.lowerBound)) / step
        let tolerance = max(1, abs(index), operandScale) * Value.ulpOfOne * 8
        let stableIndex = abs(index - nearest) <= tolerance ? nearest : index
        let next = increment
            ? stableIndex.rounded(.down) + 1
            : stableIndex.rounded(.up) - 1
        return bounded(range.lowerBound + next * step)
    }

    private func bounded(_ value: Value) -> Value {
        min(range.upperBound, max(range.lowerBound, value))
    }
}
