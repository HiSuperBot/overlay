#include <metal_stdlib>
using namespace metal;

vertex float4 avatarMaskVertex(uint id [[vertex_id]], constant float2 *points [[buffer(0)]]) {
    float2 uv = points[id];
    return float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0, 1);
}
fragment half avatarMaskFragment() { return half(1); }

kernel void avatarMaskBlur(texture2d<half, access::sample> mask [[texture(0)]],
                           texture2d<half, access::write> output [[texture(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 size(mask.get_width(), mask.get_height());
    float2 uv = (float2(gid) + 0.5) / size;
    half sum = 0;
    const half weights[7] = { 0.0366h, 0.1113h, 0.2167h, 0.2708h, 0.2167h, 0.1113h, 0.0366h };
    for (int i = -3; i <= 3; ++i) sum += mask.sample(s, uv + float2(i, 0) / size).r * weights[i + 3];
    output.write(half4(sum), gid);
}

float3 cameraToRGB(float y, float2 uv) {
    float cb = uv.x - 0.5, cr = uv.y - 0.5;
    return saturate(float3(y + 1.402 * cr, y - 0.344136 * cb - 0.714136 * cr, y + 1.772 * cb));
}
float3 sRGBToLinear(float3 c) {
    return select(c / 12.92, pow((c + 0.055) / 1.055, float3(2.4)), c > 0.04045);
}

float3 linearToSRGB(float3 c) {
    c = max(c, float3(0));
    return select(c * 12.92, 1.055 * pow(c, float3(1.0 / 2.4)) - 0.055, c > 0.0031308);
}

kernel void avatarComposite(texture2d<half, access::sample> rendered [[texture(0)]],
                            texture2d<half, access::write> output [[texture(1)]],
                            texture2d<float, access::sample> luma [[texture(2)]],
                            texture2d<float, access::sample> chroma [[texture(3)]],
                            texture2d<half, access::sample> mask [[texture(4)]],
                            constant float3x3 &imageTransform [[buffer(0)]],
                            constant uint2 &encoding [[buffer(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(output.get_width(), output.get_height());
    float2 cameraUV = (imageTransform * float3(uv, 1)).xy;
    float3 camera = cameraToRGB(luma.sample(s, cameraUV).r, chroma.sample(s, cameraUV).rg);
    camera = sRGBToLinear(camera);
    float3 avatar = float3(rendered.sample(s, uv).rgb);
    if (!encoding.x) avatar = sRGBToLinear(avatar);
    half alpha = 0;
    const half weights[7] = { 0.0366h, 0.1113h, 0.2167h, 0.2708h, 0.2167h, 0.1113h, 0.0366h };
    for (int i = -3; i <= 3; ++i) {
        alpha += mask.sample(s, uv + float2(0, float(i) / mask.get_height())).r * weights[i + 3];
    }
    float3 result = mix(camera, avatar, float(alpha));
    if (!encoding.y) result = linearToSRGB(result);
    output.write(half4(half3(result), 1), gid);
}


kernel void avatarCopy(texture2d<half, access::sample> source [[texture(0)]],
                       texture2d<half, access::write> target [[texture(1)]],
                       constant uint2 &encoding [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= target.get_width() || gid.y >= target.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(target.get_width(), target.get_height());
    float4 result = float4(source.sample(s, uv));
    if (encoding.x && !encoding.y) result.rgb = linearToSRGB(result.rgb);
    else if (!encoding.x && encoding.y) result.rgb = sRGBToLinear(result.rgb);
    target.write(half4(result), gid);
}
