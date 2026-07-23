//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum PhotoLibraryPickerAction {
    case selectedMediaAtURLs([URL])
    case cancel
    case error(PhotoLibraryPickerError)
}

enum PhotoLibraryPickerError: Error {
    case failedLoadingFileRepresentation(Error?)
    case failedLoadingOriginalAsset(Error?)
    case failedCopyingFile
}

struct PhotoLibraryPicker: UIViewControllerRepresentable {
    private let selectionType: MediaPickerScreenSelectionType
    private let userIndicatorController: UserIndicatorControllerProtocol
    private let callback: (PhotoLibraryPickerAction) -> Void
    
    init(selectionType: MediaPickerScreenSelectionType,
         userIndicatorController: UserIndicatorControllerProtocol,
         callback: @escaping (PhotoLibraryPickerAction) -> Void) {
        self.selectionType = selectionType
        self.userIndicatorController = userIndicatorController
        self.callback = callback
    }
    
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.preferredAssetRepresentationMode = .current
        configuration.selection = .ordered
        configuration.selectionLimit = switch selectionType {
        case .single:
            1
        case .multiple:
            10
        }
        
        let pickerViewController = PHPickerViewController(configuration: configuration)
        pickerViewController.delegate = context.coordinator
        
        return pickerViewController
    }
    
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {
        // Override the app wide tint color (currently set to `.compound.texActionPrimary
        // as it's not legible enough in dark mode
        uiViewController.view.tintColor = .compound.textActionAccent
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private var photoLibraryPicker: PhotoLibraryPicker
        
        init(_ photoLibraryPicker: PhotoLibraryPicker) {
            self.photoLibraryPicker = photoLibraryPicker
        }
        
        // MARK: PHPickerViewControllerDelegate
        
        private static let loadingIndicatorIdentifier = "\(PhotoLibraryPicker.self)-Loading"
        
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !results.isEmpty else {
                photoLibraryPicker.callback(.cancel)
                return
            }
            
            picker.delegate = nil
            
            photoLibraryPicker.userIndicatorController.submitIndicator(UserIndicator(id: Self.loadingIndicatorIdentifier,
                                                                                     type: .modal,
                                                                                     title: L10n.commonLoading))
            defer {
                photoLibraryPicker.userIndicatorController.retractIndicatorWithId(Self.loadingIndicatorIdentifier)
            }
            
            Task {
                let selectedURLs = await withTaskGroup { taskGroup in
                    for (index, result) in results.enumerated() {
                        taskGroup.addTask {
                            let url = await self.processResult(result)
                            return (index, url)
                        }
                    }
                    
                    var selectedURLs = [URL?](repeating: nil, count: results.count)
                    for await (index, url) in taskGroup {
                        if let url {
                            selectedURLs[index] = url
                        }
                    }
                    
                    return selectedURLs.compactMap { $0 }
                }
                
                guard !selectedURLs.isEmpty else {
                    // Every selected item failed to load; each failure was already surfaced via .error.
                    return
                }
                
                photoLibraryPicker.callback(.selectedMediaAtURLs(selectedURLs))
            }
        }
        
        // MARK: - Private
        
        func processResult(_ result: PHPickerResult) async -> URL? {
            let provider = result.itemProvider
            
            guard let contentType = provider.preferredContentType else {
                Task { @MainActor in
                    photoLibraryPicker.callback(.error(.failedLoadingFileRepresentation(nil)))
                }
                return nil
            }
            
            // PHPicker's `loadFileRepresentation` is allowed to return a rendered
            // representation. For an image that came from Apple Photos this can
            // flatten an ISO/Apple gain map and rewrite GPS/ICC metadata, even when
            // the asset itself still contains the original resource. Always read
            // the original PHAsset resource when an asset identifier is available.
            // This is important for both HEIC and JPEG/R (including Android Ultra
            // HDR JPEGs saved in Apple Photos).
            if contentType.type.conforms(to: .image), result.assetIdentifier != nil {
                guard let url = await loadOriginalPhotoResource(for: result) else {
                    Task { @MainActor in
                        photoLibraryPicker.callback(.error(.failedLoadingOriginalAsset(nil)))
                    }
                    return nil
                }
                return url
            }

            let typeIdentifier = contentType.type.conforms(to: .image) ? UTType.image.identifier : contentType.type.identifier

            return await withCheckedContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] url, error in
                    guard let url else {
                        Task { @MainActor in
                            self?.photoLibraryPicker.callback(.error(.failedLoadingFileRepresentation(error)))
                        }
                        
                        continuation.resume(returning: nil)
                        return
                    }
                    
                    do {
                        _ = url.startAccessingSecurityScopedResource()
                        let newURL = try FileManager.default.copyFileToTemporaryDirectory(file: url)
                        url.stopAccessingSecurityScopedResource()
                        
                        Task { @MainActor in
                            continuation.resume(returning: newURL)
                        }
                    } catch {
                        Task { @MainActor in
                            self?.photoLibraryPicker.callback(.error(.failedCopyingFile))
                            continuation.resume(returning: nil)
                        }
                    }
                }
            }
        }

        private func loadOriginalPhotoResource(for result: PHPickerResult) async -> URL? {
            guard let assetIdentifier = result.assetIdentifier,
                  await requestPhotoLibraryAccessIfNeeded() else {
                return nil
            }

            let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil)
            guard let asset = fetchResult.firstObject,
                  let resource = PHAssetResource.assetResources(for: asset).first(where: { resource in
                      resource.type == .photo &&
                          UTType(resource.uniformTypeIdentifier)?.conforms(to: .image) == true
                  }) else {
                return nil
            }

            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                return nil
            }
            let filename = (resource.originalFilename as NSString).lastPathComponent
            guard !filename.isEmpty else {
                try? FileManager.default.removeItem(at: directory)
                return nil
            }
            let destination = directory.appendingPathComponent(filename)
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true

            return await withCheckedContinuation { continuation in
                PHAssetResourceManager.default().writeData(for: resource, toFile: destination, options: options) { error in
                    guard error == nil else {
                        try? FileManager.default.removeItem(at: directory)
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: destination)
                }
            }
        }

        private func requestPhotoLibraryAccessIfNeeded() async -> Bool {
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            let resolvedStatus = status == .notDetermined
                ? await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                : status
            return resolvedStatus == .authorized || resolvedStatus == .limited
        }
    }
}
