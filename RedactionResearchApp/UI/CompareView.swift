import SwiftUI

struct CompareView: View {
    var body: some View {
        VStack {
            ContentUnavailableView("Compare view (placeholder)",
                                   systemImage: "square.split.2x1",
                                   description: Text("This will become the side-by-side / overlay diff viewer."))
        }
        .padding()
    }
}
