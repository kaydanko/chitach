import ReadiumShared
import SwiftUI

/// Один рядок змісту.
///
/// Зміст у Readium — дерево вкладених `Link`. Розгортати й згортати гілки тут
/// нема потреби: у книжці рівнів рідко більше двох, а розкривати все одно
/// довелося б одразу, щоб дістатися потрібного розділу. Тому дерево
/// розкладаємо в плаский перелік, а вкладеність показуємо відступом.
struct TableOfContentsEntry: Identifiable {
    let id = UUID()
    var title: String
    var link: ReadiumShared.Link
    var depth: Int

    /// Ресурс без якоря — за ним упізнаємо поточний розділ.
    var resource: String {
        link.url().removingQuery().removingFragment().string
    }
}

extension TableOfContentsEntry {
    /// Розкладає дерево змісту в плаский перелік.
    static func flatten(_ links: [ReadiumShared.Link], depth: Int = 0) -> [Self] {
        links.flatMap { link -> [Self] in
            let title = link.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let entry = Self(
                title: (title?.isEmpty == false) ? title! : String(localized: "Без назви", bundle: AppLanguage.bundle),
                link: link,
                depth: depth
            )
            return [entry] + flatten(link.children, depth: depth + 1)
        }
    }
}

/// Панель змісту.
struct TableOfContentsView: View {
    let entries: [TableOfContentsEntry]
    /// Ресурс, який читаємо зараз, — щоб підсвітити рядок.
    let currentResource: String?
    let onSelect: (TableOfContentsEntry) -> Void
    let onClose: () -> Void

    // Розміри в пунктах: на Mac Catalyst інтерфейс малюється в масштабі 77%,
    // і семантичні стилі виходять там дрібнішими за задумане.
    private let titleSize: CGFloat = 18

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            content
        }
        .background(Color(BookAppearance.voidColor))
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text("Зміст")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color(BookAppearance.onVoidColor))

            Spacer()

            CloseButton(action: onClose, label: "Закрити зміст")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    /// Рядок, який позначаємо як поточний.
    ///
    /// Перший запис, що вказує на той самий файл. Саме перший, а не кожен
    /// збіг: у книзі ціла секція з усіма підрозділами часто лежить одним
    /// файлом, а відрізняються вони лише якорем. Без цього позначка «тут»
    /// стояла б одразу на десятку рядків і не казала б нічого.
    ///
    /// Якір не враховуємо свідомо: щоб дізнатися, у якому саме підрозділі
    /// читач, довелося б виміряти положення кожного запису в книзі —
    /// десятки звернень щоразу, коли відкривають зміст. Позначки на рівні
    /// розділу для орієнтування досить.
    private var currentID: UUID? {
        guard let currentResource else { return nil }
        return entries.first { $0.resource == currentResource }?.id
    }

    @ViewBuilder
    private var content: some View {
        if entries.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                Text("У цій книзі немає змісту")
                    .font(.system(size: 18))
                Text("Так буває у звичайному тексті й у книгах, де розділи не позначені.")
                    .font(.system(size: 14))
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .foregroundStyle(Color(BookAppearance.onVoidMutedColor))
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 30)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            row(entry)
                            Divider()
                                .overlay(Color.white.opacity(0.06))
                                .padding(.leading, 20)
                        }
                    }
                }
                .onAppear {
                    // Відкриваємо зміст там, де читач зупинився: гортати до
                    // свого місця в книзі на сто розділів — марна робота.
                    guard let currentID else { return }
                    proxy.scrollTo(currentID, anchor: .center)
                }
            }
        }
    }

    private func row(_ entry: TableOfContentsEntry) -> some View {
        let isCurrent = entry.id == currentID

        return Button {
            onSelect(entry)
        } label: {
            HStack(spacing: 10) {
                Text(entry.title)
                    .font(.system(size: titleSize, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(Color(
                        isCurrent ? BookAppearance.onVoidColor : BookAppearance.onVoidMutedColor
                    ))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)

                Spacer(minLength: 8)

                if isCurrent {
                    Text("тут")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(BookAppearance.onVoidColor))
                }
            }
            // Вкладеність — відступом. Глибше за третій рівень не відсуваємо:
            // інакше назва лишилася б без місця.
            .padding(.leading, 20 + CGFloat(min(entry.depth, 3)) * 18)
            .padding(.trailing, 20)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(entry.id)
    }
}
