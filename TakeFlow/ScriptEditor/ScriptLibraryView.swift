import SwiftUI

enum ScriptRoute: Hashable {
    case edit(UUID)
    case teleprompter(UUID)
    case cameraRecording(UUID)
}

struct ScriptLibraryView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
            .sheet(isPresented: deleteConfirmationBinding) {
                ScriptDeleteConfirmationView(
                    script: viewModel.requestedDeletion,
                    onCancel: viewModel.cancelDelete,
                    onDelete: {
                        Task {
                            await viewModel.confirmDelete()
                        }
                    }
                )
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
            scriptListRow(script)
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
    private func scriptListRow(_ script: Script) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                NavigationLink(value: ScriptRoute.edit(script.id)) {
                    ScriptRow(script: script)
                }
                .accessibilityIdentifier(
                    "script.row.\(script.id.uuidString)"
                )

                HStack(spacing: 16) {
                    Spacer(minLength: 0)
                    teleprompterButton(for: script)
                    cameraRecordingButton(for: script)
                    deleteButton(for: script)
                }
            }
        } else {
            HStack(spacing: 12) {
                NavigationLink(value: ScriptRoute.edit(script.id)) {
                    ScriptRow(script: script)
                }
                .accessibilityIdentifier(
                    "script.row.\(script.id.uuidString)"
                )

                teleprompterButton(for: script)
                cameraRecordingButton(for: script)
            }
        }
    }

    private func teleprompterButton(for script: Script) -> some View {
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
    }

    private func cameraRecordingButton(for script: Script) -> some View {
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

    private func deleteButton(for script: Script) -> some View {
        Button(role: .destructive) {
            viewModel.requestDelete(script)
        } label: {
            Image(systemName: "trash")
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(ScriptEditorStrings.delete)
        .accessibilityHint(ScriptEditorStrings.deleteAccessibilityHint)
        .accessibilityIdentifier(
            "script.delete.\(script.id.uuidString)"
        )
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

private struct ScriptDeleteConfirmationView: View {
    let script: Script?
    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {
                    Label(
                        ScriptEditorStrings.deleteTitle,
                        systemImage: "trash"
                    )
                    .font(.title2.bold())
                    .accessibilityIdentifier(
                        "script.deleteConfirmation.title"
                    )

                    if let script {
                        Text(visibleTitle(for: script))
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(
                                ScriptEditorStrings.deleteTarget(
                                    visibleTitle(for: script)
                                )
                            )
                    }

                    Text(ScriptEditorStrings.deleteMessage)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .scrollIndicators(.visible)

            Divider()

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    confirmationCancelButton
                    confirmationDeleteButton
                }

                VStack(spacing: 12) {
                    confirmationCancelButton
                    confirmationDeleteButton
                }
            }
            .padding()
            .background(.regularMaterial)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("script.deleteConfirmation")
    }

    private var confirmationCancelButton: some View {
        Button(ScriptEditorStrings.cancel, role: .cancel) {
            onCancel()
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity, minHeight: 44)
        .accessibilityLabel(ScriptEditorStrings.cancelDeletion)
        .accessibilityIdentifier("script.delete.cancel")
    }

    private var confirmationDeleteButton: some View {
        Button(ScriptEditorStrings.delete, role: .destructive) {
            onDelete()
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .frame(maxWidth: .infinity, minHeight: 44)
        .accessibilityLabel(ScriptEditorStrings.confirmDeletion)
        .accessibilityIdentifier("script.delete.confirm")
    }

    private func visibleTitle(for script: Script) -> String {
        let trimmed = script.title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmed.isEmpty
            ? ScriptEditorStrings.unnamedScript
            : trimmed
    }
}

private struct ScriptRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let script: Script

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(visibleTitle)
                .font(.headline)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)

            Text(summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)

            ViewThatFits(in: .horizontal) {
                HStack {
                    scriptMetrics
                    Spacer()
                    Text(script.updatedAt, style: .relative)
                }
                VStack(alignment: .leading, spacing: 2) {
                    scriptMetrics
                    Text(script.updatedAt, style: .relative)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var scriptMetrics: some View {
        Group {
            Text(
                ScriptEditorStrings.characterCount(
                    ScriptMetrics.characterCount(in: script.content)
                )
            )
            Text(
                ScriptEditorStrings.estimatedDuration(
                    formattedDuration
                )
            )
        }
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
