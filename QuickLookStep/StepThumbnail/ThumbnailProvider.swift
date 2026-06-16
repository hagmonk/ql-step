//
//  ThumbnailProvider.swift
//  StepThumbnail
//
//  Created by John Boiles on 7/14/25.
//

import QuickLookThumbnailing
import Cocoa
import StepPreviewKit

class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        // We perform heavy work off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Build the scene using the shared helper.
                let scene = try StepSceneLoader.scene(fromFileAt: request.fileURL)

                let pointSize = request.maximumSize
                let scale = CGFloat(request.scale)
                let pixelSize = CGSize(width: pointSize.width * scale, height: pointSize.height * scale)

                let t0 = CFAbsoluteTimeGetCurrent()
                let cgImage = try StepThumbnailRenderer.cgImage(for: scene, pixelSize: pixelSize)
                let snapshotMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
                NSLog("renderer.snapshot finished in %.2f ms", snapshotMs)

                let reply = QLThumbnailReply(contextSize: pointSize, drawing: { ctx -> Bool in
                    ctx.draw(cgImage, in: CGRect(origin: .zero, size: pixelSize))
                    return true
                })

                handler(reply, nil)
            } catch {
                handler(nil, error)
            }
        }
    }
}
