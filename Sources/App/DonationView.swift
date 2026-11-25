import SwiftUI
import UIKit

/// Куди надходять добровільні внески.
///
/// Усе в одному місці, щоб зміна картки чи банки не вимагала шукати рядки
/// по розмітці.
enum DonationDetails {
    /// Банка monobank. `nil` — блоку з сумою й кнопки банки немає, лишаються
    /// реквізити для ручного переказу.
    ///
    /// Параметр `?a=` у посиланні — сума в гривнях. Офіційно він ніде не
    /// описаний; якщо сторінка банки перестане його читати, людина просто
    /// введе суму сама, і переказ усе одно відбудеться.
    static let jarURL = URL(string: "https://send.monobank.ua/jar/bUjttUaxp")

    /// Швидкі суми для банки, у гривнях.
    static let jarAmounts = [100, 200, 500]

    /// Гривнева картка. Доларова не годилася: monobank не дає до неї
    /// посилання для поповнення.
    static let cardNumber = "4874100027184244"

    /// Цифри групами по чотири — так номер читають і звіряють.
    static func grouped(_ value: String) -> String {
        stride(from: 0, to: value.count, by: 4).map { offset in
            let start = value.index(value.startIndex, offsetBy: offset)
            let end = value.index(start, offsetBy: 4, limitedBy: value.endIndex) ?? value.endIndex
            return String(value[start..<end])
        }
        .joined(separator: " ")
    }

    /// Посилання на банку з наперед заповненою сумою.
    static func jarURL(amount: Int?) -> URL? {
        guard let jarURL else { return nil }
        guard let amount, amount > 0,
              var components = URLComponents(url: jarURL, resolvingAgainstBaseURL: false)
        else { return jarURL }

        var items = components.queryItems ?? []
        items.removeAll { $0.name == "a" }
        items.append(URLQueryItem(name: "a", value: String(amount)))
        components.queryItems = items
        return components.url ?? jarURL
    }
}

/// Екран «Підтримати проєкт».
///
/// Накриває вміст так само, як бібліотека, а не підмінює його: інакше
/// читалка демонтувалася б разом із місцем у книзі.
struct DonationView: View {
    let onClose: () -> Void

    @Environment(ReaderStore.self) private var store
    @Environment(\.openURL) private var openURL

    private enum Field: Hashable { case card }

    /// Що щойно скопійовано. Одне поле на весь екран: галочка має стояти
    /// лише біля останнього скопійованого, а не біля всіх підряд.
    @State private var copiedField: Field?
    @State private var resetTask: Task<Void, Never>?

    @State private var selectedAmount: Int? = DonationDetails.jarAmounts.dropFirst().first
    @State private var customAmount = ""
    @FocusState private var isCustomAmountFocused: Bool

    // Розміри в пунктах, а не семантичні стилі: на Mac Catalyst інтерфейс
    // малюється в масштабі 77%, і системні стилі виходять там дрібнішими.
    private let titleSize: CGFloat = 30
    private let bodySize: CGFloat = 17
    private let labelSize: CGFloat = 13
    private let valueSize: CGFloat = 19

    private var paper: Color { Color(BookAppearance.defaultPaper) }
    private var onVoid: Color { Color(BookAppearance.onVoidColor) }
    private var muted: Color { Color(BookAppearance.onVoidMutedColor) }
    private var surface: Color { Color.white.opacity(0.05) }
    private var hairline: Color { Color.white.opacity(0.09) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                VStack(spacing: 28) {
                    intro

                    if DonationDetails.jarURL != nil {
                        jarSection
                    }

                    cardSection
                    dismissButton
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 24)
                .padding(.top, 64)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)

            CloseButton(action: onClose, label: "Закрити")
                .padding(14)
        }
        .background(Color(BookAppearance.voidColor).ignoresSafeArea())
        .onDisappear { resetTask?.cancel() }
    }

    // MARK: - Звернення

    private var intro: some View {
        VStack(spacing: 14) {
            Image(systemName: "cup.and.saucer")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(paper)
                .padding(.bottom, 4)

            Text("Подобається читати тут?")
                .font(.system(size: titleSize, weight: .semibold, design: .serif))
                .foregroundStyle(onVoid)
                .multilineTextAlignment(.center)

            Text("Chytach робить одна людина у вільний час. Без реклами, без підписок і без збору даних. Якщо застосунок став вам у пригоді, можна пригостити розробника кавою. Внески йдуть на час для нових функцій.")
                .font(.system(size: bodySize, design: .serif))
                .lineSpacing(4)
                .foregroundStyle(muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("Це повністю добровільно. Читалка лишиться такою ж і без внеску.")
                .font(.system(size: labelSize + 1))
                .foregroundStyle(muted.opacity(0.8))
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Банка

    private var jarSection: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                ForEach(DonationDetails.jarAmounts, id: \.self) { amount in
                    amountChip(amount)
                }
                customAmountField
            }

            Button {
                isCustomAmountFocused = false
                if let url = DonationDetails.jarURL(amount: effectiveAmount) {
                    openURL(url)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "heart.fill")
                    Text("Задонатити через monobank")
                }
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color(BookAppearance.voidColor))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(paper, in: .rect(cornerRadius: 14))
                .contentShape(.rect(cornerRadius: 14))
            }
            .buttonStyle(PressableStyle())

            Text("Відкриється банка monobank — у застосунку банку або в браузері. Платити можна карткою будь-якого банку; сума в гривнях.")
                .font(.system(size: labelSize))
                .foregroundStyle(muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Сума, яку передаємо в посилання: власна має перевагу над швидкою.
    private var effectiveAmount: Int? {
        if let custom = Int(customAmount), custom > 0 { return custom }
        return selectedAmount
    }

    private func amountChip(_ amount: Int) -> some View {
        let isSelected = customAmount.isEmpty && selectedAmount == amount

        return Button {
            selectedAmount = amount
            customAmount = ""
            isCustomAmountFocused = false
        } label: {
            Text("\(amount) ₴")
                .font(.system(size: 16, weight: .medium).monospacedDigit())
                .foregroundStyle(isSelected ? Color(BookAppearance.voidColor) : onVoid)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background {
                    if isSelected {
                        Capsule().fill(paper)
                    } else {
                        Capsule().strokeBorder(onVoid.opacity(0.25), lineWidth: 1.2)
                    }
                }
                .contentShape(.capsule)
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    private var customAmountField: some View {
        let isActive = !customAmount.isEmpty || isCustomAmountFocused

        return TextField("Інша", text: $customAmount)
            .keyboardType(.numberPad)
            .focused($isCustomAmountFocused)
            .multilineTextAlignment(.center)
            .font(.system(size: 16, weight: .medium).monospacedDigit())
            .foregroundStyle(onVoid)
            .tint(paper)
            .padding(.vertical, 11)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .background(
                Capsule().strokeBorder(
                    isActive ? paper : onVoid.opacity(0.25),
                    lineWidth: isActive ? 1.6 : 1.2
                )
            )
            .onChange(of: customAmount) { _, new in
                // Лише цифри й не більше шести: це сума, не текст.
                let digits = String(new.filter(\.isNumber).prefix(6))
                if digits != new { customAmount = digits }
            }
            .accessibilityLabel("Інша сума в гривнях")
    }

    // MARK: - Картка

    private var cardSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel(
                DonationDetails.jarURL == nil
                    ? String(localized: "Переказ на картку", bundle: AppLanguage.bundle)
                    : String(localized: "Або переказ на картку", bundle: AppLanguage.bundle)
            )
            .padding(.bottom, 10)

            VStack(spacing: 0) {
                detailRow(
                    title: String(localized: "Номер картки", bundle: AppLanguage.bundle),
                    value: DonationDetails.grouped(DonationDetails.cardNumber),
                    copyValue: DonationDetails.cardNumber,
                    field: .card,
                    monospaced: true
                )
            }
            .background(surface, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(hairline))

            currencyNote
                .padding(.top, 12)
        }
    }

    private var currencyNote: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "hryvniasign.circle")
                .foregroundStyle(paper)
            Text("Картка гривнева (UAH). Якщо ви платите карткою в іншій валюті, ваш банк сконвертує суму за своїм курсом і може взяти комісію — варто глянути, скільки спишеться.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: labelSize + 1))
        .foregroundStyle(muted)
    }

    // MARK: - Закриття

    private var dismissButton: some View {
        Button(action: onClose) {
            (store.bookURL == nil ? Text("Не зараз") : Text("Повернутися до читання"))
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(muted)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .contentShape(.capsule)
        }
        .buttonStyle(PressableStyle())
    }

    // MARK: - Рядок реквізитів

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: labelSize, weight: .semibold))
            .kerning(0.8)
            .foregroundStyle(muted)
    }

    private func detailRow(
        title: String,
        value: String,
        copyValue: String,
        field: Field,
        monospaced: Bool = false
    ) -> some View {
        let isCopied = copiedField == field

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: labelSize))
                    .foregroundStyle(muted)
                Text(value)
                    .font(.system(
                        size: valueSize,
                        weight: .medium,
                        design: monospaced ? .monospaced : .default
                    ))
                    .foregroundStyle(onVoid)
                    // Номер картки лишається в один рядок і за потреби
                    // дрібнішає: розривати його між групами цифр гірше,
                    // ніж зменшити.
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            Button {
                copy(copyValue, field: field)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                    isCopied ? Text("Скопійовано!") : Text("Скопіювати")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isCopied ? Color(BookAppearance.voidColor) : onVoid)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    isCopied ? paper : Color.white.opacity(0.1),
                    in: .capsule
                )
                .contentShape(.capsule)
            }
            .buttonStyle(PressableStyle())
            .animation(.easeOut(duration: 0.15), value: isCopied)
            .accessibilityLabel(isCopied ? String(localized: "\(title) скопійовано", bundle: AppLanguage.bundle) : String(localized: "Скопіювати: \(title)", bundle: AppLanguage.bundle))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func copy(_ value: String, field: Field) {
        UIPasteboard.general.string = value
        copiedField = field
        UIAccessibility.post(notification: .announcement, argument: String(localized: "Скопійовано", bundle: AppLanguage.bundle))

        resetTask?.cancel()
        resetTask = Task {
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            copiedField = nil
        }
    }
}

/// Легке притьмарення під пальцем — однакове для всіх кнопок екрана.
private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
