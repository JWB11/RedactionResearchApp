import SwiftUI

struct DashboardView: View {
    var body: some View {
        GroupBox("Dashboard") {
            HStack {
                VStack(alignment: .leading) {
                    Text("Files: 0").font(.headline)
                    Text("Exact dupes: 0").foregroundStyle(.secondary)
                    Text("Near dupes: 0").foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .leading) {
                    Text("Redaction variants: 0").font(.headline)
                    Text("OCR pending: 0").foregroundStyle(.secondary)
                    Text("AI insights: 0").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }
}
