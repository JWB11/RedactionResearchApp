# RedactionResearchApp

Starter macOS SwiftUI app for researching & comparing redacted files.

## What’s included
- SwiftUI NavigationSplitView shell (sidebar + documents)
- Progress bar + scratchpad panel (ready for live pipeline updates)
- SwiftData models (CaseModel, DocumentModel)
- File import / indexing / AI service stubs
- Helpers: PDFKit text extraction + thumbnail generation

## Requirements
- Xcode 16+
- macOS 14+

## Bundle Identifier
- com.jacksonwells.RedactionResearchApp

## Next steps
1. Implement NSOpenPanel + drag/drop import, copy items into case folder
2. Wire IndexingService progress stream into UI
3. Add OCR (Vision) and richer extraction (Office, XML)
4. Implement similarity (SHA-256 + perceptual hashes + clustering)
5. Integrate Foundation Models (on-device) + optional cloud provider behind a user toggle
