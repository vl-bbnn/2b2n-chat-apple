//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

struct MediumPreviewInfoParserTests {
    @Test
    func parsesPlainSource() {
        let result = parseMediumPreviewInfo(eventJSON: """
        {
          "content": {
            "pro.bbnn.chat.medium_preview": {
              "source": { "url": "mxc://example.org/medium" },
              "info": { "w": 1600, "h": 1200, "mimetype": "image/jpeg", "size": 250000 }
            }
          }
        }
        """)

        #expect(result?.source.url.absoluteString == "mxc://example.org/medium")
        #expect(result?.size?.width == 1600)
        #expect(result?.size?.height == 1200)
        #expect(result?.mimeType == "image/jpeg")
        #expect(result?.fileSize == 250_000)
    }

    @Test
    func parsesEncryptedSourceFromEditedContent() {
        let result = parseMediumPreviewInfo(eventJSON: """
        {
          "content": {
            "m.new_content": {
              "pro.bbnn.chat.medium_preview": {
                "source": {
                  "file": {
                    "url": "mxc://example.org/encrypted-medium",
                    "key": {
                      "alg": "A256CTR",
                      "ext": true,
                      "k": "b50ACIv6LMn9AfMCFD1POJI_UAFWIclxAN1kWrEO2X8",
                      "key_ops": ["encrypt", "decrypt"],
                      "kty": "oct"
                    },
                    "iv": "AK1wyzigZtQAAAABAAAAKK",
                    "hashes": { "sha256": "/NogKqW5bz/m8xHgFiH5haFGjCNVmUIPLzfvOhHdrxY" },
                    "v": "v2"
                  }
                }
              }
            }
          }
        }
        """)

        #expect(result?.source.url.absoluteString == "mxc://example.org/encrypted-medium")
    }

    @Test
    func returnsNilWithoutExtension() {
        #expect(parseMediumPreviewInfo(eventJSON: #"{"content":{"msgtype":"m.image"}}"#) == nil)
    }
}
