//
//  VirtualDisplay.metal
//  Vortex
//
//  Two passes:
//   1. pattern_* rasterises the deterministic test pattern into the guest
//      framebuffer texture.
//   2. present_* composites that texture into the drawable, aspect-fitted.
//

#include <metal_stdlib>
using namespace metal;

struct PatternUniforms {
    float2 resolution;    // guest raster size in pixels
    float2 marker;        // marker centre in guest pixels
    float  markerRadius;  // ring radius in guest pixels
};

struct PresentUniforms {
    float2 rectOrigin;    // aspect-fit rect origin, drawable pixels
    float2 rectSize;      // aspect-fit rect size, drawable pixels
};

static float2 vortex_fullscreen_position(uint vertexID)
{
    // (-1,-1), (3,-1), (-1,3) covers clip space with a single triangle.
    return float2(vertexID == 1u ? 3.0f : -1.0f, vertexID == 2u ? 3.0f : -1.0f);
}

static float3 vortex_bar_colour(int index)
{
    switch (index) {
        case 0: return float3(0.784f, 0.784f, 0.784f);
        case 1: return float3(0.851f, 0.784f, 0.122f);
        case 2: return float3(0.114f, 0.722f, 0.749f);
        case 3: return float3(0.196f, 0.659f, 0.302f);
        case 4: return float3(0.722f, 0.216f, 0.749f);
        case 5: return float3(0.749f, 0.196f, 0.180f);
        default: return float3(0.098f, 0.161f, 0.722f);
    }
}

vertex float4 pattern_vertex(uint vertexID [[vertex_id]])
{
    return float4(vortex_fullscreen_position(vertexID), 0.0f, 1.0f);
}

fragment float4 pattern_fragment(float4 position [[position]],
                                 constant PatternUniforms &uniforms [[buffer(0)]])
{
    const float barCount = 7.0f;
    float barIndex = clamp(floor((position.x / uniforms.resolution.x) * barCount), 0.0f, barCount - 1.0f);
    float3 colour = vortex_bar_colour(int(barIndex));

    float2 delta = position.xy - uniforms.marker;
    float distanceToMarker = length(delta);
    float radius = max(uniforms.markerRadius, 1.0f);

    float ringWidth = max(1.5f, radius * 0.035f);
    float ring = 1.0f - smoothstep(ringWidth * 0.5f, ringWidth, abs(distanceToMarker - radius));

    float crossHalf = radius * 0.34f;
    float crossWidth = max(1.5f, radius * 0.045f);
    float horizontal = (1.0f - smoothstep(crossWidth * 0.5f, crossWidth, abs(delta.y))) *
                       (1.0f - smoothstep(crossHalf * 0.5f, crossHalf, abs(delta.x)));
    float vertical = (1.0f - smoothstep(crossWidth * 0.5f, crossWidth, abs(delta.x))) *
                     (1.0f - smoothstep(crossHalf * 0.5f, crossHalf, abs(delta.y)));
    float cross = max(horizontal, vertical);

    float glow = exp(-max(distanceToMarker - radius, 0.0f) / max(radius * 0.85f, 1.0f)) * 0.22f;

    colour = mix(colour, float3(0.94f, 0.92f, 1.0f), clamp(max(ring, cross), 0.0f, 1.0f));
    colour += glow * float3(0.42f, 0.34f, 0.85f);

    return float4(colour, 1.0f);
}

vertex float4 present_vertex(uint vertexID [[vertex_id]])
{
    return float4(vortex_fullscreen_position(vertexID), 0.0f, 1.0f);
}

fragment float4 present_fragment(float4 position [[position]],
                                 constant PresentUniforms &uniforms [[buffer(0)]],
                                 texture2d<float> guestTexture [[texture(0)]],
                                 sampler guestSampler [[sampler(0)]])
{
    float2 uv = (position.xy - uniforms.rectOrigin) / uniforms.rectSize;
    if (any(uv < 0.0f) || any(uv > 1.0f)) {
        return float4(0.0f, 0.0f, 0.0f, 1.0f);
    }

    float3 colour = guestTexture.sample(guestSampler, uv).rgb;
    return float4(colour, 1.0f);
}
