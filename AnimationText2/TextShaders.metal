#include <metal_stdlib>
using namespace metal;

struct GlyphInstance {
    float2 origin;
    float2 size;
    float2 uvOrigin;
    float2 uvSize;
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
    float opacity;
    float blurRadiusInPixels;
};

vertex VertexOut textVertex(
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
    const float rawProgress = (uniforms.time - glyph.delay) / uniforms.duration;
    const float progress = saturate(rawProgress);
    const float2 corner = corners[vertexID];

    VertexOut out;
    out.uv = glyph.uvOrigin + float2(corner.x, 1.0 - corner.y) * glyph.uvSize;
    // Become visible quickly, then keep enough time for the blur-to-sharp transition.
    out.opacity = smoothstep(0.0, 0.16, progress);
    out.blurRadiusInPixels = uniforms.maxBlurInPixels * (1.0 - smoothstep(0.12, 1.0, progress));

    // All six vertices coincide before this glyph starts, so it produces no fragments.
    if (rawProgress <= 0.0) {
        out.position = float4(2, 2, 0, 1);
        return out;
    }

    const float easedProgress = 1.0 - pow(1.0 - progress, 3.0);
    float2 position = glyph.origin + corner * glyph.size;
    position.y -= (1.0 - easedProgress) * uniforms.travelDistance;
    out.position = float4(position / uniforms.viewportSize * 2.0 - 1.0, 0, 1);
    return out;
}

// Twenty-five linearly filtered taps represent a continuous 49-tap Gaussian.
// Dense one-pixel-scale spacing avoids both sample grids and directional stripes.
float4 gaussianSample(
    texture2d<float> source,
    sampler sourceSampler,
    float2 uv,
    float2 sampleStep
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

    float4 result = source.sample(sourceSampler, uv) * 0.0499767536;
    for (int index = 0; index < 12; index++) {
        const float2 offset = sampleStep * offsets[index];
        result += source.sample(sourceSampler, uv + offset) * weights[index];
        result += source.sample(sourceSampler, uv - offset) * weights[index];
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
        coverage = glyphAtlas.sample(glyphSampler, in.uv).a;
    } else {
        const float2 sampleStep = float2(
            in.blurRadiusInPixels / 24.0 * uniforms.atlasTexelSize.x,
            0.0
        );
        coverage = gaussianSample(glyphAtlas, glyphSampler, in.uv, sampleStep).a;
    }

    const float visibleCoverage = coverage * in.opacity;
    const float normalizedRadius = uniforms.maxBlurInPixels > 0.0
        ? in.blurRadiusInPixels / uniforms.maxBlurInPixels
        : 0.0;
    // Min blending keeps sharp glyphs from inheriting a neighboring glyph's blur.
    return float4(visibleCoverage, 0.0, 0.0, normalizedRadius);
}

struct FullscreenVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex FullscreenVertexOut fullscreenVertex(uint vertexID [[vertex_id]]) {
    const float2 corners[6] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(0, 1), float2(1, 0), float2(1, 1)
    };
    const float2 corner = corners[vertexID];
    FullscreenVertexOut out;
    out.position = float4(corner * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(corner.x, 1.0 - corner.y);
    return out;
}

fragment float4 textVerticalFragment(
    FullscreenVertexOut in [[stage_in]],
    texture2d<float> horizontalTexture [[texture(0)]],
    constant AnimationUniforms &uniforms [[buffer(1)]]
) {
    constexpr sampler blurSampler(filter::linear, address::clamp_to_edge);
    const float2 texelSize = 1.0 / float2(
        horizontalTexture.get_width(),
        horizontalTexture.get_height()
    );
    const float4 center = horizontalTexture.sample(blurSampler, in.uv);
    const float blurRadius = center.a * uniforms.maxBlurInPixels;

    float coverage;
    if (blurRadius < 0.02) {
        coverage = center.r;
    } else {
        const float2 sampleStep = float2(0.0, blurRadius / 24.0 * texelSize.y);
        coverage = gaussianSample(horizontalTexture, blurSampler, in.uv, sampleStep).r;
    }
    return float4(0.09, 0.10, 0.11, coverage);
}
