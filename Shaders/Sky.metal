// Sky.metal
// A small procedural sky: a gradient from the horizon to the zenith, the ground
// below, and the sun. It is drawn behind the scene, and it is also rendered into a
// cubemap from which the image-based lighting is computed, so that reflections and
// ambient light always match what the player sees.

#include "Common.metal"

static float3 skyRadiance(float3 direction, constant FrameUniforms &frame, bool withSunDisk) {
    float3 d = normalize(direction);
    float3 toSun = -frame.sunDirection;

    // Horizon to zenith. The square root keeps the horizon band thin, as in a real sky.
    float3 color = mix(frame.skyHorizonColor, frame.skyZenithColor, sqrt(saturate(d.y)));
    // Below the horizon, blend quickly into the ground color.
    color = mix(frame.skyGroundColor, color, smoothstep(-0.12, 0.0, d.y));

    // A glow around the sun: a tight one and a wide one.
    float towardSun = saturate(dot(d, toSun));
    float glow = 0.35 * pow(towardSun, 64.0) + 0.08 * pow(towardSun, 6.0);
    color += frame.sunColor * glow * smoothstep(-0.1, 0.05, d.y);

    if (withSunDisk) {
        float disk = smoothstep(frame.sunDiskSize, frame.sunDiskSize + 0.00008, dot(d, toSun));
        color += frame.sunColor * frame.sunDiskIntensity * disk;
    }
    return color * frame.skyIntensity;
}

// ---------------------------------------------------------------- the visible sky

struct SkyOut {
    float4 position [[position]];
    float3 direction;
};

// A full-screen triangle placed exactly on the far plane (z = w), drawn after the
// opaque geometry with a "less or equal" depth test: only the pixels that nothing
// else covered run the fragment function.
vertex SkyOut vertex_sky(uint vertexID [[vertex_id]],
                         constant PassUniforms &pass [[buffer(LMBufferPass)]]) {
    float2 uv = float2(float(vertexID & 2), float((vertexID << 1) & 2));
    float2 ndc = uv * float2(2.0, -2.0) + float2(-1.0, 1.0);

    SkyOut out;
    out.position = float4(ndc, 1.0, 1.0);
    // Where this corner of the far plane is in the world gives the view direction.
    float4 world = pass.inverseViewProjection * float4(ndc, 1.0, 1.0);
    out.direction = world.xyz / world.w - pass.cameraPosition;
    return out;
}

fragment float4 fragment_sky(SkyOut in [[stage_in]],
                             constant FrameUniforms &frame [[buffer(LMBufferFrame)]]) {
    return float4(skyRadiance(in.direction, frame, true), 1.0);
}

// ---------------------------------------------------------------- the sky as a cubemap

// The direction that a texel of a cubemap face looks at. `uv` has its origin at the
// top left of the face. This is the layout every graphics API shares.
static float3 cubeDirection(uint face, float2 uv) {
    float2 p = uv * 2.0 - 1.0;
    switch (face) {
        case 0: return float3(1.0, -p.y, -p.x);         // +X
        case 1: return float3(-1.0, -p.y, p.x);         // -X
        case 2: return float3(p.x, 1.0, p.y);           // +Y
        case 3: return float3(p.x, -1.0, -p.y);         // -Y
        case 4: return float3(p.x, -p.y, 1.0);          // +Z
        default: return float3(-p.x, -p.y, -1.0);       // -Z
    }
}

// Renders one face of the sky cubemap. The sun's disk is left out: direct sunlight is
// computed analytically, and a tiny, extremely bright spot would only add noise to the
// filtered maps.
fragment float4 fragment_sky_capture(FullscreenOut in [[stage_in]],
                                     constant CaptureUniforms &capture [[buffer(LMBufferPass)]],
                                     constant FrameUniforms &frame [[buffer(LMBufferFrame)]]) {
    return float4(skyRadiance(cubeDirection(capture.face, in.uv), frame, false), 1.0);
}
