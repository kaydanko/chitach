import SwiftUI

/// Перелік доданих книг.
///
/// Той самий вигляд служить і початковим екраном, і аркушем поверх читання:
/// перелік однаковий, різниться лише те, чи є кнопка закриття. Робити два
/// схожі екрани означало б згодом правити обидва.
struct LibraryView: View {
    @Environment(ReaderStore.self) private var store

    /// Задано, коли перелік відкрито поверх книги.
    var onClose: (() -> Void)?

    @State private var bookToDelete: LibraryBook?

    /// Зайві копії того самого. Шукаємо при появі екрана, а не в кожному
    /// відображенні: це звірка вмісту файлів, і робити її на кожен кадр
    /// ні до чого.
    @State private var redundant: [LibraryBook] = []
    @State private var isConfirmingCleanup = false

    // Розміри в пунктах, а не семантичні стилі: на Mac Catalyst інтерфейс
    // малюється в масштабі 77%, і системні стилі виходять там помітно
    // дрібнішими за задумане.
    private let titleSize: CGFloat = 19
    private let detailSize: CGFloat = 14

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            list
        }
        .background(Color(BookAppearance.voidColor))
        .task(id: store.library.count) {
            redundant = await LibraryStore.redundantCopies()
        }
        .confirmationDialog(
            "Прибрати \(redundant.count) \(Self.copiesWord(redundant.count))?",
            isPresented: $isConfirmingCleanup,
            titleVisibility: .visible
        ) {
            Button("Прибрати", role: .destructive) {
                Task {
                    await LibraryStore.removeDuplicates()
                    store.refreshLibrary()
                    redundant = await LibraryStore.redundantCopies()
                }
            }
            Button("Скасувати", role: .cancel) {}
        } message: {
            Text("Та сама книга лежить у бібліотеці кілька разів. Лишиться одна копія — та, у якій ви просунулися найдалі. Решту буде видалено без можливості відновити.")
        }
        .confirmationDialog(
            "Вилучити «\(bookToDelete?.title ?? "")»?",
            isPresented: Binding(
                get: { bookToDelete != nil },
                set: { if !$0 { bookToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Вилучити", role: .destructive) {
                if let book = bookToDelete { store.delete(book) }
                bookToDelete = nil
            }
            Button("Скасувати", role: .cancel) { bookToDelete = nil }
        } message: {
            Text("Файл буде видалено із застосунку разом із місцем читання. Скасувати це не можна.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text("Бібліотека")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color(BookAppearance.onVoidColor))

            Spacer()

            // Кнопка з`являється лише тоді, коли є що прибирати: бібліотеки,
            // зібрані до того, як повторне додавання почало впізнаватися,
            // повні копій із номерами в назві.
            if !redundant.isEmpty {
                Button("Прибрати дублікати (\(redundant.count))") {
                    isConfirmingCleanup = true
                }
                .buttonStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color(BookAppearance.onVoidMutedColor))
            }

            Button("Додати книгу…") { store.isImporting = true }
                .buttonStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color(BookAppearance.onVoidColor))

            // Хрестик праворуч, а не стрілка ліворуч: закриття шукають саме
            // в правому верхньому куті, і «вниз» ліворуч читалося як щось
            // інше — згорнути, повернутися, будь-що.
            if let onClose {
                CloseButton(action: onClose, label: "Закрити бібліотеку")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var list: some View {
        if store.library.isEmpty {
            VStack(spacing: 14) {
                Spacer()
                Text("Тут поки порожньо")
                    .font(.system(size: 19))
                Text("Перетягніть книгу у вікно або натисніть «Додати книгу…»")
                    .font(.system(size: 15))
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .foregroundStyle(Color(BookAppearance.onVoidMutedColor))
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 30)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.library) { book in
                        row(book)
                        Divider()
                            .overlay(Color.white.opacity(0.06))
                            .padding(.leading, 20)
                    }
                }
            }
        }
    }

    private func row(_ book: LibraryBook) -> some View {
        Button {
            store.open(book: book)
            onClose?()
        } label: {
            HStack(spacing: 14) {
                Text(book.format)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(BookAppearance.voidColor))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color(BookAppearance.onVoidMutedColor), in: .rect(cornerRadius: 4))

                VStack(alignment: .leading, spacing: 3) {
                    Text(book.title)
                        .font(.system(size: titleSize))
                        .foregroundStyle(Color(BookAppearance.onVoidColor))
                        .lineLimit(1)

                    if let detail = detail(for: book) {
                        Text(detail)
                            .font(.system(size: detailSize))
                            .foregroundStyle(Color(BookAppearance.onVoidMutedColor))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 10)

                if book.url == store.bookURL {
                    Text("Читаємо")
                        .font(.system(size: detailSize, weight: .medium))
                        .foregroundStyle(Color(BookAppearance.onVoidColor))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Вилучити з бібліотеки", role: .destructive) { bookToDelete = book }
        }
    }

    /// «копію» / «копії» / «копій» — щоб речення звучало по-людськи.
    /// Англійській вистачає двох форм.
    private static func copiesWord(_ count: Int) -> String {
        if AppLanguage.current == .en { return count == 1 ? "copy" : "copies" }
        let tens = count % 100
        if (11 ... 14).contains(tens) { return "копій" }
        return switch count % 10 {
        case 1: "копію"
        case 2 ... 4: "копії"
        default: "копій"
        }
    }

    /// Другий рядок: автор, а якщо його немає — те, що знаємо про поступ.
    private func detail(for book: LibraryBook) -> String? {
        var parts: [String] = []
        if let author = book.author, !author.isEmpty { parts.append(author) }
        if let progress = book.progress, book.isStarted {
            parts.append(String(localized: "прочитано \(Int((progress * 100).rounded()))%", bundle: AppLanguage.bundle))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
