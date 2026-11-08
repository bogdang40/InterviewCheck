import Foundation

extension SettingsManager {
    func configuration(for style: BorderShaderStyle) -> BorderShaderConfiguration? {
        switch style {
        case .glass: return glassBorderConfiguration
        case .liquid: return liquidBorderConfiguration
        case .none: return nil
        }
    }

    func resetConfiguration(for style: BorderShaderStyle) {
        guard let preset = BorderShaderConfiguration.preset(for: style) else { return }
        updateConfiguration(preset, for: style)
    }

}
