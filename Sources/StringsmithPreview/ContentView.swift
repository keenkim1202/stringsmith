import SwiftUI
import UniformTypeIdentifiers

/// 프로젝트 탭 + 선택된 프로젝트의 번역 화면.
struct ContentView: View {
    @ObservedObject var store: ProjectStore
    @State private var renaming: PreviewProject.ID?
    @State private var draftAlias = ""
    @State private var draggingProject: PreviewProject.ID?

    var body: some View {
        VStack(spacing: 0) {
            projectTabs
            Divider()
            if let project = store.selected {
                // 탭을 바꾸면 화면 상태(검색어·필터)를 새로 시작하도록 id 를 준다.
                TranslationView(project: project)
                    .id(project.id)
            } else {
                EmptyProjectsView { store.addWithPicker() }
            }
        }
    }

    // MARK: 프로젝트 탭

    private var projectTabs: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(store.projects) { project in
                        tab(project)
                    }
                }
                .padding(.horizontal, 8)
            }
            Divider().frame(height: 22)
            Button {
                store.addWithPicker()
            } label: {
                Image(systemName: "plus")
                    .frame(width: 28, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("project.add"))
        }
        .frame(height: 34)
    }

    @ViewBuilder
    private func tab(_ project: PreviewProject) -> some View {
        let selected = store.selection == project.id

        // 선택은 **Button** 으로 받는다. 평범한 뷰에 `.onTapGesture` 를 붙이면
        // 같이 붙인 `.onDrag` 가 클릭을 삼켜 탭이 바뀌지 않는다.
        Button {
            store.selection = project.id
        } label: {
            HStack(spacing: 5) {
                if renaming == project.id {
                    TextField(
                        "", text: $draftAlias,
                        onCommit: {
                            store.rename(project.id, to: draftAlias)
                            renaming = nil
                        }
                    )
                    .textFieldStyle(.plain)
                    .frame(width: 110)
                    .onExitCommand { renaming = nil }
                } else {
                    Text(project.displayName)
                        .foregroundStyle(selected ? Color.accentColor : .primary)
                }
                if selected, renaming != project.id {
                    Button {
                        store.remove(project.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L("project.remove"))
                }
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                selected ? Color.accentColor.opacity(0.15) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
            .opacity(draggingProject == project.id ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .help(project.configPath)
        .simultaneousGesture(TapGesture(count: 2).onEnded { startRename(project) })
        .contextMenu {
            Button(L("project.rename")) { startRename(project) }
            Button(L("project.revealInFinder")) {
                NSWorkspace.shared.selectFile(project.configPath, inFileViewerRootedAtPath: "")
            }
            Divider()
            Button(L("project.remove"), role: .destructive) { store.remove(project.id) }
        }
        .onDrag {
            draggingProject = project.id
            return NSItemProvider(object: project.id.uuidString as NSString)
        }
        .onDrop(of: [.text], isTargeted: nil) { _ in
            guard let dragging = draggingProject else { return false }
            store.move(dragging, onto: project.id)
            draggingProject = nil
            return true
        }
    }

    private func startRename(_ project: PreviewProject) {
        draftAlias = project.alias ?? project.displayName
        renaming = project.id
    }
}

// MARK: - 프로젝트가 없을 때

struct EmptyProjectsView: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(L("empty.noProjects")).font(.headline)
            Text(L("empty.noProjectsDetail"))
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(L("project.add"), action: onAdd)
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
