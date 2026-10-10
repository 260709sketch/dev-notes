import SwiftUI

/// 搜索 Tab：聚合搜索入口 + 结果列表
struct SearchView: View {
    @EnvironmentObject private var player: PlayerCore
    @State private var keyword = ""
    @State private var results: [SearchResultSection] = []
    @State private var isSearching = false
    @FocusState private var focused: Bool

    struct SearchResultSection: Identifiable {
        var id: String { title }
        var title: String
        var items: [MusicItem]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索歌曲、歌手、专辑", text: $keyword)
                        .focused($focused)
                        .submitLabel(.search)
                        .onSubmit { runSearch() }
                    if !keyword.isEmpty {
                        Button { keyword = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(AppTheme.secondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                List {
                    ForEach(results) { section in
                        Section(section.title) {
                            ForEach(section.items) { item in
                                TrackRow(item: item)
                                    .onTapGesture {
                                        player.play(queue: section.items, startIndex: section.items.firstIndex(of: item) ?? 0)
                                    }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .overlay {
                    if isSearching {
                        ProgressView("搜索中…")
                    } else if results.isEmpty && !keyword.isEmpty {
                        if #available(iOS 17.0, *) {
                            ContentUnavailableView("没有找到结果", systemImage: "magnifyingglass")
                        } else {
                            VStack(spacing: 8) {
                                Image(systemName: "magnifyingglass")
                                    .font(.largeTitle)
                                    .foregroundStyle(.secondary)
                                Text("没有找到结果").font(.headline)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                        }
                    }
                }
            }
            .navigationTitle("搜索")
        }
    }

    private func runSearch() {
        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        focused = false
        isSearching = true
        results = []
        Task {
            let sections = await SearchService.shared.search(keyword: key)
            results = sections
            isSearching = false
        }
    }
}

#Preview {
    SearchView()
}