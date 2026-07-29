import SwiftUI

struct HomeView: View {
    let service: any TakeFlowServicing
    let cameraRecordingDependencies: CameraRecordingDependencies

    var body: some View {
        ScriptLibraryView(
            service: service,
            cameraRecordingDependencies:
                cameraRecordingDependencies
        )
    }
}
