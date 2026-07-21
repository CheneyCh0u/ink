import InkConfig

enum FontSizeCommand {
    case increase
    case decrease
    case reset

    func updatedValue(from current: Double) -> Double {
        switch self {
        case .increase:
            min(current + 1, InkConfig.fontSizeRange.upperBound)
        case .decrease:
            max(current - 1, InkConfig.fontSizeRange.lowerBound)
        case .reset:
            InkConfig.defaultFontSize
        }
    }
}
