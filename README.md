<div align="center">
  <img src="My%20Prompt%20Gallery/Assets.xcassets/AppIcon.appiconset/Icon-ios-1024.png" width="160" height="160" alt="My Prompt Gallery app icon">
  <h1>My Prompt Gallery</h1>
  <p><strong>A personal gallery for organizing, finding, and reusing image generation prompts.</strong></p>
</div>

My Prompt Gallery is an iOS app built for people who work with AI-generated images and want to keep their best prompts close at hand. Save prompts with reference images, organize your visual library, quickly find ideas, and keep a practical history of what worked.

## Features

- Save prompts with text and an attached image.
- Browse the library in list or grid view.
- Search by prompt text and generated metadata.
- Use Apple Intelligence to summarize, classify, and extract keywords from prompts.
- Filter the gallery by recurring keywords.
- Quickly copy prompts to reuse them in other tools.
- Validate media, identify duplicate prompts, and export data as CSV.
- Sync the library with iCloud through SwiftData and CloudKit.

## Technology

- SwiftUI
- SwiftData
- CloudKit
- PhotosUI
- Apple Intelligence with Foundation Models, when available

## Requirements

- Xcode 16 or later
- iOS 17.0 or later
- iCloud account configured for CloudKit synchronization
- Apple Intelligence-compatible device for automatic metadata generation

## How to Run

This repository includes the app source files, but it does not include the local Xcode project file.

1. Create a new iOS app project in Xcode.
2. Add the files from the `My Prompt Gallery` folder to the app target.
3. Configure the bundle identifier, entitlements, iCloud, CloudKit, and Photos permissions for your Apple Developer account.
4. Select an iOS simulator or device.
5. Run the app with `Cmd + R`.

## Privacy

The app stores the user's library on the device and uses the private iCloud container for synchronization. The privacy policy is available at:

https://pedromopi.github.io/apps/my-prompt-gallery/privacy.html
