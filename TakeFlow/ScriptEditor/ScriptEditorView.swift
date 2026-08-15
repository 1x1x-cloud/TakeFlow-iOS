import SwiftUI

struct ScriptEditorView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var viewModel: ScriptEditorViewModel

    init(scriptID: UUID, service: any ScriptLibraryServicing) {
        _viewModel = StateObject(
            wrappedValue: ScriptEditorViewModel(
                scriptID: scriptID,
                service: service
            )
        )
    }

    var body: some View {
        Group {
            if viewModel.isLoading {
                ProgressView(ScriptEditorStrings.loading)
            } else {
                editor
            }
        }
        .navigationTitle(viewModel.visibleTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.load()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                Task {
                    await viewModel.flushPendingSave()
                }
            }
        }
        .onDisappear {
            Task {
                await viewModel.flushPendingSave()
            }
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
    }

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TextField(
                    ScriptEditorStrings.titlePlaceholder,
                    text: Binding(
                        get: { viewModel.title },
                        set: { viewModel.setTitle($0) }
                    )
                )
                .font(.title2.bold())
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("editor.title")

                ZStack(alignment: .topLeading) {
                    TextEditor(
                        text: Binding(
                            get: { viewModel.content },
                            set: { viewModel.setContent($0) }
                        )
                    )
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 360)
                    .padding(4)
                    .accessibilityIdentifier("editor.content")

                    if viewModel.content.isEmpty {
                        Text(ScriptEditorStrings.contentPlaceholder)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 13)
                            .allowsHitTesting(false)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(uiColor: .secondarySystemBackground))
                )

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        editorMetrics
                        Spacer()
                        saveStatus
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        editorMetrics
                        saveStatus
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                Divider()

                VStack(alignment: .leading, spacing: 14) {
                    Text(ScriptEditorStrings.settings)
                        .font(.headline)

                    ViewThatFits(in: .horizontal) {
                        HStack {
                            Text(ScriptEditorStrings.speechRate)
                            Spacer()
                            Text(
                                ScriptEditorStrings.speechRate(
                                    Int(viewModel.speechRateCharactersPerMinute)
                                )
                            )
                            .foregroundStyle(.secondary)
                            speechRateButtons
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text(ScriptEditorStrings.speechRate)
                            Text(
                                ScriptEditorStrings.speechRate(
                                    Int(viewModel.speechRateCharactersPerMinute)
                                )
                            )
                            .foregroundStyle(.secondary)
                            speechRateButtons
                        }
                    }
                    .accessibilityIdentifier("editor.speechRate")

                    VStack(alignment: .leading, spacing: 8) {
                        ViewThatFits(in: .horizontal) {
                            HStack {
                                Text(ScriptEditorStrings.readPosition)
                                Spacer()
                                readPositionText
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(ScriptEditorStrings.readPosition)
                                readPositionText
                            }
                        }

                        ProgressView(
                            value: Double(viewModel.lastReadPosition),
                            total: Double(max(viewModel.content.count, 1))
                        )
                        .accessibilityIdentifier("editor.readPosition")

                        ViewThatFits(in: .horizontal) {
                            HStack {
                                readPositionBackwardButton
                                Spacer()
                                readPositionForwardButton
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                readPositionBackwardButton
                                readPositionForwardButton
                            }
                        }
                        .font(.footnote)
                    }
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(uiColor: .secondarySystemBackground))
                )
            }
            .padding()
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.visible)
        .accessibilityIdentifier("editor.scrollView")
        .alert(
            ScriptEditorStrings.recoveryTitle,
            isPresented: recoveryBinding
        ) {
            Button(ScriptEditorStrings.recoverDraft) {
                viewModel.recoverPendingDraft()
            }
            Button(
                ScriptEditorStrings.keepSavedVersion,
                role: .destructive
            ) {
                Task {
                    await viewModel.keepSavedVersion()
                }
            }
        } message: {
            Text(ScriptEditorStrings.recoveryMessage)
        }
    }

    private var editorMetrics: some View {
        Group {
            Label(
                ScriptEditorStrings.characterCount(
                    viewModel.characterCount
                ),
                systemImage: "character.cursor.ibeam"
            )
            Label(
                ScriptEditorStrings.estimatedDuration(
                    ScriptDurationFormatter.string(
                        from: viewModel.estimatedDuration
                    )
                ),
                systemImage: "clock"
            )
        }
    }

    private var saveStatus: some View {
        Text(viewModel.saveStateText)
            .foregroundStyle(saveStateColor)
            .accessibilityIdentifier("editor.saveStatus")
    }

    private var speechRateButtons: some View {
        HStack(spacing: dynamicTypeSize.isAccessibilitySize ? 16 : 8) {
            Button {
                viewModel.setSpeechRate(
                    viewModel.speechRateCharactersPerMinute - 10
                )
            } label: {
                Image(systemName: "minus.circle")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(
                viewModel.speechRateCharactersPerMinute
                    <= ScriptMetrics.minimumSpeechRate
            )
            .accessibilityLabel(
                ScriptEditorStrings.decreaseSpeechRate
            )

            Button {
                viewModel.setSpeechRate(
                    viewModel.speechRateCharactersPerMinute + 10
                )
            } label: {
                Image(systemName: "plus.circle")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(
                viewModel.speechRateCharactersPerMinute
                    >= ScriptMetrics.maximumSpeechRate
            )
            .accessibilityLabel(
                ScriptEditorStrings.increaseSpeechRate
            )
        }
    }

    private var readPositionText: some View {
        Text(
            ScriptEditorStrings.readPosition(
                viewModel.lastReadPosition,
                total: viewModel.content.count
            )
        )
        .foregroundStyle(.secondary)
    }

    private var readPositionBackwardButton: some View {
        Button {
            viewModel.setLastReadPosition(
                viewModel.lastReadPosition - 10
            )
        } label: {
            Label(
                ScriptEditorStrings.moveReadPositionBackward,
                systemImage: "gobackward.10"
            )
            .frame(minHeight: 44)
        }
        .disabled(viewModel.lastReadPosition == 0)
    }

    private var readPositionForwardButton: some View {
        Button {
            viewModel.setLastReadPosition(
                viewModel.lastReadPosition + 10
            )
        } label: {
            Label(
                ScriptEditorStrings.moveReadPositionForward,
                systemImage: "goforward.10"
            )
            .frame(minHeight: 44)
        }
        .disabled(
            viewModel.lastReadPosition
                >= viewModel.content.count
        )
    }

    private var saveStateColor: Color {
        viewModel.saveState == .failed ? .red : .secondary
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

    private var recoveryBinding: Binding<Bool> {
        Binding(
            get: { viewModel.pendingRecoveryDraft != nil },
            set: { _ in }
        )
    }
}
