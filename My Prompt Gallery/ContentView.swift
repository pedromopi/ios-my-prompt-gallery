import CloudKit
import Foundation
import PhotosUI
import SwiftData
import SwiftUI
import UIKit

private let promptGalleryCloudKitContainerIdentifier = "iCloud.com.pedromopi.promptgallery"
private let promptGalleryPrivacyPolicyURL = URL(string: "https://pedromopi.github.io/apps/my-prompt-gallery/privacy.html")!

private struct DuplicatePromptGroup: Identifiable {
    let id: String
    let entries: [PromptEntry]

    var displayPrompt: String {
        entries.first?.promptText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

private struct DuplicatePromptValidation {
    let groups: [DuplicatePromptGroup]

    var duplicateGroupCount: Int {
        groups.count
    }
}

private enum CloudKitSyncValidation: Equatable {
    case checking
    case available
    case unavailable(String)

    var title: String {
        switch self {
        case .checking:
            "Checking iCloud account..."
        case .available:
            "CloudKit sync available"
        case .unavailable:
            "CloudKit sync needs attention"
        }
    }

    var detail: String {
        switch self {
        case .checking:
            "The app uses the private iCloud container \(promptGalleryCloudKitContainerIdentifier)."
        case .available:
            "The private iCloud account is available for SwiftData sync."
        case .unavailable(let reason):
            reason
        }
    }

    var systemImage: String {
        switch self {
        case .checking:
            "icloud"
        case .available:
            "checkmark.icloud.fill"
        case .unavailable:
            "exclamationmark.icloud.fill"
        }
    }

    var foregroundColor: Color {
        switch self {
        case .checking:
            .secondary
        case .available:
            .green
        case .unavailable:
            .orange
        }
    }
}

private actor PromptThumbnailLoader {
    static let shared = PromptThumbnailLoader()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlightTasks: [NSString: Task<UIImage?, Never>] = [:]

    func loadImage(for key: NSString, thumbnailData: Data?) async -> UIImage? {
        if let cachedImage = cache.object(forKey: key) {
            return cachedImage
        }

        if let existingTask = inFlightTasks[key] {
            return await existingTask.value
        }

        guard let thumbnailData else { return nil }

        let task = Task<UIImage?, Never>(priority: .utility) {
            UIImage(data: thumbnailData)
        }
        inFlightTasks[key] = task

        let image = await task.value
        inFlightTasks[key] = nil

        if let image {
            cache.setObject(image, forKey: key)
        }

        return image
    }
}

struct ContentView: View {
    private enum LayoutMode: String {
        case list
        case grid
    }

    private struct AddPromptSheetTrigger: Identifiable {
        let id = UUID()
        let initialPromptText: String?
    }

    private struct AppleIntelligenceBackfillResult {
        let generatedCount: Int
        let skippedCount: Int
        let firstErrorMessage: String?
    }

    private enum DeleteConfirmationTarget {
        case single(PersistentIdentifier)
        case multiple(Set<PersistentIdentifier>)

        var title: String {
            switch self {
            case .single:
                return "Delete prompt?"
            case .multiple(let entryIDs):
                return entryIDs.count == 1 ? "Delete prompt?" : "Delete prompts?"
            }
        }

        var message: String {
            switch self {
            case .single:
                return "This action cannot be undone."
            case .multiple(let entryIDs):
                return entryIDs.count == 1 ? "This action cannot be undone." : "The \(entryIDs.count) selected prompts will be deleted. This action cannot be undone."
            }
        }

        var confirmButtonTitle: String {
            switch self {
            case .single:
                return "Delete"
            case .multiple(let entryIDs):
                return entryIDs.count == 1 ? "Delete" : "Delete \(entryIDs.count)"
            }
        }
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query(sort: \PromptEntry.createdAt, order: .reverse) private var entries: [PromptEntry]

    @AppStorage("homeLayoutMode") private var layoutModeRawValue = LayoutMode.list.rawValue
    @State private var addPromptSheetTrigger: AddPromptSheetTrigger?
    @State private var selectedDetailEntry: PromptEntry?
    @State private var selectedEntryIDs = Set<PersistentIdentifier>()
    @State private var deleteConfirmationTarget: DeleteConfirmationTarget?
    @State private var isSelectionMode = false
    @State private var toastMessage: String?
    @AppStorage("blurMedia") private var blurMedia = true
    @State private var searchText = ""
    @State private var selectedKeywordFilters = Set<String>()
    @State private var isShowingValidationSheet = false
    @State private var isGeneratingMissingAppleIntelligenceData = false
    @State private var appleIntelligenceBackfillCompletedCount = 0
    @State private var appleIntelligenceBackfillTotalCount = 0
    @State private var appleIntelligenceBackfillCurrentTitle = ""
    @State private var isValidatingMedia = false
    @State private var cloudKitSyncValidation = CloudKitSyncValidation.checking

    private var layoutMode: LayoutMode {
        get { LayoutMode(rawValue: layoutModeRawValue) ?? .list }
        set { layoutModeRawValue = newValue.rawValue }
    }

    private var gridColumns: [GridItem] {
        let columnCount = horizontalSizeClass == .regular ? 3 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 16), count: columnCount)
    }

    private var availableKeywords: [String] {
        availableKeywordOptions.map(\.keyword)
    }

    private var availableKeywordOptions: [(keyword: String, count: Int)] {
        keywordEntryCounts
            .filter { $0.value >= 2 }
            .map { (keyword: $0.key, count: $0.value) }
            .sorted {
                if $0.count == $1.count {
                    return $0.keyword.localizedCaseInsensitiveCompare($1.keyword) == .orderedAscending
                }
                return $0.count > $1.count
            }
    }

    private var keywordEntryCounts: [String: Int] {
        var counts: [String: Int] = [:]

        for entry in entries {
            let uniqueKeywords = Set(entry.appleIntelligenceKeywords)
            for keyword in uniqueKeywords {
                counts[keyword, default: 0] += 1
            }
        }

        return counts
    }

    private var filteredEntries: [PromptEntry] {
        entries.filter { entry in
            matchesSearch(entry) && matchesKeywordFilters(entry)
        }
    }

    private var entriesMissingAppleIntelligenceData: [PromptEntry] {
        entries.filter(\.isMissingAppleIntelligenceData)
    }

    private var invalidMediaCount: Int {
        entries.reduce(into: 0) { count, entry in
            guard let media = entry.media, !isValidMedia(media) else { return }
            count += 1
        }
    }

    private var duplicatePromptValidation: DuplicatePromptValidation {
        let groups = Dictionary(grouping: entries) { entry in
            normalizedDuplicateKey(for: entry.promptText)
        }
        .compactMap { key, group -> DuplicatePromptGroup? in
            guard group.count > 1 else { return nil }
            guard group.contains(where: { !$0.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }

            return DuplicatePromptGroup(
                id: key,
                entries: group.sorted { $0.createdAt > $1.createdAt }
            )
        }
        .sorted { firstGroup, secondGroup in
            firstGroup.displayPrompt.localizedCaseInsensitiveCompare(secondGroup.displayPrompt) == .orderedAscending
        }

        return DuplicatePromptValidation(groups: groups)
    }

    private var hasActiveFilters: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !selectedKeywordFilters.isEmpty
    }

    private var isShowingDeleteConfirmation: Binding<Bool> {
        Binding(
            get: { deleteConfirmationTarget != nil },
            set: { isPresented in
                if !isPresented {
                    deleteConfirmationTarget = nil
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    emptyState
                } else if filteredEntries.isEmpty {
                    noResultsState
                } else if layoutMode == .list {
                    promptList
                } else {
                    promptGrid
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if isSelectionMode {
                        Button("Cancel") {
                            clearSelectionMode()
                        }
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    if isSelectionMode {
                        Button(role: .destructive) {
                            requestDeleteSelectedEntries()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .disabled(selectedEntryIDs.isEmpty)
                    } else {
                        HStack(spacing: 12) {
                            Button {
                                addPromptSheetTrigger = AddPromptSheetTrigger(initialPromptText: nil)
                            } label: {
                                Label("Add", systemImage: "plus")
                            }

                            Menu {
                                Section("Layout") {
                                    Button {
                                        layoutModeRawValue = LayoutMode.list.rawValue
                                    } label: {
                                        Label("List", systemImage: layoutMode == .list ? "checkmark" : "list.bullet")
                                    }

                                    Button {
                                        layoutModeRawValue = LayoutMode.grid.rawValue
                                    } label: {
                                        Label("Grid", systemImage: layoutMode == .grid ? "checkmark" : "square.grid.2x2")
                                    }
                                }

                                Menu {
                                    if availableKeywords.isEmpty {
                                        Button("No keywords available") {}
                                            .disabled(true)
                                    } else {
                                        ForEach(availableKeywordOptions, id: \.keyword) { option in
                                            Button {
                                                toggleKeywordFilter(option.keyword)
                                            } label: {
                                                let title = "\(option.keyword) (\(option.count))"

                                                if selectedKeywordFilters.contains(option.keyword) {
                                                    Label(title, systemImage: "checkmark")
                                                } else {
                                                    Text(title)
                                                }
                                            }
                                        }
                                    }

                                    if !selectedKeywordFilters.isEmpty {
                                        Divider()

                                        Button("Clear filters") {
                                            selectedKeywordFilters.removeAll()
                                        }
                                    }
                                } label: {
                                    Label("Filter", systemImage: selectedKeywordFilters.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                                }

                                Section {
                                    Button {
                                        isShowingValidationSheet = true
                                    } label: {
                                        Label("Validate", systemImage: "checkmark.shield")
                                    }
                                    .disabled(entries.isEmpty)

                                    ShareLink(item: csvExportURL, preview: SharePreview("My Prompt Gallery.csv")) {
                                        Label("Export CSV", systemImage: "tablecells")
                                    }
                                    .disabled(filteredEntries.isEmpty)

                                    Link(destination: promptGalleryPrivacyPolicyURL) {
                                        Label("Privacy Policy", systemImage: "hand.raised")
                                    }
                                }

                                Button {
                                    toggleMediaProtection()
                                } label: {
                                    Label(blurMedia ? "Show clearly" : "Protect media", systemImage: blurMedia ? "eye.slash" : "eye")
                                }

                                Button {
                                    isSelectionMode = true
                                } label: {
                                    Label("Select", systemImage: "checkmark.circle")
                                }
                                .disabled(entries.isEmpty)
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                        }
                    }
                }

                ToolbarItem(placement: .principal) {
                    if isSelectionMode {
                        Text(selectionTitle)
                            .font(.headline)
                    } else {
                        navigationTitleView
                    }
                }
            }
            .sheet(item: $addPromptSheetTrigger, onDismiss: { addPromptSheetTrigger = nil }) { trigger in
                AddPromptSheet(initialPromptText: trigger.initialPromptText) { message in
                    showToast(message)
                }
            }
            .sheet(item: $selectedDetailEntry) { entry in
                PromptDetailSheet(
                    entry: entry,
                    onDelete: {
                        selectedDetailEntry = nil
                        delete(entry: entry)
                    }
                )
            }
            .sheet(isPresented: $isShowingValidationSheet) {
                ValidationSheet(
                    invalidMediaCount: invalidMediaCount,
                    missingAppleIntelligenceDataCount: entriesMissingAppleIntelligenceData.count,
                    appleIntelligenceUnavailableReason: PromptAppleIntelligenceAnalyzer.unavailableReason(),
                    duplicatePromptValidation: duplicatePromptValidation,
                    cloudKitSyncValidation: cloudKitSyncValidation,
                    isValidatingMedia: isValidatingMedia,
                    isGeneratingAppleIntelligenceData: isGeneratingMissingAppleIntelligenceData,
                    appleIntelligenceGeneratedCount: appleIntelligenceBackfillCompletedCount,
                    appleIntelligenceTotalCount: appleIntelligenceBackfillTotalCount,
                    appleIntelligenceCurrentTitle: appleIntelligenceBackfillCurrentTitle,
                    onValidateMedia: {
                        await validateMedia()
                    },
                    onGenerateAppleIntelligenceData: {
                        await generateMissingAppleIntelligenceData()
                    },
                    onValidateCloudKitSync: {
                        await validateCloudKitSync()
                    },
                    onDeletePrompt: { entry in
                        delete(entry: entry)
                    }
                )
            }
            .alert(deleteConfirmationTarget?.title ?? "Delete prompt?", isPresented: isShowingDeleteConfirmation) {
                Button("Cancel", role: .cancel) {
                    deleteConfirmationTarget = nil
                }
                Button(deleteConfirmationTarget?.confirmButtonTitle ?? "Delete", role: .destructive) {
                    confirmPendingDelete()
                }
            } message: {
                Text(deleteConfirmationTarget?.message ?? "This action cannot be undone.")
            }
            .overlay(alignment: .bottom) {
                if let toastMessage {
                    ToastView(message: toastMessage)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .overlay {
                if isGeneratingMissingAppleIntelligenceData {
                    appleIntelligenceBackfillProgressView
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.22), value: toastMessage)
            .animation(.easeInOut(duration: 0.2), value: isGeneratingMissingAppleIntelligenceData)
            .searchable(text: $searchText, prompt: "Search prompts and generated data")
        }
    }

    private var navigationTitleView: some View {
        VStack(spacing: 2) {
            Text("My Prompt Gallery")
                .font(.headline)
            Text(entries.count == 1 ? "1 prompt" : "\(entries.count) prompts")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No saved prompts", systemImage: "sparkles.rectangle.stack")
        } description: {
            Text("Save prompts with the generated image so you can find everything quickly later.")
        } actions: {
            Button("Add first prompt") {
                addPromptSheetTrigger = AddPromptSheetTrigger(initialPromptText: nil)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var noResultsState: some View {
        ContentUnavailableView {
            Label("No results found", systemImage: "magnifyingglass")
        } description: {
            Text("Try another search term or remove some keyword filters.")
        } actions: {
            if hasActiveFilters {
                Button("Clear search and filters") {
                    searchText = ""
                    selectedKeywordFilters.removeAll()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var appleIntelligenceBackfillProgressView: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Color.accentColor)
                    Text("Generating data")
                        .font(.headline)
                }

                ProgressView(
                    value: Double(appleIntelligenceBackfillCompletedCount),
                    total: Double(max(appleIntelligenceBackfillTotalCount, 1))
                )
                .progressViewStyle(.linear)

                Text("\(appleIntelligenceBackfillCompletedCount) of \(appleIntelligenceBackfillTotalCount) prompts")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if !appleIntelligenceBackfillCurrentTitle.isEmpty {
                    Text(appleIntelligenceBackfillCurrentTitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(20)
            .frame(maxWidth: 340, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(24)
        }
    }

    private var promptList: some View {
        List {
            ForEach(filteredEntries) { entry in
                itemButton(for: entry) {
                    PromptRowView(
                        entry: entry,
                        isSelectionMode: isSelectionMode,
                        isSelected: selectedEntryIDs.contains(entry.persistentModelID),
                        blurMedia: blurMedia
                    )
                }
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var promptGrid: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: 16) {
                ForEach(filteredEntries) { entry in
                    itemButton(for: entry) {
                        PromptCardView(
                            entry: entry,
                            isSelectionMode: isSelectionMode,
                            isSelected: selectedEntryIDs.contains(entry.persistentModelID),
                            blurMedia: blurMedia
                        )
                    }
                }
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var selectionTitle: String {
        selectedEntryIDs.isEmpty ? "Select items" : "\(selectedEntryIDs.count) selected"
    }

    @ViewBuilder
    private func itemButton<Content: View>(for entry: PromptEntry, @ViewBuilder content: () -> Content) -> some View {
        Button {
            handleTap(on: entry)
        } label: {
            content()
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                copyPrompt(entry.promptText)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }

            Button {
                selectedDetailEntry = entry
            } label: {
                Label("Details", systemImage: "info.circle")
            }

            Button {
                Task {
                    await regenerateAppleIntelligenceData(for: entry)
                }
            } label: {
                Label("Regenerate Apple Intelligence Data", systemImage: "sparkles")
            }
            .disabled(isGeneratingMissingAppleIntelligenceData || entry.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button(role: .destructive) {
                requestDelete(entry: entry)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func handleTap(on entry: PromptEntry) {
        if isSelectionMode {
            toggleSelection(for: entry)
        } else {
            selectedDetailEntry = entry
        }
    }

    private func toggleSelection(for entry: PromptEntry) {
        let entryID = entry.persistentModelID
        if selectedEntryIDs.contains(entryID) {
            selectedEntryIDs.remove(entryID)
        } else {
            selectedEntryIDs.insert(entryID)
        }
    }

    private func clearSelectionMode() {
        isSelectionMode = false
        selectedEntryIDs.removeAll()
    }

    private func requestDelete(entry: PromptEntry) {
        deleteConfirmationTarget = .single(entry.persistentModelID)
    }

    private func requestDeleteSelectedEntries() {
        guard !selectedEntryIDs.isEmpty else { return }
        deleteConfirmationTarget = .multiple(selectedEntryIDs)
    }

    private func confirmPendingDelete() {
        guard let deleteConfirmationTarget else { return }
        self.deleteConfirmationTarget = nil

        switch deleteConfirmationTarget {
        case .single(let entryID):
            guard let entry = entries.first(where: { $0.persistentModelID == entryID }) else { return }
            delete(entry: entry)
        case .multiple(let entryIDs):
            deleteSelectedEntries(matching: entryIDs)
        }
    }

    private func deleteSelectedEntries(matching entryIDs: Set<PersistentIdentifier>) {
        let entriesToDelete = entries.filter { entryIDs.contains($0.persistentModelID) }
        let deletedCount = entriesToDelete.count

        Task {
            await deleteEntries(entriesToDelete)

            await MainActor.run {
                clearSelectionMode()

                guard deletedCount > 0 else { return }
                showToast(deletedCount == 1 ? "Prompt deleted" : "\(deletedCount) prompts deleted")
            }
        }
    }

    private func delete(entry: PromptEntry) {
        Task {
            await deleteEntries([entry])

            await MainActor.run {
                selectedEntryIDs.remove(entry.persistentModelID)
                showToast("Prompt deleted")
            }
        }
    }

    private func copyPrompt(_ prompt: String) {
        UIPasteboard.general.string = prompt
        showToast("Prompt copied")
    }

    @MainActor
    private func validateMedia() async {
        guard !isValidatingMedia else { return }
        isValidatingMedia = true
        defer { isValidatingMedia = false }

        let removedMediaCount = removeInvalidMedia()
        guard removedMediaCount > 0 else {
            showToast("No invalid media found")
            return
        }

        do {
            try modelContext.save()
            showToast(removedMediaCount == 1 ? "1 invalid media item removed" : "\(removedMediaCount) invalid media items removed")
        } catch {
            showToast("Could not save validation results")
        }
    }

    private func removeInvalidMedia() -> Int {
        var removedMediaCount = 0

        for entry in entries {
            guard let media = entry.media, !isValidMedia(media) else { continue }
            entry.media = nil
            modelContext.delete(media)
            removedMediaCount += 1
        }

        return removedMediaCount
    }

    private func isValidMedia(_ media: PromptMedia) -> Bool {
        canDecodeImage(from: media.imageData) || canDecodeImage(from: media.thumbnailData)
    }

    private func canDecodeImage(from data: Data?) -> Bool {
        guard let data else { return false }
        return UIImage(data: data) != nil
    }

    private func normalizedDuplicateKey(for promptText: String) -> String {
        promptText
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
    }

    @MainActor
    private func validateCloudKitSync() async {
        cloudKitSyncValidation = .checking

        do {
            let status = try await CKContainer(identifier: promptGalleryCloudKitContainerIdentifier).accountStatus()
            cloudKitSyncValidation = validation(for: status)
        } catch {
            cloudKitSyncValidation = .unavailable("Could not check iCloud status: \(error.localizedDescription)")
        }
    }

    private func validation(for status: CKAccountStatus) -> CloudKitSyncValidation {
        switch status {
        case .available:
            return .available
        case .noAccount:
            return .unavailable("Sign in to iCloud on this device to allow CloudKit backup and sync.")
        case .restricted:
            return .unavailable("This iCloud account is restricted and cannot use CloudKit sync.")
        case .couldNotDetermine:
            return .unavailable("The iCloud account status could not be determined. Try again later.")
        case .temporarilyUnavailable:
            return .unavailable("iCloud is temporarily unavailable. Try again later.")
        @unknown default:
            return .unavailable("CloudKit sync is not available right now.")
        }
    }

    private func showToast(_ message: String) {
        toastMessage = message

        Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard toastMessage == message else { return }
            toastMessage = nil
        }
    }

    private func toggleMediaProtection() {
        blurMedia.toggle()
    }

    private func toggleKeywordFilter(_ keyword: String) {
        if selectedKeywordFilters.contains(keyword) {
            selectedKeywordFilters.remove(keyword)
        } else {
            selectedKeywordFilters.insert(keyword)
        }
    }

    private func matchesSearch(_ entry: PromptEntry) -> Bool {
        let normalizedSearch = normalizedSearchText
        guard !normalizedSearch.isEmpty else { return true }
        return entry.searchableAnalysisText.localizedCaseInsensitiveContains(normalizedSearch)
    }

    private func matchesKeywordFilters(_ entry: PromptEntry) -> Bool {
        guard !selectedKeywordFilters.isEmpty else { return true }
        let entryKeywords = Set(entry.appleIntelligenceKeywords)
        return !entryKeywords.isDisjoint(with: selectedKeywordFilters)
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var csvExportURL: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("My Prompt Gallery.csv")
        try? makeCSV(from: filteredEntries).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static let csvDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private func makeCSV(from entries: [PromptEntry]) -> String {
        let header = [
            "displayTitle",
            "prompt",
            "createdAt",
            "hasImage",
            "appleIntelligenceSummary",
            "appleIntelligenceStyle",
            "appleIntelligenceType",
            "appleIntelligenceKeywords",
            "appleIntelligenceAnalyzedAt"
        ]

        let rows = entries.map { entry in
            csvFields(for: entry)
                .map(csvEscaped)
                .joined(separator: ",")
        }

        return ([header.map(csvEscaped).joined(separator: ",")] + rows).joined(separator: "\n")
    }

    private func csvFields(for entry: PromptEntry) -> [String] {
        [
            entry.displayTitle,
            entry.promptText,
            formattedCSVDate(entry.createdAt),
            hasExportableImage(entry) ? "true" : "false",
            entry.appleIntelligenceSummary ?? "",
            entry.appleIntelligenceStyle ?? "",
            entry.appleIntelligencePromptType ?? "",
            entry.appleIntelligenceKeywords.joined(separator: ", "),
            formattedCSVDate(entry.appleIntelligenceAnalyzedAt)
        ]
    }

    private func hasExportableImage(_ entry: PromptEntry) -> Bool {
        entry.media?.imageData != nil || entry.media?.thumbnailData != nil
    }

    private func formattedCSVDate(_ date: Date?) -> String {
        guard let date else { return "" }
        return Self.csvDateFormatter.string(from: date)
    }

    private func csvEscaped(_ value: String) -> String {
        let normalizedValue = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let escapedValue = normalizedValue.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escapedValue)\""
    }

    @MainActor
    private func regenerateAppleIntelligenceData(for entry: PromptEntry) async {
        guard !isGeneratingMissingAppleIntelligenceData else { return }

        isGeneratingMissingAppleIntelligenceData = true
        appleIntelligenceBackfillCompletedCount = 0
        appleIntelligenceBackfillTotalCount = 1
        appleIntelligenceBackfillCurrentTitle = entry.displayTitle
        defer {
            isGeneratingMissingAppleIntelligenceData = false
            appleIntelligenceBackfillCurrentTitle = ""
        }

        do {
            let payload = try await PromptAppleIntelligenceAnalyzer.generate(for: entry.promptText)
            entry.applyAppleIntelligencePayload(payload)
            try modelContext.save()
            appleIntelligenceBackfillCompletedCount = 1
            showToast("Apple Intelligence data regenerated")
        } catch {
            showToast(friendlyAppleIntelligenceBackfillMessage(for: error))
        }
    }

    @MainActor
    @discardableResult
    private func generateMissingAppleIntelligenceData(showCompletionToast: Bool = true) async -> AppleIntelligenceBackfillResult {
        guard !isGeneratingMissingAppleIntelligenceData else {
            return AppleIntelligenceBackfillResult(generatedCount: 0, skippedCount: 0, firstErrorMessage: nil)
        }

        let missingEntries = entriesMissingAppleIntelligenceData
        guard !missingEntries.isEmpty else {
            return AppleIntelligenceBackfillResult(generatedCount: 0, skippedCount: 0, firstErrorMessage: nil)
        }

        isGeneratingMissingAppleIntelligenceData = true
        appleIntelligenceBackfillCompletedCount = 0
        appleIntelligenceBackfillTotalCount = missingEntries.count
        appleIntelligenceBackfillCurrentTitle = "Preparing..."
        defer {
            isGeneratingMissingAppleIntelligenceData = false
            appleIntelligenceBackfillCurrentTitle = ""
        }

        var generatedCount = 0
        var skippedCount = 0
        var firstErrorMessage: String?

        for entry in missingEntries {
            appleIntelligenceBackfillCurrentTitle = entry.displayTitle

            do {
                let payload = try await PromptAppleIntelligenceAnalyzer.generate(for: entry.promptText)
                entry.applyAppleIntelligencePayload(payload)
                try modelContext.save()
                generatedCount += 1
            } catch {
                skippedCount += 1
                if firstErrorMessage == nil {
                    firstErrorMessage = friendlyAppleIntelligenceBackfillMessage(for: error)
                }
            }

            appleIntelligenceBackfillCompletedCount = generatedCount + skippedCount
        }

        if showCompletionToast {
            showAppleIntelligenceBackfillSummary(generatedCount: generatedCount, skippedCount: skippedCount, detail: firstErrorMessage)
        }

        return AppleIntelligenceBackfillResult(generatedCount: generatedCount, skippedCount: skippedCount, firstErrorMessage: firstErrorMessage)
    }

    private func showAppleIntelligenceBackfillSummary(generatedCount: Int, skippedCount: Int, detail: String?) {
        if generatedCount == 0, skippedCount == 0 {
            showToast("No missing data found")
        } else if skippedCount == 0 {
            showToast(generatedCount == 1 ? "Data generated for 1 prompt" : "Data generated for \(generatedCount) prompts")
        } else if let detail, !detail.isEmpty {
            showToast("\(generatedCount) generated, \(skippedCount) skipped. \(detail)")
        } else {
            showToast("\(generatedCount) generated, \(skippedCount) skipped")
        }
    }

    private func friendlyAppleIntelligenceBackfillMessage(for error: Error) -> String {
        let message = error.localizedDescription
        if message.localizedCaseInsensitiveContains("guardrail") || message.localizedCaseInsensitiveContains("safety") {
            return "Some prompts were blocked by Apple Intelligence safety criteria."
        }
        return message
    }

    @MainActor
    private func deleteEntries(_ entriesToDelete: [PromptEntry]) async {
        for entry in entriesToDelete {
            if let media = entry.media {
                modelContext.delete(media)
            }
            modelContext.delete(entry)
        }

        try? modelContext.save()
    }
}

private struct ValidationSheet: View {
    @Environment(\.dismiss) private var dismiss

    let invalidMediaCount: Int
    let missingAppleIntelligenceDataCount: Int
    let appleIntelligenceUnavailableReason: String?
    let duplicatePromptValidation: DuplicatePromptValidation
    let cloudKitSyncValidation: CloudKitSyncValidation
    let isValidatingMedia: Bool
    let isGeneratingAppleIntelligenceData: Bool
    let appleIntelligenceGeneratedCount: Int
    let appleIntelligenceTotalCount: Int
    let appleIntelligenceCurrentTitle: String
    let onValidateMedia: () async -> Void
    let onGenerateAppleIntelligenceData: () async -> Void
    let onValidateCloudKitSync: () async -> Void
    let onDeletePrompt: (PromptEntry) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Media") {
                    if invalidMediaCount == 0 {
                        Label("Media validated", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        LabeledContent("Invalid media", value: "\(invalidMediaCount)")

                        Button {
                            Task {
                                await onValidateMedia()
                            }
                        } label: {
                            Label(isValidatingMedia ? "Validating..." : "Validate media", systemImage: "photo.badge.checkmark")
                        }
                        .disabled(isValidatingMedia || isGeneratingAppleIntelligenceData)
                    }
                }

                Section {
                    LabeledContent("Missing data", value: "\(missingAppleIntelligenceDataCount)")

                    if isGeneratingAppleIntelligenceData {
                        VStack(alignment: .leading, spacing: 10) {
                            ProgressView(
                                value: Double(appleIntelligenceGeneratedCount),
                                total: Double(max(appleIntelligenceTotalCount, 1))
                            )
                            .progressViewStyle(.linear)

                            Text("\(appleIntelligenceGeneratedCount) of \(appleIntelligenceTotalCount) prompts")
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            if !appleIntelligenceCurrentTitle.isEmpty {
                                Text(appleIntelligenceCurrentTitle)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    } else if missingAppleIntelligenceDataCount == 0 {
                        Label("Up to date", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    } else if let appleIntelligenceUnavailableReason {
                        Text(appleIntelligenceUnavailableReason)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        Task {
                            await onGenerateAppleIntelligenceData()
                        }
                    } label: {
                        Label(isGeneratingAppleIntelligenceData ? "Generating..." : "Generate missing data", systemImage: "sparkles")
                    }
                    .disabled(
                        missingAppleIntelligenceDataCount == 0 ||
                        appleIntelligenceUnavailableReason != nil ||
                        isValidatingMedia ||
                        isGeneratingAppleIntelligenceData
                    )
                } header: {
                    Text("Apple Intelligence")
                } footer: {
                    Text("Some prompts may not be processed by Apple Intelligence depending on sensitive content in the prompt.")
                }

                Section {
                    if duplicatePromptValidation.duplicateGroupCount == 0 {
                        Label("No duplicate prompts found", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        NavigationLink {
                            DuplicatePromptGroupsView(
                                groups: duplicatePromptValidation.groups,
                                onDeletePrompt: onDeletePrompt
                            )
                        } label: {
                            LabeledContent("Duplicate groups", value: "\(duplicatePromptValidation.duplicateGroupCount)")
                        }
                    }
                } header: {
                    Text("Organization")
                } footer: {
                    Text("Duplicate checks ignore capitalization, accents, spaces, and line breaks.")
                }

                Section("Backup") {
                    Label(cloudKitSyncValidation.title, systemImage: cloudKitSyncValidation.systemImage)
                        .foregroundStyle(cloudKitSyncValidation.foregroundColor)

                }

                Section {
                    Button("Close") {
                        dismiss()
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .navigationTitle("Validations")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await onValidateCloudKitSync()
            }
        }
    }
}

private struct DuplicatePromptGroupsView: View {
    let groups: [DuplicatePromptGroup]
    let onDeletePrompt: (PromptEntry) -> Void

    var body: some View {
        List {
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                Section {
                    ForEach(group.entries) { entry in
                        DuplicatePromptRow(entry: entry)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    onDeletePrompt(entry)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    Text("Group \(index + 1)")
                } footer: {
                    Text("\(group.entries.count) prompts")
                }
            }
        }
        .navigationTitle("Duplicate Prompts")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DuplicatePromptRow: View {
    let entry: PromptEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.displayTitle)
                .font(.headline)
                .lineLimit(2)

            if entry.displayTitle != entry.promptText {
                Text(entry.promptText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct PromptRowView: View {
    @Environment(\.colorScheme) private var colorScheme

    let entry: PromptEntry
    let isSelectionMode: Bool
    let isSelected: Bool
    let blurMedia: Bool

    var body: some View {
        HStack(spacing: 14) {
            if !blurMedia {
                PromptThumbnailView(
                    cacheKey: NSString(string: String(describing: entry.persistentModelID)),
                    thumbnailData: entry.media?.thumbnailData,
                    height: 88
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(entry.displayTitle)
                    .font(.headline)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)

            }

            Spacer(minLength: 0)

            if isSelectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            }
        }
        .padding(12)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var cardBackground: some ShapeStyle {
        if isSelected {
            return AnyShapeStyle(Color.accentColor.opacity(0.18))
        }
        if colorScheme == .light {
            return AnyShapeStyle(Color(uiColor: .systemGray5))
        }
        return AnyShapeStyle(.thinMaterial)
    }
}

private struct PromptCardView: View {
    @Environment(\.colorScheme) private var colorScheme

    let entry: PromptEntry
    let isSelectionMode: Bool
    let isSelected: Bool
    let blurMedia: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !blurMedia {
                PromptThumbnailView(
                    cacheKey: NSString(string: String(describing: entry.persistentModelID)),
                    thumbnailData: entry.media?.thumbnailData,
                    height: 150
                )
            }

            Text(entry.displayTitle)
                .font(.headline)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)

            HStack {
                Spacer()
                if isSelectionMode {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var cardBackground: some ShapeStyle {
        if isSelected {
            return AnyShapeStyle(Color.accentColor.opacity(0.18))
        }
        if colorScheme == .light {
            return AnyShapeStyle(Color(uiColor: .systemGray5))
        }
        return AnyShapeStyle(.thinMaterial)
    }
}

private struct PromptThumbnailView: View {
    let cacheKey: NSString
    let thumbnailData: Data?
    let height: CGFloat

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: height, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .task(id: cacheKey.description) {
            await loadImageIfNeeded()
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.99, green: 0.71, blue: 0.47),
                    Color(red: 0.96, green: 0.46, blue: 0.43)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Image(systemName: "photo")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    private func loadImageIfNeeded() async {
        guard image == nil else { return }
        image = await PromptThumbnailLoader.shared.loadImage(
            for: cacheKey,
            thumbnailData: thumbnailData
        )
    }
}

private struct PromptDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let entry: PromptEntry
    let onDelete: () -> Void

    @State private var selectedItem: PhotosPickerItem?
    @State private var showPicker = false
    @State private var showImageOptions = false
    @State private var isLoadingImage = false
    @State private var hasCopiedPrompt = false
    @State private var isShowingDeleteConfirmation = false
    @State private var isEditingPrompt = false
    @State private var editedPromptText = ""

    private func removeImage() {
        if let media = entry.media {
            entry.media = nil
            modelContext.delete(media)
            try? modelContext.save()
        }
    }

    private func loadSelectedImage() async {
        guard let selectedItem else { return }
        isLoadingImage = true
        defer {
            isLoadingImage = false
            self.selectedItem = nil
        }

        do {
            if let data = try await selectedItem.loadTransferable(type: Data.self) {
                let thumbnailData = makeThumbnail(from: data)
                
                if let oldMedia = entry.media {
                    entry.media = nil
                    modelContext.delete(oldMedia)
                }
                
                let media = PromptMedia(imageData: data, thumbnailData: thumbnailData)
                modelContext.insert(media)
                entry.media = media
                
                try? modelContext.save()
            }
        } catch {
            print("Error loading image: \(error)")
        }
    }

    private func makeThumbnail(from imageData: Data?) -> Data? {
        guard let imageData, let image = UIImage(data: imageData) else { return nil }

        let maxDimension: CGFloat = 300
        let size = image.size
        let aspectRatio = size.width / size.height
        let targetSize: CGSize

        if aspectRatio > 1 {
            targetSize = CGSize(width: maxDimension, height: maxDimension / aspectRatio)
        } else {
            targetSize = CGSize(width: maxDimension * aspectRatio, height: maxDimension)
        }

        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let thumb = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return thumb.jpegData(compressionQuality: 0.6)
    }

    private func saveEditedPrompt() {
        let trimmed = editedPromptText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            entry.promptText = trimmed
            try? modelContext.save()
        }
        isEditingPrompt = false
    }

    private func copyPromptText() {
        UIPasteboard.general.string = entry.promptText
        hasCopiedPrompt = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            hasCopiedPrompt = false
        }
    }

    @ViewBuilder
    private var imageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Image")
                .font(.headline)
                .foregroundStyle(.secondary)
            
            ZStack {
                Button {
                    if entry.media?.imageData != nil {
                        showImageOptions = true
                    } else {
                        showPicker = true
                    }
                } label: {
                    PromptDetailImageView(
                        imageData: entry.media?.imageData
                    )
                }
                .buttonStyle(.plain)
                .disabled(isLoadingImage)
                .overlay {
                    if isLoadingImage {
                        ZStack {
                            Color.black.opacity(0.3)
                            ProgressView("Loading image...")
                                .tint(.white)
                                .foregroundStyle(.white)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Prompt")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                if isEditingPrompt {
                    Button {
                        isEditingPrompt = false
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.red)
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .padding(.trailing, 8)
                    
                    Button {
                        saveEditedPrompt()
                    } label: {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.green)
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                } else {
                    Button {
                        copyPromptText()
                    } label: {
                        Image(systemName: hasCopiedPrompt ? "checkmark.circle.fill" : "doc.on.clipboard")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(hasCopiedPrompt ? Color.green : .secondary)
                    .padding(.trailing, 8)
                    
                    Button {
                        editedPromptText = entry.promptText
                        isEditingPrompt = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }

            if isEditingPrompt {
                TextField(
                    "Describe the prompt",
                    text: $editedPromptText,
                    axis: .vertical
                )
                .font(.title3)
                .textFieldStyle(.roundedBorder)
                .padding(.vertical, 4)
            } else {
                Text(entry.promptText)
                    .font(.title3)
            }
        }
    }

    @ViewBuilder
    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Summary")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Image(systemName: "sparkles")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 14, weight: .semibold))
            }

            if let summary = entry.appleIntelligenceSummary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(summary)
                    .font(.title3)
            } else {
                Text("No generated data")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .italic()
            }
        }
    }

    @ViewBuilder
    private var metadataSections: some View {
        Group {

            // Section: Style
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Style")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    
                    Spacer()
                    
                    Image(systemName: "sparkles")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 14, weight: .semibold))
                }

                if let style = entry.appleIntelligenceStyle, !style.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(style)
                        .font(.title3)
                } else {
                    Text("No generated data")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .italic()
                }
            }

            // Section: Type
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Type")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    
                    Spacer()
                    
                    Image(systemName: "sparkles")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 14, weight: .semibold))
                }

                if let promptType = entry.appleIntelligencePromptType, !promptType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(promptType)
                        .font(.title3)
                } else {
                    Text("No generated data")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .italic()
                }
            }

            // Section: Keywords
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Keywords")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    
                    Spacer()
                    
                    Image(systemName: "sparkles")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 14, weight: .semibold))
                }

                if !entry.appleIntelligenceKeywords.isEmpty {
                    Text(entry.appleIntelligenceKeywords.joined(separator: ", "))
                        .font(.title3)
                } else {
                    Text("No generated data")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .italic()
                }
            }
        }
    }

    @ViewBuilder
    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Created on")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Text(entry.createdAt.formatted(date: .complete, time: .shortened))
                    .font(.title3)
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    summarySection
                    imageSection
                    promptSection
                    metadataSections
                    footerSection
                }
                .padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Saved Prompt")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: selectedItem) {
                await loadSelectedImage()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        isShowingDeleteConfirmation = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .alert("Delete prompt?", isPresented: $isShowingDeleteConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    onDelete()
                }
            } message: {
                Text("This action cannot be undone.")
            }
            .confirmationDialog("Image", isPresented: $showImageOptions, titleVisibility: .hidden) {
                Button("Change image") {
                    showPicker = true
                }
                Button("Remove image", role: .destructive) {
                    removeImage()
                }
                Button("Cancel", role: .cancel) {}
            }
            .photosPicker(
                isPresented: $showPicker,
                selection: $selectedItem,
                matching: .images,
                photoLibrary: .shared()
            )
        }
    }
}



private struct PromptDetailImageView: View {
    let imageData: Data?

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 220)
                    .background(Color.black.opacity(0.04))
            } else {
                ZStack {
                    LinearGradient(
                        colors: [
                            Color(red: 0.99, green: 0.71, blue: 0.47),
                            Color(red: 0.96, green: 0.46, blue: 0.43)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    VStack(spacing: 12) {
                        Image(systemName: "photo")
                            .font(.system(size: 40, weight: .medium))
                            .foregroundStyle(.white.opacity(0.92))

                        Text("No image attached")
                            .font(.headline)
                            .foregroundStyle(.white.opacity(0.92))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 260)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .task(id: imageData) {
            await loadImageIfNeeded()
        }
    }

    private func loadImageIfNeeded() async {
        if let imageData {
            self.image = UIImage(data: imageData)
        } else {
            self.image = nil
        }
    }
}

private struct ToastView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.82))
            )
            .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
    }
}
