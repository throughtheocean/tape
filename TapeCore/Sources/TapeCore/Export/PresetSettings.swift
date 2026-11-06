import HardwarePresets

extension ExportSettings {
    /// The settings a hardware preset fixes. Every preset is WAV; 16 bit output is dithered.
    public init(preset: ExportPreset) {
        let format: SampleFormat
        switch preset.format.bitDepth {
        case .int16: format = .int16
        case .int24: format = .int24
        case .float32: format = .float32
        }
        let layout: ChannelLayout
        switch preset.format.channels {
        case .mono: layout = .mono
        case .stereo: layout = .stereo
        case .asSource: layout = .session
        }
        self.init(container: .wav, sampleFormat: format, sampleRate: preset.format.sampleRate, layout: layout)
    }

    /// True when the fields a preset locks (container, rate, bit depth, channels) are as the preset sets them.
    public func matches(_ preset: ExportPreset) -> Bool {
        let fixed = ExportSettings(preset: preset)
        return container == fixed.container && sampleFormat == fixed.sampleFormat && sampleRate == fixed.sampleRate && layout == fixed.layout
    }
}

extension ExportPreset {
    /// Problems with exporting `files` files of the given lengths (seconds) under this preset, or nil.
    public func violation(fileSeconds: [Double]) -> String? {
        let l = limits
        if let max = l.maxFiles, fileSeconds.count > max {
            return "\(name) takes at most \(max) files, this export makes \(fileSeconds.count)."
        }
        if let max = l.maxSeconds, let longest = fileSeconds.max(), longest > max {
            return String(format: "%@ takes at most %.0f s per file, the longest here is %.1f s.", name, max, longest)
        }
        return nil
    }
}
