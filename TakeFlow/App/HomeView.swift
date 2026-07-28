import SwiftUI

struct HomeView: View {
    let service: any TakeFlowServicing

    var body: some View {
        ScriptLibraryView(service: service)
    }
}
