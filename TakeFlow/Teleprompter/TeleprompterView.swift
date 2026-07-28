import SwiftUI

struct TeleprompterView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var viewModel: TeleprompterViewModel
    @State private var isSettingsPresented = false

    init(
        scriptID: UUID,
        service: any TeleprompterScriptProviding
    ) {
        _viewModel = StateObject(
            wrappedValue: TeleprompterViewModel(
                scriptID: scriptID,
                service: service
            )
        )
    }

    var body: some View {
        GeometryReader { geometry in
            TimelineView(
                .animation(
                    minimumInterval: 1.0 / 120.0,
                    paused: !needsClockUpdates
                )
            ) { timeline in
                ZStack {
                    backgroundColor.ignoresSafeArea()

                    if viewModel.isLoading {
                        ProgressView()
                            .tint(foregroundColor)
                            .accessibilityLabel(
                                TeleprompterStrings.loading
                            )
                    } else if viewModel.isEmpty {
                        emptyState
                    } else if let document = viewModel.document {
                        promptText(
                            document: document,
                            in: geometry
                        )
                    } else {
                        ProgressView()
                            .tint(foregroundColor)
                            .accessibilityLabel(
                                TeleprompterStrings.loading
                            )
                    }

                    countdownOverlay

                    if viewModel.areControlsVisible {
                        controls
                    } else {
                        restoreControlsButton
                    }
                }
                .onChange(of: timeline.date) {
                    viewModel.tick()
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(
            viewModel.preferences.appearance == .dark ? .dark : .light
        )
        .sheet(isPresented: $isSettingsPresented) {
            settingsSheet
        }
        .alert(
            TeleprompterStrings.errorTitle,
            isPresented: errorBinding
        ) {
            Button(TeleprompterStrings.reload) {
                Task {
                    await viewModel.reload()
                }
            }
            Button(ScriptEditorStrings.dismiss, role: .cancel) {
                viewModel.dismissError()
            }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .task {
            await viewModel.load()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                viewModel.sceneDidEnterBackground()
            case .active:
                Task {
                    await viewModel.sceneDidBecomeActive()
                }
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .onDisappear {
            viewModel.viewDidDisappear()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("teleprompter.screen")
    }

    private func promptText(
        document: TeleprompterDocument,
        in geometry: GeometryProxy
    ) -> some View {
        TeleprompterTextView(
            document: document,
            preferences: viewModel.preferences,
            targetOffset: viewModel.scrollOffset,
            anchor: viewModel.anchor,
            layoutRevision: viewModel.layoutRevision,
            foregroundColor: UIColor(foregroundColor),
            onTapped: toggleControls,
            onDragStarted: viewModel.beginDragging,
            onDragChanged: viewModel.updateDragging,
            onDragEnded: viewModel.endDragging,
            onVisibleAnchorChanged: viewModel.visibleAnchorChanged,
            onLayoutResolved: viewModel.layoutResolved
        )
        .frame(
            width: geometry.size.width
                * viewModel.preferences.textAreaWidthFraction
        )
        .offset(
            y: geometry.size.height
                * viewModel.preferences.verticalPosition
        )
        .scaleEffect(
            x: viewModel.preferences.isHorizontallyMirrored ? -1 : 1,
            y: viewModel.preferences.isVerticallyMirrored ? -1 : 1
        )
        .accessibilityAction(
            named: TeleprompterStrings.showControls
        ) {
            viewModel.areControlsVisible = true
        }
    }

    private var controls: some View {
        VStack {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel(ScriptEditorStrings.cancel)
                .accessibilityIdentifier("teleprompter.close")

                Spacer()

                Text(viewModel.state.accessibilityDescription)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("teleprompter.state")

                Spacer()

                Button {
                    isSettingsPresented = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel(TeleprompterStrings.settings)
                .accessibilityIdentifier("teleprompter.settings")
            }
            .padding(.horizontal)
            .background(.ultraThinMaterial)

            Spacer()

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    primaryButton
                    restartButton
                }
                VStack(spacing: 10) {
                    primaryButton
                    restartButton
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)
        }
        .transition(reduceMotion ? .identity : .opacity)
    }

    private var primaryButton: some View {
        Button {
            viewModel.primaryAction()
        } label: {
            Label(primaryButtonTitle, systemImage: primaryButtonIcon)
                .frame(minWidth: 120, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityLabel(primaryButtonTitle)
        .accessibilityValue(viewModel.state.accessibilityDescription)
        .accessibilityIdentifier("teleprompter.primary")
        .disabled(!isPrimaryActionAvailable)
    }

    private var restartButton: some View {
        Button {
            viewModel.restart()
        } label: {
            Label(
                TeleprompterStrings.restart,
                systemImage: "backward.end.fill"
            )
            .frame(minWidth: 120, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(TeleprompterStrings.restart)
        .accessibilityIdentifier("teleprompter.restart")
    }

    private var restoreControlsButton: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    viewModel.areControlsVisible = true
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(.title)
                        .frame(minWidth: 52, minHeight: 52)
                }
                .accessibilityLabel(TeleprompterStrings.showControls)
                .accessibilityHint(
                    TeleprompterStrings.showControlsHint
                )
                .accessibilityIdentifier("teleprompter.showControls")
            }
            Spacer()
        }
        .padding()
    }

    @ViewBuilder
    private var countdownOverlay: some View {
        if case .countingDown(let remainingSeconds) = viewModel.state {
            Text("\(remainingSeconds)")
                .font(.system(size: 96, weight: .bold, design: .rounded))
                .foregroundStyle(foregroundColor)
                .accessibilityLabel(
                    TeleprompterStrings.countdownState(remainingSeconds)
                )
                .accessibilityIdentifier("teleprompter.countdown")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                TeleprompterStrings.emptyTitle,
                systemImage: "doc.text.magnifyingglass"
            )
        } description: {
            Text(TeleprompterStrings.emptyDescription)
        }
        .foregroundStyle(foregroundColor)
        .accessibilityIdentifier("teleprompter.empty")
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section(TeleprompterStrings.countdown) {
                    Picker(
                        TeleprompterStrings.countdown,
                        selection: countdownBinding
                    ) {
                        ForEach(
                            TeleprompterPreferences.supportedCountdowns,
                            id: \.self
                        ) { seconds in
                            Text(
                                "\(seconds) \(TeleprompterStrings.seconds)"
                            )
                            .tag(seconds)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier(
                        "teleprompter.countdownSetting"
                    )
                }

                Section(TeleprompterStrings.settings) {
                    preferenceSlider(
                        title: TeleprompterStrings.fontSize,
                        value: fontSizeBinding,
                        range:
                            TeleprompterPreferences.minimumFontSize
                            ... TeleprompterPreferences.maximumFontSize,
                        valueDescription: TeleprompterStrings.points,
                        identifier: "teleprompter.fontSize"
                    )
                    preferenceSlider(
                        title: TeleprompterStrings.lineSpacing,
                        value: lineSpacingBinding,
                        range:
                            TeleprompterPreferences.minimumLineSpacing
                            ... TeleprompterPreferences.maximumLineSpacing,
                        valueDescription: TeleprompterStrings.points,
                        identifier: "teleprompter.lineSpacing"
                    )
                    preferenceSlider(
                        title: TeleprompterStrings.scrollSpeed,
                        value: speedBinding,
                        range:
                            TeleprompterPreferences.minimumScrollSpeed
                            ... TeleprompterPreferences.maximumScrollSpeed,
                        valueDescription:
                            TeleprompterStrings.pointsPerSecond,
                        identifier: "teleprompter.speed"
                    )
                    preferenceSlider(
                        title: TeleprompterStrings.horizontalMargin,
                        value: marginBinding,
                        range:
                            TeleprompterPreferences.minimumHorizontalMargin
                            ... TeleprompterPreferences.maximumHorizontalMargin,
                        valueDescription: TeleprompterStrings.points,
                        identifier: "teleprompter.margin"
                    )
                    preferenceSlider(
                        title: TeleprompterStrings.textAreaWidth,
                        value: widthBinding,
                        range:
                            TeleprompterPreferences
                                .minimumTextAreaWidthFraction
                            ... TeleprompterPreferences
                                .maximumTextAreaWidthFraction,
                        valueDescription: TeleprompterStrings.percentage,
                        identifier: "teleprompter.width"
                    )
                    preferenceSlider(
                        title: TeleprompterStrings.verticalPosition,
                        value: verticalPositionBinding,
                        range:
                            TeleprompterPreferences.minimumVerticalPosition
                            ... TeleprompterPreferences.maximumVerticalPosition,
                        valueDescription: TeleprompterStrings.percentage,
                        identifier: "teleprompter.verticalPosition"
                    )
                }

                Section(TeleprompterStrings.appearance) {
                    Picker(
                        TeleprompterStrings.appearance,
                        selection: appearanceBinding
                    ) {
                        Text(TeleprompterStrings.darkAppearance)
                            .tag(TeleprompterAppearance.dark)
                        Text(TeleprompterStrings.lightAppearance)
                            .tag(TeleprompterAppearance.light)
                    }
                    Toggle(
                        TeleprompterStrings.horizontalMirror,
                        isOn: horizontalMirrorBinding
                    )
                    .accessibilityIdentifier(
                        "teleprompter.horizontalMirror"
                    )
                    Toggle(
                        TeleprompterStrings.verticalMirror,
                        isOn: verticalMirrorBinding
                    )
                    .accessibilityIdentifier(
                        "teleprompter.verticalMirror"
                    )
                }
            }
            .navigationTitle(TeleprompterStrings.settings)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(TeleprompterStrings.closeSettings) {
                        isSettingsPresented = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func preferenceSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        valueDescription: @escaping (Double) -> String,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                Spacer()
                Text(valueDescription(value.wrappedValue))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
                .accessibilityLabel(title)
                .accessibilityValue(valueDescription(value.wrappedValue))
                .accessibilityIdentifier(identifier)
        }
    }

    private func toggleControls() {
        if reduceMotion {
            viewModel.areControlsVisible.toggle()
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                viewModel.areControlsVisible.toggle()
            }
        }
    }

    private var needsClockUpdates: Bool {
        switch viewModel.state {
        case .running, .countingDown:
            return true
        default:
            return false
        }
    }

    private var primaryButtonTitle: String {
        switch viewModel.state {
        case .running:
            return TeleprompterStrings.pause
        case .paused:
            return TeleprompterStrings.resume
        case .countingDown:
            return TeleprompterStrings.cancelCountdown
        default:
            return TeleprompterStrings.start
        }
    }

    private var primaryButtonIcon: String {
        switch viewModel.state {
        case .running:
            return "pause.fill"
        case .countingDown:
            return "xmark"
        default:
            return "play.fill"
        }
    }

    private var isPrimaryActionAvailable: Bool {
        switch viewModel.state {
        case .userDragging, .error:
            return false
        default:
            return !viewModel.isEmpty
        }
    }

    private var backgroundColor: Color {
        viewModel.preferences.appearance == .dark ? .black : .white
    }

    private var foregroundColor: Color {
        viewModel.preferences.appearance == .dark ? .white : .black
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

    private var fontSizeBinding: Binding<Double> {
        preferenceBinding(\.fontSize)
    }

    private var lineSpacingBinding: Binding<Double> {
        preferenceBinding(\.lineSpacing)
    }

    private var speedBinding: Binding<Double> {
        preferenceBinding(\.scrollSpeedPointsPerSecond)
    }

    private var marginBinding: Binding<Double> {
        preferenceBinding(\.horizontalMargin)
    }

    private var widthBinding: Binding<Double> {
        preferenceBinding(\.textAreaWidthFraction)
    }

    private var verticalPositionBinding: Binding<Double> {
        preferenceBinding(\.verticalPosition)
    }

    private var countdownBinding: Binding<Int> {
        preferenceBinding(\.countdownSeconds)
    }

    private var appearanceBinding: Binding<TeleprompterAppearance> {
        preferenceBinding(\.appearance)
    }

    private var horizontalMirrorBinding: Binding<Bool> {
        preferenceBinding(\.isHorizontallyMirrored)
    }

    private var verticalMirrorBinding: Binding<Bool> {
        preferenceBinding(\.isVerticallyMirrored)
    }

    private func preferenceBinding<Value>(
        _ keyPath: WritableKeyPath<TeleprompterPreferences, Value>
    ) -> Binding<Value> {
        Binding(
            get: { viewModel.preferences[keyPath: keyPath] },
            set: { value in
                viewModel.updatePreferences {
                    $0[keyPath: keyPath] = value
                }
            }
        )
    }
}
