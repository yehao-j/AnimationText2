import CoreText
import Metal
import UIKit

struct AnimationConfiguration {
    /// 单个动画单元的动画时长，单位为秒。
    static let duration: Float = 0.22
    /// 相邻动画单元开始动画的时间间隔，单位为秒。
    static let stagger: Float = 0.03
    static let startDelay: TimeInterval = 0.08
    /// 动画单元在开始时的垂直偏移距离，单位为点。
    static let travelDistance: Float = 16
    static let font = UIFont.systemFont(ofSize: 17, weight: .regular)
    static let letterSpacing: CGFloat = 0
    static let lineSpacing: CGFloat = 0
}

struct AnimationInstance {
    let origin: SIMD2<Float>
    let size: SIMD2<Float>
    let uvOrigin: SIMD2<Float>
    let uvSize: SIMD2<Float>
    let blurUVOrigin: SIMD2<Float>
    let blurUVSize: SIMD2<Float>
    let delay: Float
    private let padding: Float = 0
}

struct StandaloneViewLayout {
    let view: UIView
    let frame: CGRect
    let delay: Float
}

struct AnimationAtlas {
    let texture: MTLTexture
    let instances: [AnimationInstance]
    let standaloneViewLayouts: [StandaloneViewLayout]
    let blurAtlasSize: CGSize
    let animationDuration: Float
    let pixelsPerPoint: Float
    let maxBlur: Float
}

enum AnimationAtlasError: LocalizedError {
    case cannotCreateContext
    case cannotCreateTexture
    case cannotRasterizeView
    case invalidViewFrame
    case missingViewAnchor
    case atlasOverflow

    var errorDescription: String? {
        switch self {
        case .cannotCreateContext: return "无法创建动画图集上下文"
        case .cannotCreateTexture: return "无法创建 Metal 动画纹理"
        case .cannotRasterizeView: return "无法生成静态 View 快照"
        case .invalidViewFrame: return "静态 View 的 frame 必须大于 0"
        case .missingViewAnchor: return "静态 View 的垂直居中需要相邻文本"
        case .atlasOverflow: return "动画图集超出纹理尺寸限制"
        }
    }
}

enum AnimationAtlasBuilder {
    private struct TextItem {
        let itemIndex: Int
        let range: NSRange
    }

    private struct TextLayout {
        var glyphsByItem: [Int: [PositionedGlyph]] = [:]
        var standaloneFrames: [Int: CGRect] = [:]
    }

    private struct TextSegment {
        let glyphsByItem: [Int: [PositionedGlyph]]
        let height: CGFloat
    }

    private struct PositionedGlyph {
        let glyph: CGGlyph
        let font: CTFont
        let baseline: CGPoint
        let localBounds: CGRect
    }

    private struct GlyphKey: Hashable {
        let glyph: CGGlyph
        let fontName: String
        let pointSize: Float
        let baseline: CGPoint
    }

    private enum RasterKey: Hashable {
        case text(String, [GlyphKey])
        case image(ObjectIdentifier, CGSize)
    }

    private struct Raster {
        let size: CGSize
        let draw: (CGContext, CGRect) -> Void
    }

    private struct Description {
        let key: RasterKey
        let bounds: CGRect
        let delay: Float
    }

    static func build(
        items: [MetalAnimationItem],
        font: UIFont,
        textColor: UIColor,
        lineSpacing: CGFloat,
        maxBlur: Float,
        contentRect: CGRect,
        viewportSize: CGSize,
        contentScale: CGFloat,
        device: MTLDevice
    ) throws -> AnimationAtlas {
        let maxBlur = max(0, maxBlur)
        let scale = max(1, contentScale)
        let textLayout = layoutText(
            items: items,
            font: font,
            textColor: textColor,
            lineSpacing: lineSpacing,
            contentRect: contentRect,
            viewportSize: viewportSize
        )
        let glyphsByItem = textLayout.glyphsByItem

        var descriptions: [Description] = []
        var standaloneViewLayouts: [StandaloneViewLayout] = []
        var rasters: [RasterKey: Raster] = [:]

        for (itemIndex, item) in items.enumerated() {
            let description: Description?
            switch item {
            case .text(let text):
                description = makeTextDescription(
                    text: text,
                    textColor: textColor,
                    glyphs: glyphsByItem[itemIndex] ?? [],
                    sequence: descriptions.count + standaloneViewLayouts.count,
                    rasters: &rasters
                )
            case .staticView(let view, let x, let size):
                let frame = try centeredViewFrame(
                    itemIndex: itemIndex,
                    x: x,
                    size: size,
                    lineHeight: font.lineHeight + lineSpacing,
                    items: items,
                    glyphsByItem: glyphsByItem,
                    viewportHeight: viewportSize.height
                )
                description = try makeViewDescription(
                    view: view,
                    fullSize: size,
                    displayFrame: frame,
                    viewportSize: viewportSize,
                    contentScale: scale,
                    sequence: descriptions.count + standaloneViewLayouts.count,
                    rasters: &rasters
                )
            case .standaloneView(let view, _, _):
                description = nil
                standaloneViewLayouts.append(StandaloneViewLayout(
                    view: view,
                    frame: textLayout.standaloneFrames[itemIndex]!,
                    delay: Float(descriptions.count + standaloneViewLayouts.count)
                        * AnimationConfiguration.stagger
                ))
            }
            if let description {
                descriptions.append(description)
            }
        }

        return try makeAtlas(
            descriptions: descriptions,
            standaloneViewLayouts: standaloneViewLayouts,
            rasters: rasters,
            maxBlur: maxBlur,
            contentScale: scale,
            device: device
        )
    }

    private static func layoutText(
        items: [MetalAnimationItem],
        font: UIFont,
        textColor: UIColor,
        lineSpacing: CGFloat,
        contentRect: CGRect,
        viewportSize: CGSize
    ) -> TextLayout {
        var layout = TextLayout()
        var cursorY = contentRect.maxY
        var index = 0

        while index < items.count {
            if case .standaloneView(_, let size, let alignment) = items[index] {
                let width = min(max(0, size.width), viewportSize.width)
                let height = max(0, size.height)
                let x: CGFloat
                switch alignment {
                case .left:
                    x = 0
                case .center:
                    x = (viewportSize.width - width) / 2
                case .right:
                    x = viewportSize.width - width
                }
                layout.standaloneFrames[index] = CGRect(
                    x: x,
                    y: viewportSize.height - cursorY,
                    width: width,
                    height: height
                )
                cursorY -= height
                index += 1
                continue
            }

            let segmentStart = index
            while index < items.count {
                if case .standaloneView = items[index] { break }
                index += 1
            }
            let segment = layoutTextSegment(
                items: items,
                range: segmentStart..<index,
                font: font,
                textColor: textColor,
                lineSpacing: lineSpacing,
                contentRect: contentRect,
                top: cursorY
            )
            for (itemIndex, glyphs) in segment.glyphsByItem {
                layout.glyphsByItem[itemIndex, default: []].append(contentsOf: glyphs)
            }
            cursorY -= segment.height
        }
        return layout
    }

    private static func layoutTextSegment(
        items: [MetalAnimationItem],
        range: Range<Int>,
        font: UIFont,
        textColor: UIColor,
        lineSpacing: CGFloat,
        contentRect: CGRect,
        top: CGFloat
    ) -> TextSegment {
        var fullText = ""
        var textItems: [TextItem] = []
        var location = 0

        for itemIndex in range {
            guard case .text(let text) = items[itemIndex] else { continue }
            let length = text.utf16.count
            textItems.append(TextItem(
                itemIndex: itemIndex,
                range: NSRange(location: location, length: length)
            ))
            fullText.append(text)
            location += length
        }

        guard !fullText.isEmpty else {
            return TextSegment(glyphsByItem: [:], height: 0)
        }

        let lineHeight = font.lineHeight + lineSpacing
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = lineHeight
        paragraphStyle.maximumLineHeight = lineHeight
        paragraphStyle.lineBreakMode = .byCharWrapping

        let attributedText = NSAttributedString(
            string: fullText,
            attributes: [
                .font: font,
                .kern: AnimationConfiguration.letterSpacing,
                .foregroundColor: textColor,
                .paragraphStyle: paragraphStyle
            ]
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributedText)
        let suggestedSize = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: attributedText.length),
            nil,
            CGSize(width: contentRect.width, height: CGFloat.greatestFiniteMagnitude),
            nil
        )
        let textHeight = ceil(suggestedSize.height)
        let visibleHeight = min(textHeight, max(0, top - contentRect.minY))
        var glyphsByItem: [Int: [PositionedGlyph]] = [:]

        if visibleHeight > 0 {
            let frameRect = CGRect(
                x: contentRect.minX,
                y: top - visibleHeight,
                width: contentRect.width,
                height: visibleHeight
            )
            let path = CGPath(rect: frameRect, transform: nil)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: 0, length: attributedText.length),
                path,
                nil
            )
            let lines = CTFrameGetLines(frame) as! [CTLine]
            var lineOrigins = [CGPoint](repeating: .zero, count: lines.count)
            CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &lineOrigins)

            for (lineIndex, line) in lines.enumerated() {
                let runs = CTLineGetGlyphRuns(line) as! [CTRun]
                for run in runs {
                    let attributes = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any]
                    let runUIFont = attributes?[.font] as? UIFont ?? font
                    let runFont = runUIFont as CTFont
                    let glyphCount = CTRunGetGlyphCount(run)
                    var glyphs = [CGGlyph](repeating: 0, count: glyphCount)
                    var positions = [CGPoint](repeating: .zero, count: glyphCount)
                    var stringIndices = [CFIndex](repeating: 0, count: glyphCount)
                    CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                    CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                    CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &stringIndices)

                    for index in 0..<glyphCount {
                        guard let textItem = textItem(at: stringIndices[index], in: textItems) else {
                            continue
                        }
                        var localBounds = CGRect.zero
                        var glyph = glyphs[index]
                        CTFontGetBoundingRectsForGlyphs(runFont, .default, &glyph, &localBounds, 1)
                        guard localBounds.width > 0, localBounds.height > 0 else { continue }

                        let baseline = CGPoint(
                            x: frameRect.minX + lineOrigins[lineIndex].x + positions[index].x,
                            y: frameRect.minY + lineOrigins[lineIndex].y + positions[index].y
                        )
                        glyphsByItem[textItem.itemIndex, default: []].append(PositionedGlyph(
                            glyph: glyph,
                            font: runFont,
                            baseline: baseline,
                            localBounds: localBounds
                        ))
                    }
                }
            }
        }
        return TextSegment(glyphsByItem: glyphsByItem, height: textHeight)
    }

    private static func textItem(at stringIndex: Int, in items: [TextItem]) -> TextItem? {
        var lowerBound = 0
        var upperBound = items.count

        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            let range = items[middle].range
            if stringIndex < range.location {
                upperBound = middle
            } else if stringIndex >= NSMaxRange(range) {
                lowerBound = middle + 1
            } else {
                return items[middle]
            }
        }
        return nil
    }

    private static func makeTextDescription(
        text: String,
        textColor: UIColor,
        glyphs: [PositionedGlyph],
        sequence: Int,
        rasters: inout [RasterKey: Raster]
    ) -> Description? {
        guard let firstGlyph = glyphs.first else { return nil }

        var bounds = firstGlyph.localBounds.offsetBy(
            dx: firstGlyph.baseline.x,
            dy: firstGlyph.baseline.y
        )
        for glyph in glyphs.dropFirst() {
            bounds = bounds.union(glyph.localBounds.offsetBy(
                dx: glyph.baseline.x,
                dy: glyph.baseline.y
            ))
        }

        let drawings = glyphs.map {
            PositionedGlyph(
                glyph: $0.glyph,
                font: $0.font,
                baseline: CGPoint(
                    x: $0.baseline.x - bounds.minX,
                    y: $0.baseline.y - bounds.minY
                ),
                localBounds: $0.localBounds
            )
        }
        let glyphKeys = drawings.map {
            GlyphKey(
                glyph: $0.glyph,
                fontName: CTFontCopyPostScriptName($0.font) as String,
                pointSize: Float(CTFontGetSize($0.font)),
                baseline: $0.baseline
            )
        }
        let key = RasterKey.text(text, glyphKeys)
        if rasters[key] == nil {
            rasters[key] = Raster(size: bounds.size) { context, rect in
                context.setFillColor(textColor.cgColor)
                for drawing in drawings {
                    var glyph = drawing.glyph
                    var position = CGPoint(
                        x: rect.minX + drawing.baseline.x,
                        y: rect.minY + drawing.baseline.y
                    )
                    CTFontDrawGlyphs(drawing.font, &glyph, &position, 1, context)
                }
            }
        }
        return Description(
            key: key,
            bounds: bounds,
            delay: Float(sequence) * AnimationConfiguration.stagger
        )
    }

    private static func centeredViewFrame(
        itemIndex: Int,
        x: CGFloat,
        size: CGSize,
        lineHeight: CGFloat,
        items: [MetalAnimationItem],
        glyphsByItem: [Int: [PositionedGlyph]],
        viewportHeight: CGFloat
    ) throws -> CGRect {
        guard let lineCenter = anchorLineCenter(
            itemIndex: itemIndex,
            items: items,
            glyphsByItem: glyphsByItem
        ) else {
            throw AnimationAtlasError.missingViewAnchor
        }
        let displayHeight = min(size.height, lineHeight)
        // 实例空间 y 轴向上（原点在视口底部），view frame 的 y 轴向下。
        return CGRect(
            x: x,
            y: viewportHeight - lineCenter - displayHeight / 2,
            width: size.width,
            height: displayHeight
        )
    }

    private static func anchorLineCenter(
        itemIndex: Int,
        items: [MetalAnimationItem],
        glyphsByItem: [Int: [PositionedGlyph]]
    ) -> CGFloat? {
        var anchorBaseline: CGFloat?
        for index in (0..<itemIndex).reversed() {
            if case .text = items[index], let glyphs = glyphsByItem[index], let last = glyphs.last {
                anchorBaseline = last.baseline.y
                break
            }
        }
        if anchorBaseline == nil {
            for index in (itemIndex + 1)..<items.count {
                if case .text = items[index], let glyphs = glyphsByItem[index], let first = glyphs.first {
                    anchorBaseline = first.baseline.y
                    break
                }
            }
        }
        guard let anchorBaseline else { return nil }

        var bounds = CGRect.null
        for glyphs in glyphsByItem.values {
            for glyph in glyphs where abs(glyph.baseline.y - anchorBaseline) < 0.5 {
                bounds = bounds.union(glyph.localBounds.offsetBy(
                    dx: glyph.baseline.x,
                    dy: glyph.baseline.y
                ))
            }
        }
        return bounds.isNull ? nil : bounds.midY
    }

    private static func makeViewDescription(
        view: UIView,
        fullSize: CGSize,
        displayFrame: CGRect,
        viewportSize: CGSize,
        contentScale: CGFloat,
        sequence: Int,
        rasters: inout [RasterKey: Raster]
    ) throws -> Description {
        guard displayFrame.width > 0, displayFrame.height > 0 else {
            throw AnimationAtlasError.invalidViewFrame
        }

        // 按完整尺寸布局，只快照顶部 displayFrame.height 的部分（超出行高时裁掉底部）。
        view.frame = CGRect(origin: displayFrame.origin, size: fullSize)
        view.setNeedsLayout()
        view.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = contentScale
        format.opaque = false
        let snapshot = UIGraphicsImageRenderer(size: displayFrame.size, format: format).image {
            view.layer.render(in: $0.cgContext)
        }
        guard let image = snapshot.cgImage else {
            throw AnimationAtlasError.cannotRasterizeView
        }

        let key = RasterKey.image(ObjectIdentifier(view), fullSize)
        if rasters[key] == nil {
            rasters[key] = Raster(size: displayFrame.size) { context, rect in
                context.draw(image, in: rect)
            }
        }
        let bounds = CGRect(
            x: displayFrame.minX,
            y: viewportSize.height - displayFrame.maxY,
            width: displayFrame.width,
            height: displayFrame.height
        )
        return Description(
            key: key,
            bounds: bounds,
            delay: Float(sequence) * AnimationConfiguration.stagger
        )
    }

    private static func makeAtlas(
        descriptions: [Description],
        standaloneViewLayouts: [StandaloneViewLayout],
        rasters: [RasterKey: Raster],
        maxBlur: Float,
        contentScale: CGFloat,
        device: MTLDevice
    ) throws -> AnimationAtlas {
        let paddingInPixels = Int(ceil(CGFloat(maxBlur) * contentScale)) + 2
        let atlasWidth = 2048
        var x = 0
        var y = 0
        var rowHeight = 0
        var pixelRectsByKey: [RasterKey: CGRect] = [:]

        for (key, raster) in rasters {
            let width = Int(ceil(raster.size.width * contentScale)) + paddingInPixels * 2
            let height = Int(ceil(raster.size.height * contentScale)) + paddingInPixels * 2
            if width > atlasWidth { throw AnimationAtlasError.atlasOverflow }
            if x + width > atlasWidth {
                x = 0
                y += rowHeight
                rowHeight = 0
            }
            pixelRectsByKey[key] = CGRect(x: x, y: y, width: width, height: height)
            x += width
            rowHeight = max(rowHeight, height)
        }

        let atlasHeight = max(1, y + rowHeight)
        guard atlasHeight <= 16_384 else { throw AnimationAtlasError.atlasOverflow }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: atlasWidth,
            height: atlasHeight,
            bitsPerComponent: 8,
            bytesPerRow: atlasWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw AnimationAtlasError.cannotCreateContext
        }

        context.setAllowsAntialiasing(true)
        context.setShouldSmoothFonts(true)
        context.scaleBy(x: contentScale, y: contentScale)

        for (key, pixelRect) in pixelRectsByKey {
            guard let raster = rasters[key] else { continue }
            let padding = CGFloat(paddingInPixels) / contentScale
            let contentRect = CGRect(
                x: pixelRect.minX / contentScale + padding,
                y: pixelRect.minY / contentScale + padding,
                width: raster.size.width,
                height: raster.size.height
            )
            raster.draw(context, contentRect)
        }

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: atlasWidth,
            height: atlasHeight,
            mipmapped: false
        )
        textureDescriptor.usage = .shaderRead
        textureDescriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: textureDescriptor), let data = context.data else {
            throw AnimationAtlasError.cannotCreateTexture
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, atlasWidth, atlasHeight),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: atlasWidth * 4
        )

        let blurAtlasWidth = atlasWidth
        var blurX = 0
        var blurY = 0
        var blurRowHeight = 0
        let blurPixelRects = descriptions.map { description -> CGRect in
            let pixelRect = pixelRectsByKey[description.key]!
            let width = Int(pixelRect.width)
            let height = Int(pixelRect.height)
            if blurX + width > blurAtlasWidth {
                blurX = 0
                blurY += blurRowHeight
                blurRowHeight = 0
            }
            let blurPixelRect = CGRect(x: blurX, y: blurY, width: width, height: height)
            blurX += width
            blurRowHeight = max(blurRowHeight, height)
            return blurPixelRect
        }
        let blurAtlasHeight = max(1, blurY + blurRowHeight)
        guard blurAtlasHeight <= 16_384 else { throw AnimationAtlasError.atlasOverflow }

        let paddingInPoints = CGFloat(paddingInPixels) / contentScale
        let instances = descriptions.enumerated().map { index, description in
            let pixelRect = pixelRectsByKey[description.key]!
            let blurPixelRect = blurPixelRects[index]
            let absoluteOrigin = CGPoint(
                x: description.bounds.minX - paddingInPoints,
                y: description.bounds.minY - paddingInPoints
            )
            let size = CGSize(
                width: pixelRect.width / contentScale,
                height: pixelRect.height / contentScale
            )
            return AnimationInstance(
                origin: SIMD2(Float(absoluteOrigin.x), Float(absoluteOrigin.y)),
                size: SIMD2(Float(size.width), Float(size.height)),
                uvOrigin: SIMD2(
                    Float(pixelRect.minX / CGFloat(atlasWidth)),
                    Float((CGFloat(atlasHeight) - pixelRect.maxY) / CGFloat(atlasHeight))
                ),
                uvSize: SIMD2(
                    Float(pixelRect.width / CGFloat(atlasWidth)),
                    Float(pixelRect.height / CGFloat(atlasHeight))
                ),
                blurUVOrigin: SIMD2(
                    Float(blurPixelRect.minX / CGFloat(blurAtlasWidth)),
                    Float((CGFloat(blurAtlasHeight) - blurPixelRect.maxY) / CGFloat(blurAtlasHeight))
                ),
                blurUVSize: SIMD2(
                    Float(blurPixelRect.width / CGFloat(blurAtlasWidth)),
                    Float(blurPixelRect.height / CGFloat(blurAtlasHeight))
                ),
                delay: description.delay
            )
        }

        let itemCount = descriptions.count + standaloneViewLayouts.count
        let animationDuration = itemCount == 0 ? 0 : Float(itemCount - 1)
            * AnimationConfiguration.stagger + AnimationConfiguration.duration
        return AnimationAtlas(
            texture: texture,
            instances: instances,
            standaloneViewLayouts: standaloneViewLayouts,
            blurAtlasSize: CGSize(width: blurAtlasWidth, height: blurAtlasHeight),
            animationDuration: animationDuration,
            pixelsPerPoint: Float(contentScale),
            maxBlur: maxBlur
        )
    }
}
