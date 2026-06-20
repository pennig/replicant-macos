extension Duration {
    /// A short, human-readable representation of the duration suitable for a
    /// latency readout (e.g. `"342 ms"` or `"1.21 s"`).
    public var apiCallReadout: String {
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1e18
        if seconds < 1 {
            return "\(Int((seconds * 1000).rounded())) ms"
        }
        return String(format: "%.2f s", seconds)
    }
}
