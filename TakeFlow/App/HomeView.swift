import SwiftUI

struct HomeView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                Text("一遍成")
                    .font(.largeTitle.bold())
                    .accessibilityIdentifier("home.title")

                Text("工程基础已就绪")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("home.status")
            }
            .multilineTextAlignment(.center)
            .padding()
            .navigationTitle("首页")
        }
    }
}

#Preview {
    HomeView()
}
