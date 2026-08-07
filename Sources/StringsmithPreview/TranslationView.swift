import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 한 프로젝트의 번역을 언어별로 나란히 보여준다.
struct TranslationView: View {
    let project: PreviewProject

    @State private var snapshot: ProjectSnapshot?
    @State private var loadError: String?
    @State private var loading = false

    @State private var search = ""
    @State private var enabledLocales: Set<String> = []
    @State private var missingOnly = false
    @State private var variablesOnly = false
    /// 변수를 치환하지 않고 `{name}` 원본 표기 그대로 보여준다.
    @State private var showRaw = false
    @State private var selectedGroup: String?
    /// 사용자가 정한 언어 표시 순서. 쉼표로 이어 저장한다.
    @AppStorage("localeOrder") private var storedOrder = ""
    @State private var draggingLocale: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: project.id) { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .stringsmithRefresh)) { _ in
            Task { await reload() }
        }
    }

    // MARK: 읽기

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                [path = project.configPath] in
                try ProjectSnapshot.load(configPath: path)
            }.value
            snapshot = loaded
            loadError = nil
            if enabledLocales.isEmpty { enabledLocales = Set(loaded.locales) }
        } catch {
            loadError = "\(error)"
        }
    }

    // MARK: 상단

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("search.placeholder"), text: $search)
                    .textFieldStyle(.plain)
                Spacer()
                Toggle(L("filter.variablesOnly"), isOn: $variablesOnly).toggleStyle(.checkbox)
                Toggle(L("filter.missingOnly"), isOn: $missingOnly).toggleStyle(.checkbox)
                Toggle(L("filter.showRaw"), isOn: $showRaw).toggleStyle(.checkbox)
                Text("\(visibleCount) / \(snapshot?.entries.count ?? 0)")
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    Task { await reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(loading)
                .help(L("action.refresh"))
            }
            HStack(spacing: 6) {
                Text(L("language.label")).font(.caption).foregroundStyle(.secondary)
                ForEach(orderedLocales, id: \.self) { locale in
                    Button {
                        if enabledLocales.contains(locale) {
                            // 마지막 하나는 끄지 않는다 — 빈 화면이 되면 곤란하다
                            if enabledLocales.count > 1 { enabledLocales.remove(locale) }
                        } else {
                            enabledLocales.insert(locale)
                        }
                    } label: {
                        Chip(text: locale, selected: enabledLocales.contains(locale))
                            .opacity(draggingLocale == locale ? 0.4 : 1)
                    }
                    .buttonStyle(.plain)
                    .help(L("language.reorderHint"))
                    .onDrag {
                        draggingLocale = locale
                        return NSItemProvider(object: locale as NSString)
                    }
                    .onDrop(of: [.text], isTargeted: nil) { _ in
                        guard let dragging = draggingLocale else { return false }
                        move(dragging, onto: locale)
                        draggingLocale = nil
                        return true
                    }
                }
                Spacer()
                if let snapshot {
                    Text(Self.timeFormatter.string(from: snapshot.loadedAt))
                        .font(.caption2).foregroundStyle(.tertiary)
                        .help(snapshot.sheetPath)
                }
                Button(L("language.all")) { enabledLocales = Set(snapshot?.locales ?? []) }
                    .buttonStyle(.link).font(.caption)
                Button(L("language.sourceOnly")) {
                    if let source = snapshot?.sourceLocale { enabledLocales = [source] }
                }
                .buttonStyle(.link).font(.caption)
                Button(L("language.resetOrder"), action: resetOrder)
                    .buttonStyle(.link).font(.caption)
            }
        }
        .padding(12)
    }

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    // MARK: 본문

    @ViewBuilder
    private var content: some View {
        if let loadError {
            LoadErrorView(path: project.configPath, message: loadError) {
                Task { await reload() }
            }
        } else if snapshot == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    if let warnings = snapshot?.warnings, !warnings.isEmpty {
                        WarningBar(warnings: warnings)
                        Divider()
                    }
                    sectionTabs(proxy)
                    Divider()
                    list
                }
            }
        }
    }

    /// 섹션 이동용 가로 탭. 누르면 해당 섹션으로 스크롤한다.
    private func sectionTabs(_ proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(grouped, id: \.0) { group, entries in
                    Button {
                        selectedGroup = group
                        // 상태 변경으로 목록이 다시 그려진 **뒤에** 스크롤해야 한다.
                        // 같은 사이클에서 부르면 옛 레이아웃 기준이라 반영되지 않는다.
                        DispatchQueue.main.async {
                            withAnimation(.easeOut(duration: 0.25)) {
                                proxy.scrollTo(Self.anchor(group), anchor: .top)
                            }
                        }
                    } label: {
                        SectionTab(
                            title: group, count: entries.count, selected: selectedGroup == group)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 30)
    }

    /// - Note: `pinnedViews: [.sectionHeaders]` 를 쓰면 안 된다. 머리글이 상단에 고정되어
    ///   이미 보이는 상태이므로 `scrollTo(group)` 이 "이동할 필요 없음"으로 판단해
    ///   **탭을 눌러도 스크롤되지 않는다.** 탭바가 이미 위치 표시 역할을 한다.
    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(grouped, id: \.0) { group, entries in
                    Section {
                        ForEach(entries) { entry in
                            EntryRow(
                                entry: entry,
                                locales: visibleLocales,
                                sourceLocale: snapshot?.sourceLocale ?? "",
                                showRaw: showRaw
                            )
                            Divider()
                        }
                    } header: {
                        Text(group)
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.background)
                            .id(Self.anchor(group))
                    }
                }
            }
        }
    }

    // MARK: 계산

    /// 스크롤 대상 식별자.
    ///
    /// `ForEach(grouped, id: \.0)` 이 그룹 이름을 이미 행 식별자로 쓰고 있어,
    /// 머리글에 같은 값을 `.id()` 로 주면 대상이 겹쳐 `scrollTo` 가 엉뚱하게 동작한다.
    static func anchor(_ group: String) -> String { "section:" + group }

    /// 표시 순서. 저장된 순서를 먼저 쓰고, 거기 없는 언어는 뒤에 붙인다.
    private var orderedLocales: [String] {
        let all = snapshot?.locales ?? []
        let saved = storedOrder.split(separator: ",").map(String.init)
        let known = saved.filter { all.contains($0) }
        return known + all.filter { !known.contains($0) }
    }

    private var visibleLocales: [String] {
        orderedLocales.filter { enabledLocales.contains($0) }
    }

    private func move(_ locale: String, onto target: String) {
        guard locale != target else { return }
        var order = orderedLocales
        guard let from = order.firstIndex(of: locale), let to = order.firstIndex(of: target)
        else { return }
        order.remove(at: from)
        // 제거 후 인덱스가 밀리므로 좌우 어느 쪽으로 옮기든 `to` 가 맞는 자리가 된다.
        order.insert(locale, at: to)
        storedOrder = order.joined(separator: ",")
    }

    private func resetOrder() {
        guard let snapshot else { return }
        let rest = snapshot.locales.filter { $0 != snapshot.sourceLocale }.sorted()
        storedOrder = ([snapshot.sourceLocale] + rest).joined(separator: ",")
    }

    private func matches(_ entry: ProjectSnapshot.Entry) -> Bool {
        if variablesOnly, !entry.hasVariables { return false }
        if missingOnly, !isMissing(entry) { return false }
        guard !search.isEmpty else { return true }
        if entry.key.localizedCaseInsensitiveContains(search) { return true }
        return entry.values.values.contains { $0.localizedCaseInsensitiveContains(search) }
    }

    private func isMissing(_ entry: ProjectSnapshot.Entry) -> Bool {
        (snapshot?.locales ?? []).contains { entry.isMissing($0) }
    }

    private var grouped: [(String, [ProjectSnapshot.Entry])] {
        let fallback = L("group.other")
        let kept = (snapshot?.entries ?? []).filter(matches)
        return Dictionary(grouping: kept, by: { $0.group(fallback: fallback) })
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value.sorted { $0.key < $1.key }) }
    }

    private var visibleCount: Int { grouped.reduce(0) { $0 + $1.1.count } }
}

// MARK: - 부속 뷰

struct WarningBar: View {
    let warnings: [String]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("\(warnings.count)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(warnings[0]).font(.caption).lineLimit(1)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(warnings.indices, id: \.self) { index in
                    Text(warnings[index])
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.orange.opacity(0.08))
    }
}

struct LoadErrorView: View {
    let path: String
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30)).foregroundStyle(.orange)
            Text(L("error.loadFailed")).font(.headline)
            Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            ScrollView {
                Text(message)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            .padding(8)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            Button(L("action.refresh"), action: onRetry)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 언어 선택용. **여러 개를 켜고 끄는** 성격이라 테두리 있는 캡슐로 둔다.
struct Chip: View {
    let text: String
    let selected: Bool

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(
                selected ? Color.accentColor.opacity(0.2) : Color.clear, in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(
                    selected ? Color.accentColor : Color.secondary.opacity(0.35))
            )
    }
}

/// 섹션 이동용. 캡슐로 만들면 언어 칩과 똑같이 보여 **다중 선택처럼 오해**된다.
/// 하나만 가리키는 위치 표시이므로 밑줄 탭으로 구분한다.
struct SectionTab: View {
    let title: String
    let count: Int
    let selected: Bool

    var body: some View {
        VStack(spacing: 3) {
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Text(title).foregroundStyle(selected ? Color.accentColor : .primary)
                Text("\(count)").foregroundStyle(.secondary)
            }
            .font(.caption)
            Rectangle()
                .fill(selected ? Color.accentColor : Color.clear)
                .frame(height: 2)
        }
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }
}

// MARK: - 항목 한 줄

struct EntryRow: View {
    let entry: ProjectSnapshot.Entry
    let locales: [String]
    let sourceLocale: String
    let showRaw: Bool

    /// 입력값을 **행 안에** 둔다.
    ///
    /// 상위 뷰의 상태로 올리면 한 글자 칠 때마다 목록 전체가 다시 그려지며
    /// 텍스트필드가 포커스를 잃는다. 항목이 수백 개면 사실상 입력이 안 된다.
    @State private var arguments: [String]

    init(entry: ProjectSnapshot.Entry, locales: [String], sourceLocale: String, showRaw: Bool) {
        self.entry = entry
        self.locales = locales
        self.sourceLocale = sourceLocale
        self.showRaw = showRaw
        _arguments = State(initialValue: Array(repeating: "", count: entry.placeholders.count))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(entry.key)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let comment = entry.comment, !comment.isEmpty {
                    Text(comment).font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
            }

            ForEach(locales, id: \.self) { locale in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(locale)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(locale == sourceLocale ? .primary : .secondary)
                        .frame(width: 56, alignment: .leading)
                    if showRaw, let raw = entry.rawValues[locale], !raw.isEmpty {
                        // 원본 표기는 시트에 적힌 그대로 보여준다 (치환·색 없음).
                        Text(raw)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                    } else if !showRaw,
                        let value = attributed(locale: locale)
                    {
                        Text(value).textSelection(.enabled)
                    } else {
                        Text(L("entry.noTranslation"))
                            .foregroundStyle(.red.opacity(0.8)).font(.callout)
                    }
                }
            }

            if !entry.placeholders.isEmpty, !showRaw {
                HStack(spacing: 8) {
                    Text(L("entry.variables")).font(.caption2).foregroundStyle(.secondary)
                    ForEach(entry.placeholders.indices, id: \.self) { index in
                        HStack(spacing: 4) {
                            Text(entry.placeholders[index])
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(Color.accentColor)
                            TextField(entry.placeholders[index], text: $arguments[index])
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 110)
                        }
                    }
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// 입력값을 채운 문자열. **변수 자리에는 색을 입혀** 어디가 치환됐는지 보이게 한다.
    ///
    /// `String(format:)` 을 쓰면 어느 부분이 변수였는지 알 수 없으므로 포맷 문자열을
    /// 직접 훑으며 조각을 이어 붙인다. stringsmith 는 `%@` 와 `%N$@` 만 내보내므로 단순하다.
    private func attributed(locale: String) -> AttributedString? {
        guard let format = entry.values[locale], !format.isEmpty else { return nil }
        guard !entry.placeholders.isEmpty else { return AttributedString(format) }

        let chars = Array(format)
        var result = AttributedString()
        var plain = ""
        var autoIndex = 0
        var i = 0

        func flush() {
            if !plain.isEmpty {
                result += AttributedString(plain)
                plain = ""
            }
        }

        while i < chars.count {
            guard chars[i] == "%", i + 1 < chars.count else {
                plain.append(chars[i])
                i += 1
                continue
            }
            if chars[i + 1] == "%" {
                plain.append("%")
                i += 2
                continue
            }

            var index: Int
            var next: Int
            var digits = ""
            var j = i + 1
            while j < chars.count, chars[j].isNumber {
                digits.append(chars[j])
                j += 1
            }
            if !digits.isEmpty, j + 1 < chars.count, chars[j] == "$", chars[j + 1] == "@" {
                index = (Int(digits) ?? 1) - 1
                next = j + 2
            } else if chars[i + 1] == "@" {
                index = autoIndex
                autoIndex += 1
                next = i + 2
            } else {
                plain.append(chars[i])
                i += 1
                continue
            }

            flush()
            let filled =
                index < arguments.count && !arguments[index].isEmpty
                ? arguments[index]
                : (index < entry.placeholders.count ? entry.placeholders[index] : "?")
            var run = AttributedString(filled)
            run.foregroundColor = .accentColor
            run.backgroundColor = Color.accentColor.opacity(0.18)
            result += run
            i = next
        }
        flush()
        return result
    }
}
