#include <metal_stdlib>
using namespace metal;

struct GlyphInstance {
    float2 origin;
    float2 size;
    float2 uvOrigin;
    float2 uvSize;
    float2 blurUVOrigin;
    float2 blurUVSize;
    float delay;
    float padding;
};

struct AnimationUniforms {
    float time;
    float duration;
    float travelDistance;
    float maxBlurInPixels;
    float2 viewportSize;
    float2 atlasTexelSize;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
    float2 uvMin;
    float2 uvMax;
    float opacity;
    float blurRadiusInPixels;
};

VertexOut animatedGlyphVertex(
    const GlyphInstance glyph,
    const float2 corner,
    constant AnimationUniforms &uniforms
) {
    const float rawProgress = (uniforms.time - glyph.delay) / uniforms.duration;
    const float progress = saturate(rawProgress);

    VertexOut out;
    out.uv = float2(0);
    out.uvMin = float2(0);
    out.uvMax = float2(0);
    // Become visible quickly, then keep enough time for the blur-to-sharp transition.
    out.opacity = smoothstep(0.0, 0.16, progress);
    out.blurRadiusInPixels = uniforms.maxBlurInPixels * (1.0 - smoothstep(0.12, 1.0, progress));

    // All six vertices coincide before this glyph starts, so it produces no fragments.
    out.position = float4(2, 2, 0, 1);
    if (rawProgress <= 0.0) {
        return out;
    }

    const float easedProgress = 1.0 - pow(1.0 - progress, 3.0);
    float2 position = glyph.origin + corner * glyph.size;
    position.y -= (1.0 - easedProgress) * uniforms.travelDistance;
    out.position = float4(position / uniforms.viewportSize * 2.0 - 1.0, 0, 1);
    return out;
}

vertex VertexOut horizontalTextVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    const device GlyphInstance *instances [[buffer(0)]],
    constant AnimationUniforms &uniforms [[buffer(1)]]
) {
    const float2 corners[6] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(0, 1), float2(1, 0), float2(1, 1)
    };
    const GlyphInstance glyph = instances[instanceID];
    const float2 corner = corners[vertexID];
    VertexOut out = animatedGlyphVertex(glyph, corner, uniforms);
    out.uv = glyph.uvOrigin + float2(corner.x, 1.0 - corner.y) * glyph.uvSize;
    out.uvMin = glyph.uvOrigin;
    out.uvMax = glyph.uvOrigin + glyph.uvSize;

    if (uniforms.time > glyph.delay) {
        const float2 blurUV = glyph.blurUVOrigin
            + float2(corner.x, 1.0 - corner.y) * glyph.blurUVSize;
        out.position = float4(blurUV.x * 2.0 - 1.0, 1.0 - blurUV.y * 2.0, 0, 1);
    }
    return out;
}

vertex VertexOut verticalTextVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    const device GlyphInstance *instances [[buffer(0)]],
    constant AnimationUniforms &uniforms [[buffer(1)]]
) {
    const float2 corners[6] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(0, 1), float2(1, 0), float2(1, 1)
    };
    const GlyphInstance glyph = instances[instanceID];
    const float2 corner = corners[vertexID];
    VertexOut out = animatedGlyphVertex(glyph, corner, uniforms);
    out.uv = glyph.blurUVOrigin + float2(corner.x, 1.0 - corner.y) * glyph.blurUVSize;
    out.uvMin = glyph.blurUVOrigin;
    out.uvMax = glyph.blurUVOrigin + glyph.blurUVSize;
    return out;
}

float2 clampToGlyph(
    float2 uv,
    float2 uvMin,
    float2 uvMax,
    float2 texelSize
) {
    const float2 halfTexel = texelSize * 0.5;
    return clamp(uv, uvMin + halfTexel, uvMax - halfTexel);
}

// Twenty-five linearly filtered taps represent a continuous 49-tap Gaussian.
// Dense one-pixel-scale spacing avoids both sample grids and directional stripes.
float4 gaussianSample(
    texture2d<float> source,
    sampler sourceSampler,
    float2 uv,
    float2 sampleStep,
    float2 uvMin,
    float2 uvMax
) {
    const float offsets[12] = {
        1.4941408932, 3.4863315314, 5.4785288375, 7.4707366066,
        9.4629586132, 11.4551986043, 13.4474602919, 15.4397473464,
        17.4320633892, 19.4244119867, 21.4167966432, 23.4092207951
    };
    const float weights[12] = {
        0.0980269620, 0.0906877868, 0.0788341890, 0.0643936182,
        0.0494234786, 0.0356439502, 0.0241546147, 0.0153806911,
        0.0092026449, 0.0051738061, 0.0027331774, 0.0013567042
    };
    const float2 texelSize = 1.0 / float2(source.get_width(), source.get_height());

    float4 result = source.sample(
        sourceSampler,
        clampToGlyph(uv, uvMin, uvMax, texelSize)
    ) * 0.0499767536;
    for (int index = 0; index < 12; index++) {
        const float2 offset = sampleStep * offsets[index];
        result += source.sample(
            sourceSampler,
            clampToGlyph(uv + offset, uvMin, uvMax, texelSize)
        ) * weights[index];
        result += source.sample(
            sourceSampler,
            clampToGlyph(uv - offset, uvMin, uvMax, texelSize)
        ) * weights[index];
    }
    return result;
}

fragment float4 textHorizontalFragment(
    VertexOut in [[stage_in]],
    texture2d<float> glyphAtlas [[texture(0)]],
    constant AnimationUniforms &uniforms [[buffer(1)]]
) {
    constexpr sampler glyphSampler(filter::linear, address::clamp_to_edge);

    float coverage;
    if (in.blurRadiusInPixels < 0.02) {
        const float2 uv = clampToGlyph(in.uv, in.uvMin, in.uvMax, uniforms.atlasTexelSize);
        coverage = glyphAtlas.sample(glyphSampler, uv).a;
    } else {
        const float2 sampleStep = float2(
            in.blurRadiusInPixels / 24.0 * uniforms.atlasTexelSize.x,
            0.0
        );
        coverage = gaussianSample(
            glyphAtlas,
            glyphSampler,
            in.uv,
            sampleStep,
            in.uvMin,
            in.uvMax
        ).a;
    }

    const float visibleCoverage = coverage * in.opacity;
    return float4(visibleCoverage, 0.0, 0.0, visibleCoverage);
}

fragment float4 textVerticalFragment(
    VertexOut in [[stage_in]],
    texture2d<float> horizontalAtlas [[texture(0)]]
) {
    constexpr sampler blurSampler(filter::linear, address::clamp_to_edge);
    const float2 texelSize = 1.0 / float2(
        horizontalAtlas.get_width(),
        horizontalAtlas.get_height()
    );

    float coverage;
    if (in.blurRadiusInPixels < 0.02) {
        const float2 uv = clampToGlyph(in.uv, in.uvMin, in.uvMax, texelSize);
        coverage = horizontalAtlas.sample(blurSampler, uv).r;
    } else {
        const float2 sampleStep = float2(
            0.0,
            in.blurRadiusInPixels / 24.0 * texelSize.y
        );
        coverage = gaussianSample(
            horizontalAtlas,
            blurSampler,
            in.uv,
            sampleStep,
            in.uvMin,
            in.uvMax
        ).r;
    }
    return float4(0.09, 0.10, 0.11, coverage);
}
