import SwiftData
import SwiftUI

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        DashboardContent(modelContext: modelContext)
    }
}
