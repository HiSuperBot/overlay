#include <metal_stdlib>
using namespace metal;

struct CameraVertex {
    float4 position [[position]];
    float2 textureCoordinate;
};

vertex CameraVertex cameraVertex(
    uint index [[vertex_id]],
    constant float3x3 &displayToImage [[buffer(0)]]
) {
    const float2 positions[] = {
        float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1)
    };
    const float2 coordinates[] = {
        float2(0, 1), float2(1, 1), float2(0, 0), float2(1, 0)
    };
    CameraVertex output;
    output.position = float4(positions[index], 1, 1);
    output.textureCoordinate = (displayToImage * float3(coordinates[index], 1)).xy;
    return output;
}

fragment half4 cameraFragment(
    CameraVertex input [[stage_in]],
    texture2d<float> luma [[texture(0)]],
    texture2d<float> chroma [[texture(1)]]
) {
    constexpr sampler cameraSampler(filter::linear, address::clamp_to_edge);
    float y = luma.sample(cameraSampler, input.textureCoordinate).r;
    float2 cbcr = chroma.sample(cameraSampler, input.textureCoordinate).rg - 0.5;
    // ARKit supplies full-range YCbCr camera buffers.
    float3 rgb = float3(
        y + 1.402 * cbcr.y,
        y - 0.3441 * cbcr.x - 0.7141 * cbcr.y,
        y + 1.772 * cbcr.x
    );
    return half4(half3(saturate(rgb)), 1);
}

struct FaceVertex {
    float4 position [[position]];
};

vertex FaceVertex faceVertex(
    uint index [[vertex_id]],
    const device float3 *positions [[buffer(0)]],
    constant float4x4 &modelViewProjection [[buffer(1)]]
) {
    FaceVertex output;
    output.position = modelViewProjection * float4(positions[index], 1);
    return output;
}

fragment half4 faceFragment(FaceVertex input [[stage_in]]) {
    return half4(1);
}
