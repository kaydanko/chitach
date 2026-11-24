import SwiftUI

/// Налаштування оформлення: кольори й розмір тексту.
struct AppearanceSettingsView: View {
    @Environment(ReaderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Локальні копії для `ColorPicker`.
    ///
    /// Він працює зі `SwiftUI.Color`, а оформлення зберігає `UIColor` — його
    /// потребує Readium. Тримати проміжний стан обовʼязково: якщо звʼязати
    /// вибирач напряму зі сховищем, кожен рух перемальовує екран і скидає
    /// значення під пальцем.
    @State private var paper: Color = .clear
    @State private var ink: Color = .clear

    private struct Theme: Identifiable {
        let id: String
        let name: LocalizedStringKey
        let paper: UInt32
        let ink: UInt32
    }

    private let themes: [Theme] = [
        .init(id: "sand", name: "Пісочна", paper: 0xCDC28B, ink: 0x38331C),
        .init(id: "cream", name: "Кремова", paper: 0xEEE6D3, ink: 0x2B2419),
        .init(id: "sepia", name: "Сепія", paper: 0xE4D5B7, ink: 0x4A3826),
        .init(id: "grey", name: "Сіра", paper: 0xC9C9C4, ink: 0x242424),
        .init(id: "night", name: "Нічна", paper: 0x2A2A28, ink: 0xC4BFAE),
        .init(id: "black", name: "Чорна", paper: 0x000000, ink: 0x9A9A92),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Зразок") { preview }

                Section("Готові теми") {
                    LazyVGrid(columns: [.init(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
                        ForEach(themes) { theme in
                            themeChip(theme)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Власні кольори") {
                    ColorPicker("Тло сторінки", selection: $paper, supportsOpacity: false)
                    ColorPicker("Колір тексту", selection: $ink, supportsOpacity: false)
                }

                Section("Розмір тексту") {
                    HStack {
                        stepButton("minus", label: "Менший текст") {
                            store.stepFontSize(by: -1)
                        }
                        .disabled(!store.canDecreaseFontSize)

                        Spacer()
                        Text("\(Int((store.fontSize * 100).rounded()))%")
                            .monospacedDigit()
                        Spacer()

                        stepButton("plus", label: "Більший текст") {
                            store.stepFontSize(by: 1)
                        }
                        .disabled(!store.canIncreaseFontSize)
                    }

                    Text("Також: ⌘ і коліщатко миші, або ⌘+ і ⌘−.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Поля сторінки") {
                    marginRow(
                        "Ліве поле",
                        value: store.leftMargin,
                        narrower: "Вужче ліве поле",
                        wider: "Ширше ліве поле"
                    ) { store.stepLeftMargin(by: $0) }

                    marginRow(
                        "Праве поле",
                        value: store.rightMargin,
                        narrower: "Вужче праве поле",
                        wider: "Ширше праве поле"
                    ) { store.stepRightMargin(by: $0) }

                    marginRow(
                        "Проміжок між колонками",
                        value: store.spreadGap,
                        narrower: "Вужчий проміжок",
                        wider: "Ширший проміжок",
                        range: BookAppearance.minimumSpreadGap...BookAppearance.maximumSpreadGap
                    ) { store.stepSpreadGap(by: $0) }

                    Text("Боки регулюються окремо: якщо вічко камери лізе на текст, розширте поле з того боку. Проміжок між колонками від них не залежить і діє на широкому вікні, де сторінка ділиться надвоє.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Повернути початкові", role: .destructive) {
                        store.resetAppearance()
                        syncFromStore()
                    }
                }
            }
            .navigationTitle("Оформлення")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .onAppear(perform: syncFromStore)
        .onChange(of: paper) { _, new in store.paperColor = UIColor(new) }
        .onChange(of: ink) { _, new in store.inkColor = UIColor(new) }
    }

    /// Рядок бічного поля: підпис, менше, значення, більше.
    private func marginRow(
        _ title: LocalizedStringKey,
        value: Double,
        narrower: LocalizedStringKey,
        wider: LocalizedStringKey,
        range: ClosedRange<Double> = BookAppearance.minimumSideMargin...BookAppearance.maximumSideMargin,
        step: @escaping (Int) -> Void
    ) -> some View {
        let canNarrow = { (v: Double) in v > range.lowerBound }
        let canWiden = { (v: Double) in v < range.upperBound }

        return HStack {
            Text(title)
            Spacer(minLength: 12)

            stepButton("minus", label: narrower) { step(-1) }
                .disabled(!canNarrow(value))

            Text("\(Int(value))")
                .monospacedDigit()
                .frame(minWidth: 34)

            stepButton("plus", label: wider) { step(1) }
                .disabled(!canWiden(value))
        }
    }

    /// Обидві кнопки однакової висоти.
    ///
    /// Символи `minus` і `plus` мають різну власну висоту, а `.bordered`
    /// малює рамку по вмісту — без явного розміру кнопки виходять різними.
    private func stepButton(
        _ systemName: String,
        label: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 34, height: 24)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(label)
    }

    private var preview: some View {
        Text("Зразок тексту — п'ять, об'єм, здоров'я.")
            .font(.system(size: 15 * store.fontSize))
            .foregroundStyle(ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 14)
            .padding(.leading, previewInset(store.leftMargin))
            .padding(.trailing, previewInset(store.rightMargin))
            .background(paper, in: .rect(cornerRadius: 8))
    }

    /// Поле у зразку — пропорція, а не ті самі пікселі.
    ///
    /// Зразок завжди вужчий за сторінку, а поле в 160 пікселів із двох
    /// боків не лишило б у ньому місця на текст. Тут важливо бачити, який
    /// бік ширший; точну відстань видно на самій сторінці.
    private func previewInset(_ margin: Double) -> CGFloat {
        let fraction = margin / BookAppearance.maximumSideMargin
        return 4 + CGFloat(fraction) * 40
    }

    private func themeChip(_ theme: Theme) -> some View {
        let isActive = store.paperColor.hexValue == theme.paper
            && store.inkColor.hexValue == theme.ink

        return Button {
            store.paperColor = UIColor(hex: theme.paper)
            store.inkColor = UIColor(hex: theme.ink)
            syncFromStore()
        } label: {
            Text(theme.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color(UIColor(hex: theme.ink)))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color(UIColor(hex: theme.paper)), in: .rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isActive ? Color.accentColor : .secondary.opacity(0.25),
                                      lineWidth: isActive ? 2.5 : 1)
                }
        }
        .buttonStyle(.plain)
    }

    private func syncFromStore() {
        paper = Color(store.paperColor)
        ink = Color(store.inkColor)
    }
}
