import PhotosUI
import SwiftData
import SwiftUI
import UIKit

struct AddPromptSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    private let entry: PromptEntry?
    private let initialPromptText: String?
    private let onSaved: ((String) -> Void)?

    @State private var promptText: String
    @State private var selectedItem: PhotosPickerItem?
    @State private var selectedImageData: Data?
    @State private var isLoadingImage = false
    @State private var didLoadExistingImage = false
    @State private var isSaving = false
    @FocusState private var isPromptFocused: Bool

    init(entry: PromptEntry? = nil, initialPromptText: String? = nil, onSaved: ((String) -> Void)? = nil) {
        self.entry = entry
        self.initialPromptText = initialPromptText
        self.onSaved = onSaved
        _promptText = State(initialValue: entry?.promptText ?? initialPromptText ?? "")
        _selectedImageData = State(initialValue: nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Image") {
                    if let data = selectedImageData, let image = UIImage(data: data) {
                        Menu {
                            PhotosPicker(
                                selection: $selectedItem,
                                matching: .images,
                                photoLibrary: .shared()
                            ) {
                                Label("Change image", systemImage: "photo.on.rectangle")
                            }

                            Button(role: .destructive) {
                                selectedItem = nil
                                selectedImageData = nil
                            } label: {
                                Label("Remove image", systemImage: "trash")
                            }
                        } label: {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity)
                                .frame(maxHeight: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    } else if isLoadingImage {
                        ProgressView("Loading image...")
                            .frame(maxWidth: .infinity)
                            .frame(height: 220)
                    } else {
                        PhotosPicker(
                            selection: $selectedItem,
                            matching: .images,
                            photoLibrary: .shared()
                        ) {
                            ContentUnavailableView("No Image", systemImage: "photo.badge.plus", description: Text("Tap to attach an image"))
                                .frame(height: 220)
                        }
                    }
                }

                Section("Prompt") {
                    TextField(
                        "Describe the prompt that generated the image",
                        text: $promptText,
                        axis: .vertical
                    )
                    .lineLimit(1...15)
                    .focused($isPromptFocused)

                    HStack {
                        Spacer()
                        Button {
                            pastePromptText()
                        } label: {
                            Label("Paste", systemImage: "plus.square.on.square")
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                    }
                }

                Section {
                    if let entry {
                        Text("Created on \(entry.createdAt.formatted(date: .abbreviated, time: .shortened)).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(entry == nil ? "New Prompt" : "Edit Prompt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        Task {
                            await savePrompt()
                        }
                    }
                    .disabled(isSaving || promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .task(id: selectedItem) {
                await loadSelectedImage()
            }
            .task {
                await loadExistingImageIfNeeded()
            }
        }
    }

    private func loadSelectedImage() async {
        guard let selectedItem else { return }
        isLoadingImage = true
        defer { isLoadingImage = false }

        do {
            selectedImageData = try await selectedItem.loadTransferable(type: Data.self)
        } catch {
            selectedImageData = nil
        }
    }

    private func pastePromptText() {
        guard let pastedText = UIPasteboard.general.string else { return }
        promptText = pastedText
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

    private func loadExistingImageIfNeeded() async {
        guard !didLoadExistingImage else { return }
        didLoadExistingImage = true
        guard let entry else { return }

        if let media = entry.media {
            selectedImageData = media.imageData
        } else {
            selectedImageData = nil
        }
    }


    private func savePrompt() async {
        let trimmedPrompt = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if entry == nil && trimmedPrompt.isEmpty {
            dismiss()
            return
        }
        
        if trimmedPrompt.isEmpty {
            dismiss()
            return
        }

        isSaving = true
        defer { isSaving = false }

        let thumbnailData = makeThumbnail(from: selectedImageData)

        if let entry {
            entry.promptText = trimmedPrompt
            if let payload = try? await PromptAppleIntelligenceAnalyzer.generate(for: trimmedPrompt) {
                entry.applyAppleIntelligencePayload(payload)
            }

            if let existingMedia = entry.media {
                if selectedImageData != nil || thumbnailData != nil {
                    existingMedia.imageData = selectedImageData
                    existingMedia.thumbnailData = thumbnailData
                } else {
                    entry.media = nil
                    modelContext.delete(existingMedia)
                }
            } else if selectedImageData != nil || thumbnailData != nil {
                let media = PromptMedia(imageData: selectedImageData, thumbnailData: thumbnailData)
                modelContext.insert(media)
                entry.media = media
            }

            onSaved?("Prompt updated")
        } else {
            let media: PromptMedia?
            if selectedImageData != nil || thumbnailData != nil {
                let newMedia = PromptMedia(imageData: selectedImageData, thumbnailData: thumbnailData)
                modelContext.insert(newMedia)
                media = newMedia
            } else {
                media = nil
            }

            let newEntry = PromptEntry(promptText: trimmedPrompt, media: media)
            if let payload = try? await PromptAppleIntelligenceAnalyzer.generate(for: trimmedPrompt) {
                newEntry.applyAppleIntelligencePayload(payload)
            }

            modelContext.insert(newEntry)
            onSaved?("Prompt saved")
        }

        do {
            try modelContext.save()
            dismiss()
        } catch {
            return
        }
    }
}
