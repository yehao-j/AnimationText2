import CoreText
import Metal
import UIKit

struct AnimationConfiguration {
    /// 单个动画单元的动画时长，单位为秒。
    static let duration: Float = 0.42
    /// 相邻动画单元开始动画的时间间隔，单位为秒。
    static let stagger: Float = 0.08
    
//    static let duration: Float = 1
//    static let stagger: Float = 0.2
    
    /// 动画开始前的延迟时间，单位为秒。
    static let startDelay: TimeInterval = 0
    /// 动画单元在开始时的垂直偏移距离，单位为点。
    static let travelDistance: Float = 10
    /// 文本字体。
    static let font = UIFont.systemFont(ofSize: 17, weight: .regular)
    /// 字符间距，单位为点。
    static let letterSpacing: CGFloat = 0
    /// 相邻文本行之间的额外间距，单位为点。
    static let lineSpacing: CGFloat = 0
    /// 是否为每个文本行绘制随机背景色；颜色生成后保持不变，透明度为 0.5。
    static let showsRandomLineColors = true
    
    /// 返回当前字体的行高，单位为点。
    static func lineHeight() -> CGFloat {
        font.lineHeight
    }
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
    let completion: (() -> Void)?
}

struct AnimationItemHeight {
    let delay: Float
    let height: CGFloat
}

struct AnimationAtlas {
    let texture: MTLTexture
    let instances: [AnimationInstance]
    let standaloneViewLayouts: [StandaloneViewLayout]
    let itemHeights: [AnimationItemHeight]
    /// 按动画实例生成顺序排列的 delay；流式追加重建时旧实例沿用这些时刻，保证不重播。
    let sequenceDelays: [Float]
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
    case atlasOverflow

    var errorDescription: String? {
        switch self {
        case .cannotCreateContext: return "无法创建动画图集上下文"
        case .cannotCreateTexture: return "无法创建 Metal 动画纹理"
        case .cannotRasterizeView: return "无法生成静态 View 快照"
        case .invalidViewFrame: return "静态 View 的 frame 必须大于 0"
        case .atlasOverflow: return "动画图集超出纹理尺寸限制"
        }
    }
}

enum AnimationAtlasBuilder {
    private static var lineColors: [Int: UIColor] = [:]

    private struct TextItem {
        let itemIndex: Int
        let range: NSRange
    }

    private struct TextLayout {
        var glyphsByItem: [Int: [PositionedGlyph]] = [:]
        var staticFrames: [Int: CGRect] = [:]
        var standaloneFrames: [Int: CGRect] = [:]
        var itemHeights: [Int: CGFloat] = [:]
        var lineFrames: [CGRect] = []
    }

    private struct TextSegment {
        let glyphsByItem: [Int: [PositionedGlyph]]
        let staticFrames: [Int: CGRect]
        let itemHeights: [Int: CGFloat]
        let lineFrames: [CGRect]
        let height: CGFloat
    }

    private struct StaticItem {
        let itemIndex: Int
        let size: CGSize
    }

    private final class InlineViewMetrics {
        let width: CGFloat

        init(width: CGFloat) {
            self.width = width
        }
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
        case lineBackground(Int)
    }

    private struct Raster {
        let size: CGSize
        let draw: (CGContext, CGRect) -> Void
    }

    private struct Description {
        let key: RasterKey
        let bounds: CGRect
        let delay: Float
        let participatesInTimeline: Bool
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
        existingDelays: [Float],
        elapsed: Float,
        device: MTLDevice
    ) throws -> AnimationAtlas {
        let maxBlur = max(0, maxBlur)
        let scale = max(1, contentScale)
        // sequence 是动画实例的生成序号（空白文本不产生实例、不占序号）。旧实例沿用
        // existingDelays，新实例从 max(队尾 delay + stagger, 当前已播时间) 起依次错开；
        // 整段重置即 existingDelays = []、elapsed = 0 的特例。
        let firstNewDelay = max(
            (existingDelays.last ?? -AnimationConfiguration.stagger) + AnimationConfiguration.stagger,
            elapsed
        )
        func delay(for sequence: Int) -> Float {
            if sequence < existingDelays.count { return existingDelays[sequence] }
            return firstNewDelay + Float(sequence - existingDelays.count) * AnimationConfiguration.stagger
        }
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
        var itemHeights: [AnimationItemHeight] = []
        var rasters: [RasterKey: Raster] = [:]

        for (itemIndex, item) in items.enumerated() {
            let description: Description?
            switch item {
            case .text(let text):
                description = makeTextDescription(
                    text: text,
                    textColor: textColor,
                    glyphs: glyphsByItem[itemIndex] ?? [],
                    delay: delay(for: descriptions.count + standaloneViewLayouts.count),
                    rasters: &rasters
                )
            case .staticView(let view):
                if let frame = textLayout.staticFrames[itemIndex] {
                    description = try makeViewDescription(
                        view: view,
                        displayFrame: frame,
                        viewportSize: viewportSize,
                        contentScale: scale,
                        delay: delay(for: descriptions.count + standaloneViewLayouts.count),
                        rasters: &rasters
                    )
                } else {
                    description = nil
                }
            case .standaloneView(let view, _, let completion):
                description = nil
                let standaloneLayout = StandaloneViewLayout(
                    view: view,
                    frame: textLayout.standaloneFrames[itemIndex]!,
                    delay: delay(for: descriptions.count + standaloneViewLayouts.count),
                    completion: completion
                )
                standaloneViewLayouts.append(standaloneLayout)
                itemHeights.append(AnimationItemHeight(
                    delay: standaloneLayout.delay,
                    height: standaloneLayout.frame.maxY
                ))
            }
            if let description {
                descriptions.append(description)
                itemHeights.append(AnimationItemHeight(
                    delay: description.delay,
                    height: textLayout.itemHeights[itemIndex]!
                ))
            }
        }

        if AnimationConfiguration.showsRandomLineColors {
            let backgrounds = textLayout.lineFrames.enumerated().map { lineIndex, frame in
                let key = RasterKey.lineBackground(lineIndex)
                let color: UIColor
                if let existingColor = lineColors[lineIndex] {
                    color = existingColor
                } else {
                    color = UIColor(
                        hue: .random(in: 0...1),
                        saturation: 0.7,
                        brightness: 1,
                        alpha: 0.5
                    )
                    lineColors[lineIndex] = color
                }
                rasters[key] = Raster(size: frame.size) { context, rect in
                    context.setFillColor(color.cgColor)
                    context.fill(rect)
                }
                return Description(
                    key: key,
                    bounds: CGRect(
                        x: frame.minX,
                        y: viewportSize.height - frame.maxY,
                        width: frame.width,
                        height: frame.height
                    ),
                    delay: -AnimationConfiguration.duration,
                    participatesInTimeline: false
                )
            }
            descriptions.insert(contentsOf: backgrounds, at: 0)
        }

        return try makeAtlas(
            descriptions: descriptions,
            standaloneViewLayouts: standaloneViewLayouts,
            itemHeights: itemHeights,
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
            if case .standaloneView(let view, let alignment, _) = items[index] {
                let size = view.bounds.size
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
                let frame = CGRect(
                    x: x,
                    y: viewportSize.height - cursorY,
                    width: width,
                    height: height
                )
                layout.standaloneFrames[index] = frame
                layout.itemHeights[index] = frame.maxY
                cursorY -= height + lineSpacing
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
                viewportHeight: viewportSize.height,
                top: cursorY
            )
            for (itemIndex, glyphs) in segment.glyphsByItem {
                layout.glyphsByItem[itemIndex, default: []].append(contentsOf: glyphs)
            }
            for (itemIndex, frame) in segment.staticFrames {
                layout.staticFrames[itemIndex] = frame
            }
            for (itemIndex, height) in segment.itemHeights {
                layout.itemHeights[itemIndex] = height
            }
            layout.lineFrames.append(contentsOf: segment.lineFrames)
            cursorY -= segment.height
            if segment.height > 0 {
                cursorY -= lineSpacing
            }
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
        viewportHeight: CGFloat,
        top: CGFloat
    ) -> TextSegment {
        let attributedText = NSMutableAttributedString()
        var textItems: [TextItem] = []
        var staticItems: [Int: StaticItem] = [:]

        for itemIndex in range {
            switch items[itemIndex] {
            case .text(let text):
                textItems.append(TextItem(
                    itemIndex: itemIndex,
                    range: NSRange(location: attributedText.length, length: text.utf16.count)
                ))
                attributedText.append(NSAttributedString(string: text))
            case .staticView(let view):
                let size = view.bounds.size
                staticItems[attributedText.length] = StaticItem(itemIndex: itemIndex, size: size)
                let delegate = makeInlineViewDelegate(width: max(0, size.width))
                attributedText.append(NSAttributedString(
                    string: "\u{FFFC}",
                    attributes: [kCTRunDelegateAttributeName as NSAttributedString.Key: delegate]
                ))
            case .standaloneView:
                continue
            }
        }

        guard attributedText.length > 0 else {
            return TextSegment(
                glyphsByItem: [:],
                staticFrames: [:],
                itemHeights: [:],
                lineFrames: [],
                height: 0
            )
        }

        let lineHeight = font.lineHeight
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = lineHeight
        paragraphStyle.maximumLineHeight = lineHeight
        paragraphStyle.lineSpacing = lineSpacing
        paragraphStyle.lineBreakMode = .byCharWrapping
        attributedText.addAttributes([
            .font: font,
            .kern: AnimationConfiguration.letterSpacing,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle
        ], range: NSRange(location: 0, length: attributedText.length))

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
        var staticFrames: [Int: CGRect] = [:]
        var itemHeights: [Int: CGFloat] = [:]
        var lineFrames: [CGRect] = []

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
                let lineTop = top - CGFloat(lineIndex) * (lineHeight + lineSpacing)
                lineFrames.append(CGRect(
                    x: frameRect.minX,
                    y: viewportHeight - lineTop,
                    width: frameRect.width,
                    height: lineHeight
                ))
                let itemHeight = lineFrames[lineIndex].maxY
                let runs = CTLineGetGlyphRuns(line) as! [CTRun]
                for run in runs {
                    let runRange = CTRunGetStringRange(run)
                    if let staticItem = staticItems[runRange.location] {
                        var position = CGPoint.zero
                        CTRunGetPositions(run, CFRange(location: 0, length: 1), &position)
                        let displayHeight = max(0, staticItem.size.height)
                        staticFrames[staticItem.itemIndex] = CGRect(
                            x: frameRect.minX + lineOrigins[lineIndex].x + position.x,
                            y: viewportHeight - lineTop + (lineHeight - displayHeight) / 2,
                            width: staticItem.size.width,
                            height: displayHeight
                        )
                        itemHeights[staticItem.itemIndex] = itemHeight
                        continue
                    }

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
                        itemHeights[textItem.itemIndex] = max(
                            itemHeights[textItem.itemIndex] ?? 0,
                            itemHeight
                        )
                    }
                }
            }
        }
        return TextSegment(
            glyphsByItem: glyphsByItem,
            staticFrames: staticFrames,
            itemHeights: itemHeights,
            lineFrames: lineFrames,
            height: textHeight
        )
    }

    private static func makeInlineViewDelegate(width: CGFloat) -> CTRunDelegate {
        var callbacks = CTRunDelegateCallbacks(
            version: kCTRunDelegateCurrentVersion,
            dealloc: { pointer in
                Unmanaged<InlineViewMetrics>.fromOpaque(pointer).release()
            },
            getAscent: { _ in 0 },
            getDescent: { _ in 0 },
            getWidth: { pointer in
                Unmanaged<InlineViewMetrics>.fromOpaque(pointer).takeUnretainedValue().width
            }
        )
        let metrics = InlineViewMetrics(width: width)
        return CTRunDelegateCreate(&callbacks, Unmanaged.passRetained(metrics).toOpaque())!
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
        delay: Float,
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
            delay: delay,
            participatesInTimeline: true
        )
    }

    private static func makeViewDescription(
        view: UIView,
        displayFrame: CGRect,
        viewportSize: CGSize,
        contentScale: CGFloat,
        delay: Float,
        rasters: inout [RasterKey: Raster]
    ) throws -> Description {
        guard displayFrame.width > 0, displayFrame.height > 0 else {
            throw AnimationAtlasError.invalidViewFrame
        }

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

        let key = RasterKey.image(ObjectIdentifier(view), displayFrame.size)
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
            delay: delay,
            participatesInTimeline: true
        )
    }

    private static func makeAtlas(
        descriptions: [Description],
        standaloneViewLayouts: [StandaloneViewLayout],
        itemHeights: [AnimationItemHeight],
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

        // delay 随生成序号严格递增，排序后即实例的生成顺序。
        var sequenceDelays = standaloneViewLayouts.map(\.delay)
        for description in descriptions where description.participatesInTimeline {
            sequenceDelays.append(description.delay)
        }
        sequenceDelays.sort()
        let animationDuration = sequenceDelays.last.map { $0 + AnimationConfiguration.duration } ?? 0
        return AnimationAtlas(
            texture: texture,
            instances: instances,
            standaloneViewLayouts: standaloneViewLayouts,
            itemHeights: itemHeights,
            sequenceDelays: sequenceDelays,
            blurAtlasSize: CGSize(width: blurAtlasWidth, height: blurAtlasHeight),
            animationDuration: animationDuration,
            pixelsPerPoint: Float(contentScale),
            maxBlur: maxBlur
        )
    }
}
