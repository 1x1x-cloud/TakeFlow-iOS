import SwiftUI

enum ScriptRoute: Hashable {
    case edit(UUID)
    case teleprompter(UUID)
    case cameraRecording(UUID)
}

struct ScriptLibraryView: View {
    private let service: any TakeFlowServicing
    private let cameraRecordingDependencies:
        CameraRecordingDependencies
    @StateObject private var viewModel: ScriptLibraryViewModel
    @State private var path: [ScriptRoute] = []

    init(
        service: any TakeFlowServicing,
        cameraRecordingDependencies:
            CameraRecordingDependencies
    ) {
        self.service = service
        self.cameraRecordingDependencies =
            cameraRecordingDependencies
        _viewModel = StateObject(
            wrappedValue: ScriptLibraryViewModel(service: service)
        )
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if viewModel.scripts.isEmpty, !viewModel.isLoading {
                    emptyState
                } else {
                    scriptList
                }
            }
            .navigationTitle(ScriptEditorStrings.libraryTitle)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task {
                            if let id = await viewModel.createBlankScript() {
                                path.append(.edit(id))
                            }
                        }
                    } label: {
                        Label(
                            ScriptEditorStrings.addScript,
                            systemImage: "square.and.pencil"
                        )
                    }
                    .accessibilityIdentifier("script.add")
                }
            }
            .searchable(
                text: $viewModel.searchText,
                prompt: ScriptEditorStrings.searchPrompt
            )
            .navigationDestination(for: ScriptRoute.self) { route in
                switch route {
                case .edit(let scriptID):
                    ScriptEditorView(scriptID: scriptID, service: service)
                case .teleprompter(let scriptID):
                    TeleprompterView(
                        scriptID: scriptID,
                        service: service
                    )
                case .cameraRecording(let scriptID):
                    CameraRecordingView(
                        scriptID: scriptID,
                        service: service,
                        dependencies:
                            cameraRecordingDependencies
                    )
                }
            }
            .overlay {
                if viewModel.isLoading {
                    ProgressView()
                        .accessibilityLabel(ScriptEditorStrings.loading)
                }
            }
            .safeAreaInset(edge: .bottom) {
                undoBanner
            }
            .confirmationDialog(
                ScriptEditorStrings.deleteTitle,
                isPresented: deleteConfirmationBinding,
                titleVisibility: .visible
            ) {
                Button(ScriptEditorStrings.delete, role: .destructive) {
                    Task {
                        await viewModel.confirmDelete()
                    }
                }
                Button(ScriptEditorStrings.cancel, role: .cancel) {
                    viewModel.cancelDelete()
                }
            } message: {
                Text(ScriptEditorStrings.deleteMessage)
            }
            .alert(
                ScriptEditorStrings.errorTitle,
                isPresented: errorBinding
            ) {
                Button(ScriptEditorStrings.dismiss) {
                    viewModel.dismissError()
                }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .task {
                await viewModel.load()
            }
        }
    }

    private var scriptList: some View {
        List(viewModel.scripts) { script in
            HStack(spacing: 12) {
                NavigationLink(value: ScriptRoute.edit(script.id)) {
                    ScriptRow(script: script)
                }
                .accessibilityIdentifier(
                    "script.row.\(script.id.uuidString)"
                )

                Button {
                    path.append(.teleprompter(script.id))
                } label: {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(TeleprompterStrings.title)
                .accessibilityIdentifier(
                    "teleprompter.open.\(script.id.uuidString)"
                )

                Button {
                    path.append(.cameraRecording(script.id))
                } label: {
                    Image(systemName: "video.fill")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(CameraRecordingStrings.title)
                .accessibilityIdentifier(
                    "capture.open.\(script.id.uuidString)"
                )
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    viewModel.requestDelete(script)
                } label: {
                    Label(ScriptEditorStrings.delete, systemImage: "trash")
                }

                Button {
                    Task {
                        await viewModel.duplicate(script)
                    }
                } label: {
                    Label(
                        ScriptEditorStrings.duplicate,
                        systemImage: "doc.on.doc"
                    )
                }
                .tint(.blue)
            }
            .contextMenu {
                Button {
                    Task {
                        await viewModel.duplicate(script)
                    }
                } label: {
                    Label(
                        ScriptEditorStrings.duplicate,
                        systemImage: "doc.on.doc"
                    )
                }

                Button(role: .destructive) {
                    viewModel.requestDelete(script)
                } label: {
                    Label(ScriptEditorStrings.delete, systemImage: "trash")
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private var emptyState: some View {
        if viewModel.hasSearchQuery {
            ContentUnavailableView.search(text: viewModel.searchText)
                .accessibilityIdentifier("script.search.empty")
        } else {
            ContentUnavailableView {
                Label(
                    ScriptEditorStrings.emptyLibraryTitle,
                    systemImage: "doc.text"
                )
                .accessibilityIdentifier("script.empty.title")
            } description: {
                Text(ScriptEditorStrings.emptyLibraryDescription)
            } actions: {
                Button(ScriptEditorStrings.addScript) {
                    Task {
                        if let id = await viewModel.createBlankScript() {
                            path.append(.edit(id))
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("script.empty.add")
            }
        }
    }

    @ViewBuilder
    private var undoBanner: some View {
        if viewModel.pendingDeletion != nil {
            HStack(spacing: 16) {
                Text(ScriptEditorStrings.deleted)
                Spacer()
                Button(ScriptEditorStrings.undo) {
                    Task {
                        await viewModel.undoDelete()
                    }
                }
                .fontWeight(.semibold)
                .accessibilityIdentifier("script.undo")
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(.regularMaterial)
        }
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isDeleteConfirmationPresented },
            set: { isPresented in
                if !isPresented {
                    viewModel.dismissDeleteConfirmation()
                }
            }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.dismissError()
                }
            }
        )
    }
}

private struct ScriptRow: View {
    let script: Script

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(visibleTitle)
                .font(.headline)
                .lineLimit(1)

            Text(summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack {
                Text(
                    ScriptEditorStrings.characterCount(
                        ScriptMetrics.characterCount(in: script.content)
                    )
                )
                Text(ScriptEditorStrings.estimatedDuration(formattedDuration))
                Spacer()
                Text(script.updatedAt, style: .relative)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var visibleTitle: String {
        let trimmed = script.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? ScriptEditorStrings.unnamedScript : trimmed
    }

    private var summary: String {
        let trimmed = script.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? ScriptEditorStrings.emptyContent : trimmed
    }

    private var formattedDuration: String {
        ScriptDurationFormatter.string(from: script.estimatedDuration)
    }
}

enum ScriptDurationFormatter {
    static func string(from duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60

        if minutes == 0 {
            return "\(seconds) 秒"
        }
        if seconds == 0 {
            return "\(minutes) 分钟"
        }
        return "\(minutes) 分 \(seconds) 秒"
    }
}
