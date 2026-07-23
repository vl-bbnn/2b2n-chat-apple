//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import UniformTypeIdentifiers

nonisolated struct ImageRoomTimelineItemContent: Hashable {
    let filename: String
    var caption: String?
    var formattedCaption: AttributedString?
    /// The original textual representation of the formatted caption directly from the event (usually HTML code)
    var formattedCaptionHTMLString: String?
    
    let imageInfo: ImageInfoProxy
    let thumbnailInfo: ImageInfoProxy?
    let mediumPreviewInfo: ImageInfoProxy?
    
    var blurhash: String?
    var contentType: UTType?

    init(filename: String,
         caption: String? = nil,
         formattedCaption: AttributedString? = nil,
         formattedCaptionHTMLString: String? = nil,
         imageInfo: ImageInfoProxy,
         thumbnailInfo: ImageInfoProxy? = nil,
         mediumPreviewInfo: ImageInfoProxy? = nil,
         blurhash: String? = nil,
         contentType: UTType? = nil) {
        self.filename = filename
        self.caption = caption
        self.formattedCaption = formattedCaption
        self.formattedCaptionHTMLString = formattedCaptionHTMLString
        self.imageInfo = imageInfo
        self.thumbnailInfo = thumbnailInfo
        self.mediumPreviewInfo = mediumPreviewInfo
        self.blurhash = blurhash
        self.contentType = contentType
    }
}
