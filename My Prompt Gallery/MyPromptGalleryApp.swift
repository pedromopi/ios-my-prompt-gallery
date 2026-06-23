import SwiftData
import SwiftUI

@main
struct MyPromptGalleryApp: App {
    private let modelContainer: ModelContainer = {
        let schema = Schema([PromptEntry.self, PromptMedia.self])
        let configuration = ModelConfiguration(
            schema: schema,
            cloudKitDatabase: .private("iCloud.com.pedromopi.promptgallery")
        )

        do {
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            fatalError("Failed to create SwiftData container: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(modelContainer)
    }
}
