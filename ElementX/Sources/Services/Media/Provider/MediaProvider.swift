//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import ImageIO
import Kingfisher
import UIKit

nonisolated struct MediaProvider: MediaProviderProtocol {
    /// Bump this whenever the encoded representation kept on disk changes. Version 1 caches may
    /// contain a UIImage re-encoded by Kingfisher, which flattens HDR gain maps to SDR.
    private static let imageCacheFormatVersion = 6
    private static let imageCacheSerializer: DefaultCacheSerializer = {
        var serializer = DefaultCacheSerializer()
        serializer.preferCacheOriginalData = true
        return serializer
    }()

    private let mediaLoader: MediaLoaderProtocol
    private let imageCache: Kingfisher.ImageCache
    private let homeserverReachabilityPublisher: CurrentValuePublisher<HomeserverReachability, Never>?
    
    init(mediaLoader: MediaLoaderProtocol,
         imageCache: Kingfisher.ImageCache,
         homeserverReachabilityPublisher: CurrentValuePublisher<HomeserverReachability, Never>?) {
        self.mediaLoader = mediaLoader
        self.imageCache = imageCache
        self.homeserverReachabilityPublisher = homeserverReachabilityPublisher
    }
    
    // MARK: Images
    
    func imageFromSource(_ source: MediaSourceProxy?, size: CGSize?) -> UIImage? {
        guard let url = source?.url else {
            return nil
        }
        let cacheKey = cacheKeyForURL(url, size: size)
        return imageCache.retrieveImageInMemoryCache(forKey: cacheKey, options: nil)
    }
    
    func loadImageFromSource(_ source: MediaSourceProxy, size: CGSize?) async -> Result<UIImage, MediaProviderError> {
        if let image = imageFromSource(source, size: size) {
            return .success(image)
        }
        
        let cacheKey = cacheKeyForURL(source.url, size: size)

        // Kingfisher's default disk deserializer uses UIImage(data:), which doesn't opt in to HDR
        // rendering. Read our original encoded bytes and decode them through UIImageReader instead.
        if let imageData = await loadImageDataFromDiskCache(forKey: cacheKey),
           let image = await decodeImage(data: imageData) {
            try? await imageCache.store(image,
                                        forKey: cacheKey,
                                        cacheSerializer: Self.imageCacheSerializer,
                                        toDisk: false)
            return .success(image)
        }
        
        if let cacheResult = try? await imageCache.retrieveImage(forKey: cacheKey, options: nil),
           let image = cacheResult.image {
            return .success(image)
        }
        
        do {
            let imageData: Data
            if let size {
                imageData = try await mediaLoader.loadMediaThumbnailForSource(source, width: UInt(size.width), height: UInt(size.height))
            } else {
                imageData = try await mediaLoader.loadMediaContentForSource(source)
            }
            
            guard let image = await decodeImage(data: imageData) else {
                MXLog.error("Invalid image data")
                return .failure(.invalidImageData)
            }
            
            // Keep the encoded gain map in the disk cache instead of letting the cache serializer
            // flatten the decoded UIImage to a conventional JPEG or PNG.
            try await imageCache.store(image,
                                       original: imageData,
                                       forKey: cacheKey,
                                       cacheSerializer: Self.imageCacheSerializer)
            
            return .success(image)
        } catch {
            MXLog.error("Failed retrieving image with error: \(error)")
            return .failure(.failedRetrievingImage)
        }
    }
    
    func loadImageRetryingOnReconnection(_ source: MediaSourceProxy, size: CGSize?) -> Task<UIImage, any Error> {
        guard let homeserverReachabilityPublisher else {
            fatalError("This method shouldn't be invoked without a homeserver reachability publisher set.")
        }
        
        return Task {
            if case let .success(image) = await loadImageFromSource(source, size: size) {
                return image
            }
            
            guard !Task.isCancelled else {
                throw MediaProviderError.cancelled
            }
            
            for await reachability in homeserverReachabilityPublisher.values {
                guard !Task.isCancelled else {
                    throw MediaProviderError.cancelled
                }
                
                guard reachability == .reachable else {
                    continue
                }
                
                switch await loadImageFromSource(source, size: size) {
                case .success(let image):
                    return image
                case .failure:
                    // If it fails after a retry with the network available
                    // then something else must be wrong. Bail out.
                    if reachability == .reachable {
                        throw MediaProviderError.cancelled
                    }
                }
            }
            
            throw MediaProviderError.cancelled
        }
    }
    
    func loadImageDataFromSource(_ source: MediaSourceProxy) async -> Result<Data, MediaProviderError> {
        do {
            let imageData = try await mediaLoader.loadMediaContentForSource(source)
            return .success(imageData)
        } catch {
            MXLog.error("Failed retrieving image with error: \(error)")
            return .failure(.failedRetrievingImage)
        }
    }
    
    // MARK: Files
    
    func loadFileFromSource(_ source: MediaSourceProxy, filename: String?) async -> Result<MediaFileHandleProxy, MediaProviderError> {
        do {
            let file = try await mediaLoader.loadMediaFileForSource(source, filename: filename)
            return .success(file)
        } catch {
            MXLog.error("Failed retrieving file with error: \(error)")
            return .failure(.failedRetrievingFile)
        }
    }
    
    // MARK: Thumbnail
    
    func loadThumbnailForSource(source: MediaSourceProxy, size: CGSize) async -> Result<Data, MediaProviderError> {
        do {
            let thumbnailData = try await mediaLoader.loadMediaThumbnailForSource(source, width: UInt(size.width), height: UInt(size.height))
            return .success(thumbnailData)
        } catch {
            MXLog.error("Failed retrieving image with error: \(error)")
            return .failure(.failedRetrievingThumbnail)
        }
    }
    
    // MARK: - Private

    private func loadImageDataFromDiskCache(forKey key: String) async -> Data? {
        let diskStorage = imageCache.diskStorage
        return await Task.detached(priority: .userInitiated) {
            try? diskStorage.value(forKey: key)
        }.value
    }

    private func decodeImage(data: Data) async -> UIImage? {
        #if targetEnvironment(simulator)
        // The iOS 26 Simulator identifies gain-map JPEGs but renders the resulting HDR UIImage
        // as a black frame. Decode the SDR base rendition for Simulator UI tests while retaining
        // the original HDR bytes in the disk cache. Physical devices continue through HDR decode.
        return UIImage(data: data)
        #else
        guard isHighDynamicRangeImage(data: data) else {
            return UIImage(data: data)
        }

        var configuration = UIImageReader.Configuration()
        configuration.prefersHighDynamicRange = true
        return await UIImageReader(configuration: configuration).image(data: data)
        #endif
    }

    #if !targetEnvironment(simulator)
    private func isHighDynamicRangeImage(data: Data) -> Bool {
        if let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
           CGImageSourceCopyAuxiliaryDataInfoAtIndex(imageSource, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil ||
           CGImageSourceCopyAuxiliaryDataInfoAtIndex(imageSource, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil {
            return true
        }

        // ImageIO does not expose Google's appended JPEG/R gain map on every OS version.
        return data.range(of: Data("http://ns.google.com/photos/1.0/container/".utf8)) != nil &&
            data.range(of: Data("http://ns.adobe.com/hdr-gain-map/1.0/".utf8)) != nil
    }
    #endif
    
    private func cacheKeyForURL(_ url: URL, size: CGSize?) -> String {
        let versionedURL = "v\(Self.imageCacheFormatVersion)|\(url.absoluteString)"
        if let size {
            return "\(versionedURL){\(size.width),\(size.height)}"
        } else {
            return versionedURL
        }
    }
}
