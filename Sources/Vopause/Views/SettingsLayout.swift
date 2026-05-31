import SwiftUI

enum SettingsLayout {
    static let idealWidth: CGFloat = 560
    static let idealHeight: CGFloat = 460
    static let horizontalPadding: CGFloat = 24
    static let verticalPadding: CGFloat = 20
    static let stackSpacing: CGFloat = 14
    static let cardPadding: CGFloat = 16
    static let cardCornerRadius: CGFloat = VopausePalette.cornerRadius
    static let labelWidth: CGFloat = 170
    static let cardFill = Color.primary.opacity(0.035)
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(SettingsLayout.cardPadding)
            .background(SettingsLayout.cardFill, in: RoundedRectangle(cornerRadius: SettingsLayout.cardCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: SettingsLayout.cardCornerRadius)
                    .strokeBorder(VopausePalette.hairline, lineWidth: 1)
            }
    }
}
