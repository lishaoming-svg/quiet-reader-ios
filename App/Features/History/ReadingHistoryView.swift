import SwiftData
import SwiftUI

struct ReadingHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BookRecord.lastReadAt, order: .reverse) private var books: [BookRecord]
    @Query(sort: \ReadingSessionRecord.startedAt, order: .reverse) private var sessions: [ReadingSessionRecord]
    @Query private var progresses: [ReadingProgressRecord]
    @Query private var sourceRecords: [BookSourceRecord]
    @State private var section = HistorySection.recent

    var body: some View {
        ZStack {
            PaperBackground()
            VStack(spacing: 0) {
                Picker("记录类型", selection: $section) {
                    ForEach(HistorySection.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                if section == .recent { recentContent } else { statisticsContent }
            }
        }
        .navigationTitle("阅读记录")
        .toolbarBackground(AppTheme.paperLight, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            if section == .statistics, !visibleSessions.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("清空阅读时长记录", role: .destructive) {
                            sessions.forEach(modelContext.delete)
                            try? modelContext.save()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var recentContent: some View {
        if recentBooks.isEmpty {
            Spacer()
            EmptyStateView(
                icon: "clock.arrow.circlepath",
                title: "还没有阅读记录",
                message: "打开书架中的图书后，这里会显示最近阅读时间和准确进度。"
            )
            Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: 13) {
                    ForEach(recentBooks) { book in
                        if let source = source(for: book) {
                            NavigationLink {
                                BookDetailView(book: book.searchBook, source: source)
                            } label: {
                                RecentReadingRow(book: book, progress: progress(for: book.bookID))
                            }
                            .buttonStyle(.plain)
                        } else {
                            RecentReadingRow(book: book, progress: progress(for: book.bookID))
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private var recentBooks: [BookRecord] {
        books.filter { book in progresses.contains { $0.bookID == book.bookID } }
    }

    private var statisticsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    StatisticCard(title: "今日", seconds: duration(since: startOfToday))
                    StatisticCard(title: "本周", seconds: duration(since: startOfWeek))
                    StatisticCard(title: "本月", seconds: duration(since: startOfMonth))
                    StatisticCard(title: "累计", seconds: visibleSessions.reduce(0) { $0 + $1.activeSeconds })
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("阅读明细")
                        .font(AppTheme.sectionFont)
                        .foregroundStyle(AppTheme.ink)
                    if visibleSessions.isEmpty {
                        Text("有效阅读后会在这里累计时长。切到后台或超过 5 分钟未操作时会暂停计时。")
                            .font(.callout)
                            .foregroundStyle(AppTheme.inkSoft)
                    } else {
                        ForEach(visibleSessions.prefix(80)) { session in
                            HStack(spacing: 12) {
                                Image(systemName: "book.pages")
                                    .foregroundStyle(AppTheme.jade)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(session.bookName)
                                        .font(.headline)
                                        .foregroundStyle(AppTheme.ink)
                                    Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(AppTheme.inkSoft)
                                }
                                Spacer()
                                Text(Self.durationText(session.activeSeconds))
                                    .font(.subheadline.monospacedDigit().bold())
                                    .foregroundStyle(AppTheme.vermilion)
                            }
                            .padding(.vertical, 6)
                            if session.sessionID != visibleSessions.prefix(80).last?.sessionID {
                                Divider().overlay(AppTheme.line.opacity(0.5))
                            }
                        }
                    }
                }
                .inkCard()
            }
            .padding(16)
        }
    }

    private var visibleSessions: [ReadingSessionRecord] {
        sessions.filter { $0.activeSeconds >= 1 }
    }

    private var startOfToday: Date { Calendar.current.startOfDay(for: .now) }

    private var startOfWeek: Date {
        Calendar.current.dateInterval(of: .weekOfYear, for: .now)?.start ?? startOfToday
    }

    private var startOfMonth: Date {
        Calendar.current.dateInterval(of: .month, for: .now)?.start ?? startOfToday
    }

    private func duration(since date: Date) -> Double {
        visibleSessions
            .filter { $0.startedAt >= date }
            .reduce(0) { $0 + $1.activeSeconds }
    }

    private func progress(for bookID: String) -> ReadingProgressRecord? {
        progresses.first { $0.bookID == bookID }
    }

    private func source(for book: BookRecord) -> BookSourceDefinition? {
        sourceRecords.first { $0.sourceID == book.sourceID }?.definition
    }

    static func durationText(_ seconds: Double) -> String {
        let totalMinutes = Int(seconds) / 60
        if totalMinutes < 1 { return "<1 分钟" }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0 ? "\(hours) 小时 \(minutes) 分" : "\(minutes) 分钟"
    }
}

private enum HistorySection: String, CaseIterable, Identifiable {
    case recent
    case statistics

    var id: String { rawValue }
    var title: String { self == .recent ? "最近阅读" : "时长统计" }
}

private struct RecentReadingRow: View {
    let book: BookRecord
    let progress: ReadingProgressRecord?

    var body: some View {
        HStack(spacing: 14) {
            BookCoverView(urlString: book.coverURL, title: book.name, width: 58, height: 84)
            VStack(alignment: .leading, spacing: 6) {
                Text(book.name)
                    .font(.system(size: 18, weight: .semibold, design: .serif))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(2)
                Text(progress?.chapterTitle ?? "尚未开始")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.inkSoft)
                    .lineLimit(1)
                if let progress {
                    ProgressView(value: progress.chapterProgress)
                        .tint(AppTheme.vermilion)
                    Text("本章 \(Int(progress.chapterProgress * 100))% · \(book.lastReadAt.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(AppTheme.inkSoft)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(AppTheme.line)
        }
        .inkCard()
    }
}

private struct StatisticCard: View {
    let title: String
    let seconds: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption)
                .foregroundStyle(AppTheme.inkSoft)
            Text(ReadingHistoryView.durationText(seconds))
                .font(.system(size: 18, weight: .bold, design: .serif))
                .foregroundStyle(AppTheme.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .inkCard()
    }
}
