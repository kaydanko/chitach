import SwiftUI

/// Хрестик, яким закривають екран або аркуш.
///
/// Окремим видом, щоб закриття виглядало однаково скрізь: доти бібліотека
/// й зміст мали стрілку «вниз» ліворуч, і її не впізнавали як закриття —
/// шукають його в правому верхньому куті.
struct CloseButton: View {
    let action: () -> Void
    let label: String

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(BookAppearance.onVoidColor))
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.1), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .keyboardShortcut(.escape, modifiers: [])
    }
}
