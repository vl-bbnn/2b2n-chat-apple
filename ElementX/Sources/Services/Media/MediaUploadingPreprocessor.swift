//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVFoundation
import CoreImage
import ImageIO
import MatrixRustSDK
import UIKit
import UniformTypeIdentifiers

indirect enum MediaUploadingPreprocessorError: Error {
    case maxUploadSizeUnknown
    case maxUploadSizeExceeded(limit: UInt)
    
    case failedProcessingMedia(Error)
    
    case failedProcessingImage(MediaUploadingPreprocessorError)
    case failedProcessingVideo(MediaUploadingPreprocessorError)
    case failedProcessingAudio
    
    case failedGeneratingVideoThumbnail(Error?)
    case failedGeneratingImageThumbnail(Error?)
    
    case failedStrippingLocationData
    case failedResizingImage
    
    case failedConvertingVideo
}

enum MediaInfo {
    case image(imageURL: URL, thumbnailURL: URL?, mediumPreview: ImagePreviewInfo?, imageInfo: ImageInfo)
    case video(videoURL: URL, thumbnailURL: URL, videoInfo: VideoInfo)
    case audio(audioURL: URL, audioInfo: AudioInfo)
    case file(fileURL: URL, fileInfo: FileInfo)
    
    var mimeType: String? {
        switch self {
        case .image(_, _, _, let imageInfo):
            return imageInfo.mimetype
        case .video(_, _, let videoInfo):
            return videoInfo.mimetype
        case .audio(_, let audioInfo):
            return audioInfo.mimetype
        case .file(_, let fileInfo):
            return fileInfo.mimetype
        }
    }
    
    var url: URL {
        switch self {
        case .image(let url, _, _, _),
             .video(let url, _, _),
             .audio(let url, _),
             .file(let url, _):
            return url
        }
    }
    
    var thumbnailURL: URL? {
        switch self {
        case .image(_, let url, _, _):
            return url
        case .video(_, let url, _):
            return url
        case .audio, .file:
            return nil
        }
    }
}

struct ImagePreviewInfo {
    let url: URL
    let info: ThumbnailInfo
}

private struct ImageProcessingInfo {
    let url: URL
    let height: Double
    let width: Double
    let mimeType: String
    let blurhash: String?
}

private struct VideoProcessingInfo {
    let url: URL
    let height: Double
    let width: Double
    let duration: Double // seconds
    let mimeType: String
}

struct MediaUploadingPreprocessor {
    let appSettings: AppSettings
    
    enum Constants {
        static let maximumThumbnailSize = CGSize(width: 800, height: 600)
        static let highDynamicRangeThumbnailMaxPixelSize = 1600.0
        static let optimizedMaxPixelSize = 2048.0
        static let jpegCompressionQuality = 0.78
        static let highDynamicRangeThumbnailJPEGCompressionQuality = 0.9
        static let videoThumbnailTime = 5.0 // seconds
    }
    
    /// Processes media at the given URLs. It will generate thumbnails for images and videos, convert videos to 1080p mp4, strip GPS locations
    /// from images and retrieve associated media information
    /// - Parameter urls: the file URL
    /// - Returns: a collection of results containing specific type of `MediaInfo` depending on the file type
    /// and its associated details or any resulting error
    func processMedia(at urls: [URL], maxUploadSize: UInt) async -> Result<[MediaInfo], MediaUploadingPreprocessorError> {
        await withTaskGroup { taskGroup in
            for (index, url) in urls.enumerated() {
                taskGroup.addTask {
                    let result = await processMedia(at: url, maxUploadSize: maxUploadSize)
                    return (index, result)
                }
            }
            
            // Store results in their respective index as they come in
            var results = [MediaInfo?](repeating: nil, count: urls.count)
            
            for await (index, result) in taskGroup {
                switch result {
                case .success(let mediaInfo):
                    results[index] = mediaInfo
                case .failure(let error):
                    return .failure(error)
                }
            }
            
            return .success(results.compactMap { $0 })
        }
    }
    
    /// Processes media at a given URL. It will generate thumbnails for images and videos, convert videos to 1080p mp4, strip GPS locations
    /// from images and retrieve associated media information
    /// - Parameter url: the file URL
    /// - Returns: a specific type of `MediaInfo` depending on the file type and its associated details
    func processMedia(at url: URL, maxUploadSize: UInt) async -> Result<MediaInfo, MediaUploadingPreprocessorError> {
        // Start by copying the file to a unique temporary location in order to avoid conflicts if processing it multiple times
        // All the other operations will be made relative to it
        let uniqueFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var newURL = uniqueFolder.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: uniqueFolder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: newURL)
        } catch {
            return .failure(.failedProcessingMedia(error))
        }
        
        // Process unknown types as plain files
        guard let type = UTType(filenameExtension: newURL.pathExtension),
              let mimeType = type.preferredMIMEType else {
            return processFile(at: newURL, mimeType: "application/octet-stream", maxUploadSize: maxUploadSize)
        }
        
        if type.conforms(to: .image) {
            return processImage(at: &newURL, type: type, mimeType: mimeType, maxUploadSize: maxUploadSize)
        } else if type.conforms(to: .movie) || type.conforms(to: .video) {
            return await processVideo(at: newURL, maxUploadSize: maxUploadSize)
        } else if type.conforms(to: .audio) {
            return await processAudio(at: newURL, mimeType: mimeType, maxUploadSize: maxUploadSize)
        } else {
            return processFile(at: newURL, mimeType: mimeType, maxUploadSize: maxUploadSize)
        }
    }
    
    // MARK: - Private
    
    /// Prepares an image for upload and generates a thumbnail. SDR images have their location data stripped.
    /// HEIC and HDR originals are preserved byte-for-byte.
    /// - Parameters:
    ///   - url: The image URL
    ///   - type: its UTType
    ///   - mimeType: the mimeType extracted from the UTType
    /// - Returns: Returns a `MediaInfo.image` containing the URLs for the modified image and its thumbnail plus the corresponding `ImageInfo`
    private func processImage(at url: inout URL, type: UTType, mimeType: String, maxUploadSize: UInt) -> Result<MediaInfo, MediaUploadingPreprocessorError> {
        do {
            // Re-encoding HEIC or a gain-map image changes the original image and its metadata.
            // Keep these originals byte-for-byte and only create a separate preview below.
            let isHighDynamicRange = isHighDynamicRangeImage(at: url)
            let shouldPreserveOriginal = isHighDynamicRange || type.conforms(to: .heif)
            if !shouldPreserveOriginal {
                try stripLocationFromImage(at: url, type: type)
            }
            
            var mimeType = mimeType
            if appSettings.optimizeMediaUploads, !type.conforms(to: .gif), !shouldPreserveOriginal {
                let outputType = type.conforms(to: .png) ? UTType.png : .jpeg
                mimeType = outputType.preferredMIMEType ?? "application/octet-stream"
                try resizeImage(at: url, maxPixelSize: Constants.optimizedMaxPixelSize, destination: url, type: outputType)
                
                if let preferredFilenameExtension = outputType.preferredFilenameExtension,
                   url.pathExtension != preferredFilenameExtension {
                    let convertedURL = url.deletingPathExtension().appendingPathExtension(preferredFilenameExtension)
                    do {
                        try FileManager.default.moveItem(at: url, to: convertedURL)
                    } catch {
                        return .failure(.failedResizingImage)
                    }
                    url = convertedURL
                }
            }
            
            let thumbnailResult = try generateThumbnailForImage(at: url,
                                                                maxPixelSize: max(Constants.maximumThumbnailSize.height,
                                                                                  Constants.maximumThumbnailSize.width),
                                                                filenamePrefix: "thumbnail")
            let mediumPreviewResult = try generateThumbnailForImage(at: url,
                                                                    maxPixelSize: Constants.highDynamicRangeThumbnailMaxPixelSize,
                                                                    filenamePrefix: "medium-preview")
            
            guard let imageSource = CGImageSourceCreateWithURL(url as NSURL, nil),
                  let imageSize = imageSource.size else {
                return .failure(.failedProcessingImage(.failedStrippingLocationData))
            }
            
            let fileSize = (try? FileManager.default.sizeForItem(at: url)) ?? 0
            let thumbnailFileSize = (try? FileManager.default.sizeForItem(at: thumbnailResult.url)) ?? 0
            let mediumPreviewFileSize = (try? FileManager.default.sizeForItem(at: mediumPreviewResult.url)) ?? 0
            
            guard fileSize < maxUploadSize,
                  thumbnailFileSize < maxUploadSize,
                  mediumPreviewFileSize < maxUploadSize else { return .failure(.maxUploadSizeExceeded(limit: maxUploadSize)) }
            
            let thumbnailInfo = ThumbnailInfo(height: UInt64(thumbnailResult.height),
                                              width: UInt64(thumbnailResult.width),
                                              mimetype: thumbnailResult.mimeType,
                                              size: UInt64(thumbnailFileSize))
            let mediumPreviewInfo = ThumbnailInfo(height: UInt64(mediumPreviewResult.height),
                                                  width: UInt64(mediumPreviewResult.width),
                                                  mimetype: mediumPreviewResult.mimeType,
                                                  size: UInt64(mediumPreviewFileSize))
            
            let imageInfo = ImageInfo(height: UInt64(imageSize.height),
                                      width: UInt64(imageSize.width),
                                      mimetype: mimeType,
                                      size: UInt64(fileSize),
                                      thumbnailInfo: thumbnailInfo,
                                      thumbnailSource: nil,
                                      blurhash: thumbnailResult.blurhash,
                                      isAnimated: nil)
            
            let mediaInfo = MediaInfo.image(imageURL: url,
                                            thumbnailURL: thumbnailResult.url,
                                            mediumPreview: .init(url: mediumPreviewResult.url, info: mediumPreviewInfo),
                                            imageInfo: imageInfo)
            
            return .success(mediaInfo)
        } catch {
            return .failure(.failedProcessingImage(error))
        }
    }
    
    /// Prepares a video for upload. Converts it to an 1080p mp4 and generates a thumbnail
    /// - Parameters:
    ///   - url: The video URL
    ///   - type: its UTType
    ///   - mimeType: the mimeType extracted from the UTType
    /// - Returns: Returns a `MediaInfo.video` containing the URLs for the modified video and its thumbnail plus the corresponding `VideoInfo`
    private func processVideo(at url: URL, maxUploadSize: UInt) async -> Result<MediaInfo, MediaUploadingPreprocessorError> {
        do {
            let result = try await convertVideoToMP4(url, targetFileSize: UInt(maxUploadSize))
            let thumbnailResult = try await generateThumbnailForVideoAt(result.url)
            
            let videoSize = (try? FileManager.default.sizeForItem(at: result.url)) ?? 0
            let thumbnailSize = (try? FileManager.default.sizeForItem(at: thumbnailResult.url)) ?? 0
            
            guard videoSize < maxUploadSize, thumbnailSize < maxUploadSize else { return .failure(.maxUploadSizeExceeded(limit: maxUploadSize)) }
            
            let thumbnailInfo = ThumbnailInfo(height: UInt64(thumbnailResult.height),
                                              width: UInt64(thumbnailResult.width),
                                              mimetype: thumbnailResult.mimeType,
                                              size: UInt64(thumbnailSize))
            
            let videoInfo = VideoInfo(duration: result.duration,
                                      height: UInt64(result.height),
                                      width: UInt64(result.width),
                                      mimetype: result.mimeType,
                                      size: UInt64(videoSize),
                                      thumbnailInfo: thumbnailInfo,
                                      thumbnailSource: nil,
                                      blurhash: thumbnailResult.blurhash)
            
            let mediaInfo = MediaInfo.video(videoURL: result.url, thumbnailURL: thumbnailResult.url, videoInfo: videoInfo)
            
            return .success(mediaInfo)
        } catch {
            return .failure(.failedProcessingVideo(error))
        }
    }
    
    /// Prepares a file for upload.
    /// - Parameters:
    ///   - url: The audio URL
    ///   - mimeType: the mimeType extracted from the UTType
    /// - Returns: Returns a `MediaInfo.audio` containing the file URL plus the corresponding `AudioInfo`
    private func processAudio(at url: URL, mimeType: String?, maxUploadSize: UInt) async -> Result<MediaInfo, MediaUploadingPreprocessorError> {
        let fileSize = (try? FileManager.default.sizeForItem(at: url)) ?? 0
        
        guard fileSize < maxUploadSize else { return .failure(.maxUploadSizeExceeded(limit: maxUploadSize)) }
        
        let asset = AVURLAsset(url: url)
        guard let durationInSeconds = try? await asset.load(.duration).seconds else {
            return .failure(.failedProcessingAudio)
        }
        
        let audioInfo = AudioInfo(duration: durationInSeconds, size: UInt64(fileSize), mimetype: mimeType)
        return .success(.audio(audioURL: url, audioInfo: audioInfo))
    }
    
    /// Prepares a file for upload.
    /// - Parameters:
    ///   - url: The file URL
    ///   - type: its UTType
    ///   - mimeType: the mimeType extracted from the UTType
    /// - Returns: Returns a `MediaInfo.file` containing the file URL plus the corresponding `FileInfo`
    private func processFile(at url: URL, mimeType: String?, maxUploadSize: UInt) -> Result<MediaInfo, MediaUploadingPreprocessorError> {
        let fileSize = (try? FileManager.default.sizeForItem(at: url)) ?? 0
        
        guard fileSize < maxUploadSize else { return .failure(.maxUploadSizeExceeded(limit: maxUploadSize)) }
        
        let fileInfo = FileInfo(mimetype: mimeType, size: UInt64(fileSize), thumbnailInfo: nil, thumbnailSource: nil)
        return .success(.file(fileURL: url, fileInfo: fileInfo))
    }
    
    // MARK: Image Helpers
    
    /// Removes the GPS dictionary from an image's metadata
    /// - Parameters:
    ///   - url: the URL for the original image
    ///   - type: its UTType
    /// - Returns: the URL for the modified image and its size as an `ImageProcessingResult`
    private func stripLocationFromImage(at url: URL, type: UTType) throws(MediaUploadingPreprocessorError) {
        guard let originalData = NSData(contentsOf: url),
              let imageSource = CGImageSourceCreateWithData(originalData, nil) else {
            throw .failedStrippingLocationData
        }
        
        guard let originalMetadata = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil),
              (originalMetadata as NSDictionary).value(forKeyPath: "\(kCGImagePropertyGPSDictionary)") != nil else {
            MXLog.info("No GPS metadata found. Nothing to do.")
            return
        }
        
        let count = CGImageSourceGetCount(imageSource)
        let metadataKeysToRemove = [kCGImagePropertyGPSDictionary: kCFNull]
        
        let data = NSMutableData()
        
        // Certain type identifiers cannot be used for image destinations, fall
        // back to `public.jpeg` when that's the case
        let destination = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, count, nil) ??
            CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, count, nil)
        guard let destination else {
            throw .failedStrippingLocationData
        }
        
        CGImageDestinationAddImageFromSource(destination, imageSource, 0, metadataKeysToRemove as NSDictionary)
        CGImageDestinationFinalize(destination)
        
        do {
            try data.write(to: url)
        } catch {
            throw .failedStrippingLocationData
        }
    }
    
    /// Generates a thumbnail for an image
    /// - Parameter url: the original image URL
    /// - Returns: the URL for the resulting thumbnail and its sizing info as an `ImageProcessingResult`
    private func generateThumbnailForImage(at url: URL,
                                           maxPixelSize: CGFloat,
                                           filenamePrefix: String) throws(MediaUploadingPreprocessorError) -> ImageProcessingInfo {
        let thumbnailFileName = "\(filenamePrefix)-\((url.lastPathComponent as NSString).deletingPathExtension).jpeg"
        let thumbnailURL = url.deletingLastPathComponent().appendingPathComponent(thumbnailFileName)

        if isHighDynamicRangeImage(at: url) {
            return try generateHighDynamicRangeThumbnail(at: url, destination: thumbnailURL, maxPixelSize: maxPixelSize)
        }
        
        do {
            try resizeImage(at: url, maxPixelSize: maxPixelSize, destination: thumbnailURL, type: .jpeg)
        } catch {
            throw .failedGeneratingImageThumbnail(error)
        }
        
        guard let thumbnail = UIImage(contentsOfFile: thumbnailURL.path(percentEncoded: false)) else {
            throw .failedGeneratingImageThumbnail(nil)
        }
        
        let blurhash = thumbnail.blurHash(numberOfComponents: (3, 3))
        
        return .init(url: thumbnailURL, height: thumbnail.size.height, width: thumbnail.size.width, mimeType: "image/jpeg", blurhash: blurhash)
    }

    /// Creates an ISO gain-map JPEG. Existing gain maps are scaled without decoding the complete
    /// HDR rendition, which is both cheaper and supported by the iOS Simulator.
    private func generateHighDynamicRangeThumbnail(at url: URL,
                                                   destination: URL,
                                                   maxPixelSize: CGFloat) throws(MediaUploadingPreprocessorError) -> ImageProcessingInfo {
        if hasAuxiliaryGainMap(at: url) {
            return try generateHighDynamicRangeThumbnailPreservingGainMap(at: url,
                                                                          destination: destination,
                                                                          maxPixelSize: maxPixelSize)
        }

        // ImageIO on the simulator (and on some older OS versions) does not expose the
        // gain map embedded in Google's JPEG/R container as auxiliary image data. Keep a
        // byte-for-byte copy as the thumbnail in that case: resizing only the primary JPEG
        // would silently turn an Ultra HDR message into SDR for other clients.
        if hasEmbeddedUltraHDRGainMap(at: url) {
            return try copyEmbeddedUltraHDRThumbnail(at: url, destination: destination)
        }

        return try generateHighDynamicRangeThumbnailDerivingGainMap(at: url,
                                                                    destination: destination,
                                                                    maxPixelSize: maxPixelSize)
    }

    private func copyEmbeddedUltraHDRThumbnail(at url: URL,
                                               destination: URL) throws(MediaUploadingPreprocessorError) -> ImageProcessingInfo {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let imageSize = imageSource.size else {
            throw .failedGeneratingImageThumbnail(nil)
        }

        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            throw .failedGeneratingImageThumbnail(error)
        }

        let blurhash = standardDynamicRangeImage(at: destination)?.blurHash(numberOfComponents: (3, 3))
        return .init(url: destination,
                     height: imageSize.height,
                     width: imageSize.width,
                     mimeType: "image/jpeg",
                     blurhash: blurhash)
    }

    private func generateHighDynamicRangeThumbnailPreservingGainMap(at url: URL,
                                                                    destination: URL,
                                                                    maxPixelSize: CGFloat) throws(MediaUploadingPreprocessorError) -> ImageProcessingInfo {
        let imageOptions: [CIImageOption: Any] = [.applyOrientationProperty: true]
        let gainMapOptions: [CIImageOption: Any] = [
            .applyOrientationProperty: true,
            .auxiliaryHDRGainMap: true
        ]
        guard let baseImage = CIImage(contentsOf: url, options: imageOptions),
              let gainMapImage = CIImage(contentsOf: url, options: gainMapOptions),
              !baseImage.extent.isEmpty,
              !gainMapImage.extent.isEmpty,
              let colorSpace = baseImage.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3) else {
            throw .failedGeneratingImageThumbnail(nil)
        }

        let scale = min(1, maxPixelSize / max(baseImage.extent.width, baseImage.extent.height))
        let targetSize = CGSize(width: max(1, floor(baseImage.extent.width * scale)),
                                height: max(1, floor(baseImage.extent.height * scale)))
        let targetExtent = CGRect(origin: .zero, size: targetSize)
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        let scaledBaseImage = baseImage
            .transformed(by: transform)
            .cropped(to: targetExtent)
        let scaledGainMapExtent = CGRect(x: 0,
                                         y: 0,
                                         width: max(1, floor(gainMapImage.extent.width * scale)),
                                         height: max(1, floor(gainMapImage.extent.height * scale)))
        let scaledGainMapImage = gainMapImage
            .transformed(by: transform)
            .cropped(to: scaledGainMapExtent)
            .settingProperties(gainMapImage.properties)

        let qualityKey = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        var representationOptions: [CIImageRepresentationOption: Any] = [
            qualityKey: Constants.highDynamicRangeThumbnailJPEGCompressionQuality,
            .hdrGainMapImage: scaledGainMapImage
        ]
        if gainMapImage.colorSpace?.model == .rgb {
            representationOptions[.hdrGainMapAsRGB] = true
        }

        let context = CIContext(options: [.cacheIntermediates: false])
        defer { context.clearCaches() }
        try? FileManager.default.removeItem(at: destination)
        do {
            try context.writeJPEGRepresentation(of: scaledBaseImage,
                                                to: destination,
                                                colorSpace: colorSpace,
                                                options: representationOptions)
            try addUltraHDRCompatibilityMetadata(sourceURL: url, thumbnailURL: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw .failedGeneratingImageThumbnail(error)
        }

        guard isHighDynamicRangeImage(at: destination) else {
            try? FileManager.default.removeItem(at: destination)
            throw .failedGeneratingImageThumbnail(nil)
        }

        let blurhash = standardDynamicRangeImage(at: destination)?.blurHash(numberOfComponents: (3, 3))
        return .init(url: destination,
                     height: targetSize.height,
                     width: targetSize.width,
                     mimeType: "image/jpeg",
                     blurhash: blurhash)
    }

    private func generateHighDynamicRangeThumbnailDerivingGainMap(at url: URL,
                                                                  destination: URL,
                                                                  maxPixelSize: CGFloat) throws(MediaUploadingPreprocessorError) -> ImageProcessingInfo {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let sourceSize = imageSource.size else {
            throw .failedGeneratingImageThumbnail(nil)
        }

        let scale = min(1, maxPixelSize / max(sourceSize.width, sourceSize.height))
        let targetSize = CGSize(width: max(1, floor(sourceSize.width * scale)),
                                height: max(1, floor(sourceSize.height * scale)))
        let thumbnailMaxPixelSize = max(targetSize.width, targetSize.height)
        let decodeOptions: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR
        ]

        guard let hdrImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, decodeOptions as CFDictionary) else {
            throw .failedGeneratingImageThumbnail(nil)
        }

        try? FileManager.default.removeItem(at: destination)
        guard let imageDestination = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw .failedGeneratingImageThumbnail(nil)
        }

        let encodeOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: Constants.highDynamicRangeThumbnailJPEGCompressionQuality,
            kCGImageDestinationEncodeRequest: kCGImageDestinationEncodeToISOGainmap,
            kCGImageDestinationEncodeRequestOptions: [kCGImageDestinationEncodeBaseIsSDR: true]
        ]
        CGImageDestinationAddImage(imageDestination, hdrImage, encodeOptions as CFDictionary)
        guard CGImageDestinationFinalize(imageDestination) else {
            try? FileManager.default.removeItem(at: destination)
            throw .failedGeneratingImageThumbnail(nil)
        }

        do {
            try addUltraHDRCompatibilityMetadata(sourceURL: url, thumbnailURL: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        guard isHighDynamicRangeImage(at: destination) else {
            try? FileManager.default.removeItem(at: destination)
            throw .failedGeneratingImageThumbnail(nil)
        }

        let blurhash = standardDynamicRangeImage(at: destination)?.blurHash(numberOfComponents: (3, 3))
        return .init(url: destination,
                     height: Double(hdrImage.height),
                     width: Double(hdrImage.width),
                     mimeType: "image/jpeg",
                     blurhash: blurhash)
    }

    /// ImageIO and Core Image only write Apple's gain-map description on the auxiliary JPEG.
    /// Android Ultra HDR additionally requires Adobe calibration XMP on that JPEG, Google
    /// Container XMP on the primary JPEG and matching MPF lengths.
    private func addUltraHDRCompatibilityMetadata(sourceURL: URL,
                                                  thumbnailURL: URL) throws(MediaUploadingPreprocessorError) {
        let sourceData: Data
        var thumbnailData: Data
        do {
            sourceData = try Data(contentsOf: sourceURL)
            thumbnailData = try Data(contentsOf: thumbnailURL)
        } catch {
            throw .failedGeneratingImageThumbnail(error)
        }

        guard let gainMapXMP = standardGainMapXMPApp1Segment(in: sourceData) ?? generatedGainMapXMPApp1Segment(at: sourceURL),
              let initialMPF = mpfInfo(in: thumbnailData),
              thumbnailData[initialMPF.secondImageOffset] == 0xFF,
              thumbnailData[initialMPF.secondImageOffset + 1] == 0xD8 else {
            throw .failedGeneratingImageThumbnail(nil)
        }

        thumbnailData.insert(contentsOf: gainMapXMP, at: initialMPF.secondImageOffset + 2)
        let auxiliaryImageLength = initialMPF.secondImageLength + gainMapXMP.count
        guard writeUInt32(auxiliaryImageLength,
                          at: initialMPF.secondImageLengthOffset,
                          byteOrder: initialMPF.byteOrder,
                          in: &thumbnailData),
            let containerXMP = ultraHDRContainerXMPApp1Segment(auxiliaryImageLength: auxiliaryImageLength) else {
            throw .failedGeneratingImageThumbnail(nil)
        }

        // Inserting before the MPF segment moves both MPF and auxiliary JPEG equally, so the
        // auxiliary data offset remains valid. The primary image length still needs updating.
        thumbnailData.insert(contentsOf: containerXMP, at: 2)
        guard let updatedMPF = mpfInfo(in: thumbnailData),
              writeUInt32(updatedMPF.primaryImageLength + containerXMP.count,
                          at: updatedMPF.primaryImageLengthOffset,
                          byteOrder: updatedMPF.byteOrder,
                          in: &thumbnailData) else {
            throw .failedGeneratingImageThumbnail(nil)
        }

        do {
            try thumbnailData.write(to: thumbnailURL, options: .atomic)
        } catch {
            throw .failedGeneratingImageThumbnail(error)
        }
    }

    private func standardGainMapXMPApp1Segment(in data: Data) -> Data? {
        let startOfImage = Data([0xFF, 0xD8])
        let gainMapNamespace = Data("http://ns.adobe.com/hdr-gain-map/1.0/".utf8)
        let gainMapVersion = Data("Version=\"1.0\"".utf8)
        let gainMapMaximum = Data("GainMapMax=\"".utf8)
        var searchOffset = 0

        while searchOffset + startOfImage.count <= data.count,
              let imageRange = data.range(of: startOfImage, in: searchOffset..<data.count) {
            var markerOffset = imageRange.upperBound
            while markerOffset + 4 <= data.count, data[markerOffset] == 0xFF {
                let marker = data[markerOffset + 1]
                if marker == 0xDA || marker == 0xD9 { break }
                if marker == 0x01 || (0xD0...0xD7).contains(marker) {
                    markerOffset += 2
                    continue
                }

                guard let segmentLength = readUInt16(at: markerOffset + 2, byteOrder: .bigEndian, in: data),
                      segmentLength >= 2 else { break }
                let segmentEnd = markerOffset + 2 + segmentLength
                guard segmentEnd <= data.count else { break }
                let payload = data[(markerOffset + 4)..<segmentEnd]
                if marker == 0xE1,
                   payload.range(of: gainMapNamespace) != nil,
                   payload.range(of: gainMapVersion) != nil,
                   payload.range(of: gainMapMaximum) != nil {
                    return data[markerOffset..<segmentEnd]
                }
                markerOffset = segmentEnd
            }
            searchOffset = imageRange.upperBound
        }
        return nil
    }

    private func generatedGainMapXMPApp1Segment(at url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let auxiliaryInfo = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) ??
              CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap),
              let metadataValue = (auxiliaryInfo as NSDictionary)[kCGImageAuxiliaryDataInfoMetadata] else {
            return nil
        }
        let metadata = metadataValue as! CGImageMetadata
        guard let metadataData = CGImageMetadataCreateXMPData(metadata, nil) as Data?,
              let metadataXML = String(data: metadataData, encoding: .utf8),
              let gainMapMinimum = firstXMLElementValue(named: "GainMapMin", in: metadataXML),
              let gainMapMaximum = firstXMLElementValue(named: "GainMapMax", in: metadataXML) else {
            return nil
        }

        let gamma = firstXMLElementValue(named: "Gamma", in: metadataXML) ?? "1.0"
        let offsetSDR = firstXMLElementValue(named: "BaseOffset", in: metadataXML) ?? "0.0"
        let offsetHDR = firstXMLElementValue(named: "AlternateOffset", in: metadataXML) ?? "0.0"
        let capacityMinimum = firstXMLElementValue(named: "BaseHeadroom", in: metadataXML) ?? "0.0"
        let capacityMaximum = firstXMLElementValue(named: "AlternateHeadroom", in: metadataXML) ?? gainMapMaximum
        let xmp = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:hdrgm="http://ns.adobe.com/hdr-gain-map/1.0/" hdrgm:Version="1.0" hdrgm:GainMapMin="\(gainMapMinimum)" hdrgm:GainMapMax="\(gainMapMaximum)" hdrgm:Gamma="\(gamma)" hdrgm:OffsetSDR="\(offsetSDR)" hdrgm:OffsetHDR="\(offsetHDR)" hdrgm:HDRCapacityMin="\(capacityMinimum)" hdrgm:HDRCapacityMax="\(capacityMaximum)" hdrgm:BaseRenditionIsHDR="False"/></rdf:RDF></x:xmpmeta>
        """
        return xmpApp1Segment(xmp)
    }

    private func ultraHDRContainerXMPApp1Segment(auxiliaryImageLength: Int) -> Data? {
        let xmp = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:Container="http://ns.google.com/photos/1.0/container/" xmlns:Item="http://ns.google.com/photos/1.0/container/item/" xmlns:hdrgm="http://ns.adobe.com/hdr-gain-map/1.0/" hdrgm:Version="1.0"><Container:Directory><rdf:Seq><rdf:li rdf:parseType="Resource"><Container:Item Item:Semantic="Primary" Item:Mime="image/jpeg"/></rdf:li><rdf:li rdf:parseType="Resource"><Container:Item Item:Semantic="GainMap" Item:Mime="image/jpeg" Item:Length="\(auxiliaryImageLength)"/></rdf:li></rdf:Seq></Container:Directory></rdf:Description></rdf:RDF></x:xmpmeta>
        """
        return xmpApp1Segment(xmp)
    }

    private func xmpApp1Segment(_ xmp: String) -> Data? {
        guard let xmpData = xmp.data(using: .utf8) else { return nil }
        var payload = Data("http://ns.adobe.com/xap/1.0/\0".utf8)
        payload.append(xmpData)
        let segmentLength = payload.count + 2
        guard segmentLength <= Int(UInt16.max) else { return nil }

        var segment = Data([0xFF, 0xE1, UInt8(segmentLength >> 8), UInt8(segmentLength & 0xFF)])
        segment.append(payload)
        return segment
    }

    private func firstXMLElementValue(named name: String, in xml: String) -> String? {
        guard let openingTag = xml.range(of: ":\(name)>"),
              let closingTag = xml[openingTag.upperBound...].firstIndex(of: "<") else {
            return nil
        }
        return String(xml[openingTag.upperBound..<closingTag])
    }

    private func mpfInfo(in data: Data) -> MPFInfo? {
        guard let mpfRange = data.range(of: Data("MPF\0".utf8)) else { return nil }
        let tiffOffset = mpfRange.upperBound
        guard tiffOffset + 8 <= data.count else { return nil }
        let byteOrder: MPFByteOrder
        switch (data[tiffOffset], data[tiffOffset + 1]) {
        case (0x4D, 0x4D): byteOrder = .bigEndian
        case (0x49, 0x49): byteOrder = .littleEndian
        default: return nil
        }

        guard let imageFileDirectoryRelativeOffset = readUInt32(at: tiffOffset + 4, byteOrder: byteOrder, in: data) else { return nil }
        let imageFileDirectoryOffset = tiffOffset + imageFileDirectoryRelativeOffset
        guard let entryCount = readUInt16(at: imageFileDirectoryOffset, byteOrder: byteOrder, in: data) else { return nil }
        var mpEntryOffset: Int?
        for index in 0..<entryCount {
            let entryOffset = imageFileDirectoryOffset + 2 + index * 12
            guard let tag = readUInt16(at: entryOffset, byteOrder: byteOrder, in: data),
                  let valueOffset = readUInt32(at: entryOffset + 8, byteOrder: byteOrder, in: data) else { return nil }
            if tag == 0xB002 {
                mpEntryOffset = tiffOffset + valueOffset
                break
            }
        }

        guard let mpEntryOffset,
              let primaryImageLength = readUInt32(at: mpEntryOffset + 4, byteOrder: byteOrder, in: data),
              let secondImageLength = readUInt32(at: mpEntryOffset + 20, byteOrder: byteOrder, in: data),
              let secondImageRelativeOffset = readUInt32(at: mpEntryOffset + 24, byteOrder: byteOrder, in: data) else { return nil }
        let secondImageOffset = tiffOffset + secondImageRelativeOffset
        guard secondImageOffset + 2 <= data.count else { return nil }
        return .init(byteOrder: byteOrder,
                     primaryImageLength: primaryImageLength,
                     primaryImageLengthOffset: mpEntryOffset + 4,
                     secondImageLength: secondImageLength,
                     secondImageLengthOffset: mpEntryOffset + 20,
                     secondImageOffset: secondImageOffset)
    }

    private func readUInt16(at offset: Int, byteOrder: MPFByteOrder, in data: Data) -> Int? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        switch byteOrder {
        case .bigEndian: return Int(data[offset]) << 8 | Int(data[offset + 1])
        case .littleEndian: return Int(data[offset + 1]) << 8 | Int(data[offset])
        }
    }

    private func readUInt32(at offset: Int, byteOrder: MPFByteOrder, in data: Data) -> Int? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let bytes = (0..<4).map { UInt32(data[offset + $0]) }
        let value: UInt32
        switch byteOrder {
        case .bigEndian: value = bytes[0] << 24 | bytes[1] << 16 | bytes[2] << 8 | bytes[3]
        case .littleEndian: value = bytes[3] << 24 | bytes[2] << 16 | bytes[1] << 8 | bytes[0]
        }
        return Int(value)
    }

    private func writeUInt32(_ value: Int, at offset: Int, byteOrder: MPFByteOrder, in data: inout Data) -> Bool {
        guard value >= 0, value <= Int(UInt32.max), offset >= 0, offset + 4 <= data.count else { return false }
        let value = UInt32(value)
        let bytes: [UInt8]
        switch byteOrder {
        case .bigEndian: bytes = [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        case .littleEndian: bytes = [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)]
        }
        data.replaceSubrange(offset..<(offset + 4), with: bytes)
        return true
    }

    private enum MPFByteOrder {
        case bigEndian
        case littleEndian
    }

    private struct MPFInfo {
        let byteOrder: MPFByteOrder
        let primaryImageLength: Int
        let primaryImageLengthOffset: Int
        let secondImageLength: Int
        let secondImageLengthOffset: Int
        let secondImageOffset: Int
    }

    private func isHighDynamicRangeImage(at url: URL) -> Bool {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return false
        }
        if hasAuxiliaryGainMap(in: imageSource) || hasEmbeddedUltraHDRGainMap(at: url) {
            return true
        }

        // iPhone HDR HEIF/HEIC assets expose their HDR payload as an auxiliary
        // gain map. Do not run UIImageReader's full-resolution HDR decode for a
        // regular HEIF without one: on large 12 MP SDR assets that decode is
        // needlessly expensive and can block media processing for minutes.
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .heif) {
            return false
        }

        var configuration = UIImageReader.Configuration()
        configuration.prefersHighDynamicRange = true
        return UIImageReader(configuration: configuration).image(contentsOf: url)?.isHighDynamicRange == true
    }

    private func hasAuxiliaryGainMap(at url: URL) -> Bool {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return false
        }
        return hasAuxiliaryGainMap(in: imageSource)
    }

    private func hasAuxiliaryGainMap(in imageSource: CGImageSource) -> Bool {
        CGImageSourceCopyAuxiliaryDataInfoAtIndex(imageSource, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil ||
            CGImageSourceCopyAuxiliaryDataInfoAtIndex(imageSource, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
    }

    /// Detects a Google/Adobe JPEG/R gain map when ImageIO does not surface it.
    /// Require both XMP namespaces and a valid MPF second JPEG to avoid treating an
    /// arbitrary image that merely contains the namespace strings as HDR.
    private func hasEmbeddedUltraHDRGainMap(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.range(of: Data("http://ns.adobe.com/hdr-gain-map/1.0/".utf8)) != nil,
              data.range(of: Data("http://ns.google.com/photos/1.0/container/".utf8)) != nil,
              data.range(of: Data("GainMap".utf8)) != nil,
              let mpf = mpfInfo(in: data),
              mpf.secondImageLength > 0,
              mpf.secondImageOffset + mpf.secondImageLength <= data.count,
              data[mpf.secondImageOffset] == 0xFF,
              data[mpf.secondImageOffset + 1] == 0xD8 else {
            return false
        }
        return true
    }

    private func standardDynamicRangeImage(at url: URL) -> UIImage? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, [
                  kCGImageSourceDecodeRequest: kCGImageSourceDecodeToSDR
              ] as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: image)
    }
    
    private func resizeImage(at url: URL, maxPixelSize: CGFloat, destination: URL, type: UTType) throws(MediaUploadingPreprocessorError) {
        guard let imageSource = CGImageSourceCreateWithURL(url as NSURL, nil) else {
            throw .failedResizingImage
        }
        
        try resizeImage(withSource: imageSource, maxPixelSize: maxPixelSize, destination: destination, type: type)
    }
    
    /// Aspect ratio resizes an image so it fits in the given size. This is useful for resizing images without loading them directly into memory
    /// - Parameters:
    ///   - imageSource: the original image `CGImageSource`
    ///   - maxPixelSize: maximum resulting size for the largest dimension of the image.
    /// - Returns: the resized image
    private func resizeImage(withSource imageSource: CGImageSource, maxPixelSize: CGFloat, destination destinationURL: URL, type: UTType) throws(MediaUploadingPreprocessorError) {
        let options: [NSString: Any] = [
            // The maximum width and height in pixels of a thumbnail.
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Should include kCGImageSourceCreateThumbnailWithTransform: true in the options dictionary. Otherwise, the image result will appear rotated when an image is taken from camera in the portrait orientation.
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        
        guard let scaledImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as NSDictionary),
              let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, type.identifier as CFString, 1, nil) else {
            throw .failedResizingImage
        }
        let properties = [kCGImageDestinationLossyCompressionQuality: Constants.jpegCompressionQuality]
        
        CGImageDestinationAddImage(destination, scaledImage, properties as NSDictionary)
        CGImageDestinationFinalize(destination)
    }
    
    // MARK: Video Helpers
    
    /// Generates a thumbnail for the video at the given URL
    /// - Parameter url: the video URL
    /// - Returns: the URL for the resulting thumbnail and its sizing info as an `ImageProcessingResult`
    private func generateThumbnailForVideoAt(_ url: URL) async throws(MediaUploadingPreprocessorError) -> ImageProcessingInfo {
        let assetImageGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        assetImageGenerator.appliesPreferredTrackTransform = true
        assetImageGenerator.maximumSize = Constants.maximumThumbnailSize
        
        // Avoid the first frames as on a lot of videos they're black.
        // If the specified seconds are longer than the actual video a frame close to the end of the video will be used, at AVFoundation's discretion
        let location = CMTime(seconds: Constants.videoThumbnailTime, preferredTimescale: 1)
        
        let cgImage: CGImage
        do {
            cgImage = try await assetImageGenerator.image(at: location).image
        } catch {
            throw .failedGeneratingVideoThumbnail(error)
        }
        
        let thumbnail = UIImage(cgImage: cgImage)
        
        guard let data = thumbnail.jpegData(compressionQuality: Constants.jpegCompressionQuality) else {
            throw .failedGeneratingVideoThumbnail(nil)
        }
        
        let blurhash = thumbnail.blurHash(numberOfComponents: (3, 3))
        
        let fileName = "\((url.lastPathComponent as NSString).deletingPathExtension).jpeg"
        let thumbnailURL = url.deletingLastPathComponent().appendingPathComponent(fileName)
        
        do {
            try data.write(to: thumbnailURL)
        } catch {
            throw .failedGeneratingVideoThumbnail(error)
        }
        
        return .init(url: thumbnailURL, height: thumbnail.size.height, width: thumbnail.size.width, mimeType: "image/jpeg", blurhash: blurhash)
    }
    
    /// Converts the given video to an 1080p mp4
    /// - Parameters:
    ///   - url: the original video URL
    ///   - targetFileSize: the maximum resulting file size. 90% of this will be used
    /// - Returns: the URL for the resulting video and its media info as a `VideoProcessingResult`
    private func convertVideoToMP4(_ url: URL, targetFileSize: UInt) async throws(MediaUploadingPreprocessorError) -> VideoProcessingInfo {
        let asset = AVURLAsset(url: url)
        let presetName = appSettings.optimizeMediaUploads ? AVAssetExportPreset1280x720 : AVAssetExportPreset1920x1080
        
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: presetName) else {
            throw .failedConvertingVideo
        }
        
        // AVAssetExportSession will fail if the output URL already exists
        let uuid = UUID().uuidString
        let originalFilenameWithoutExtension = url.deletingPathExtension().lastPathComponent
        let outputURL = url.deletingLastPathComponent().appendingPathComponent("\(uuid)-\(originalFilenameWithoutExtension).mp4")
        
        try? FileManager.default.removeItem(at: outputURL)
        
        guard exportSession.supportedFileTypes.contains(AVFileType.mp4) else {
            throw .failedConvertingVideo
        }
        
        if targetFileSize > 0 {
            // Reduce the target file size by 10% as fileLengthLimit isn't a hard limit
            exportSession.fileLengthLimit = Int64(Double(targetFileSize) * 0.9)
        }
        
        do {
            try await exportSession.export(to: outputURL, as: .mp4)
        } catch {
            MXLog.error("Video conversion failed: \(error)")
            throw .failedConvertingVideo
        }
        
        // Delete the original
        try? FileManager.default.removeItem(at: url)
        // Strip the UUID from the new version
        let newOutputURL = url.deletingLastPathComponent().appendingPathComponent("\(originalFilenameWithoutExtension).mp4")
        
        do { try FileManager.default.moveItem(at: outputURL, to: newOutputURL) } catch {
            throw .failedConvertingVideo
        }
        
        let newAsset = AVURLAsset(url: newOutputURL)
        guard let track = try? await newAsset.loadTracks(withMediaType: .video).first,
              let durationInSeconds = try? await newAsset.load(.duration).seconds,
              let adjustedNaturalSize = try? await track.size else {
            throw .failedConvertingVideo
        }
        
        return .init(url: newOutputURL,
                     height: adjustedNaturalSize.height,
                     width: adjustedNaturalSize.width,
                     duration: durationInSeconds,
                     mimeType: "video/mp4")
    }
}

// MARK: - Extensions

private extension CGImageSource {
    var size: CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(self, 0, nil) as? [NSString: Any],
              var width = properties[kCGImagePropertyPixelWidth] as? Int,
              var height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        
        // Make sure the width and height are the correct way around if an orientation is set.
        if let orientationValue = properties[kCGImagePropertyOrientation] as? UInt32,
           let orientation = CGImagePropertyOrientation(rawValue: orientationValue) {
            switch orientation {
            case .up, .down, .upMirrored, .downMirrored:
                break
            case .left, .right, .leftMirrored, .rightMirrored:
                swap(&width, &height)
            }
        }
        
        return CGSize(width: width, height: height)
    }
}

private extension AVAssetTrack {
    var size: CGSize {
        get async throws {
            let naturalSize = try await load(.naturalSize)
            guard mediaType == .video else {
                return naturalSize
            }
            
            // The naturalSize does not take the preferredTransform into consideration resulting
            // in portrait videos reporting inverted values.
            let transform = try await load(.preferredTransform)
            
            switch (transform.a, transform.b, transform.c, transform.d) {
            case (0, 1, -1, 0), (0, -1, 1, 0):
                return CGSize(width: naturalSize.height, height: naturalSize.width)
            default:
                return CGSize(width: naturalSize.width, height: naturalSize.height)
            }
        }
    }
}
