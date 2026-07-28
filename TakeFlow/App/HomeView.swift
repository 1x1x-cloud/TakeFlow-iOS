import SwiftUI

struct HomeView: View {
    let service: any ScriptLibraryServicing

    var body: some View {
        ScriptLibraryView(service: service)
    }
}
