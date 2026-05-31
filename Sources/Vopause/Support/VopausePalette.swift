import SwiftUI

enum VopausePalette {
    static let popoverBackground = Color(nsColor: .windowBackgroundColor).opacity(0.98)
    static let surfaceFill = Color.primary.opacity(0.045)
    static let elevatedFill = Color.primary.opacity(0.065)
    static let hairline = Color.primary.opacity(0.075)
    static let activeFill = Color.green.opacity(0.12)
    static let activeBorder = Color.green.opacity(0.24)
    static let warningFill = Color.orange.opacity(0.12)
    static let warningBorder = Color.orange.opacity(0.28)
    static let controlCornerRadius: CGFloat = 8
    static let cornerRadius: CGFloat = 8
    static let popoverCornerRadius: CGFloat = 18
    static let surfacePadding: CGFloat = 12
}
