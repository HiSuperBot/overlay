#include <metal_stdlib>
using namespace metal;

// A UIView reflection is not stored in its drawable. Bake that reflection into diagnostic clips.
kernel void recordingCopy(texture2d<float, access::sample> source [[texture(0)]],
                          texture2d<float, access::write> target [[texture(1)]],
                          constant uint2 &options [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= target.get_width() || gid.y >= target.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(target.get_width(), target.get_height());
    if (options.x) uv.x = 1.0 - uv.x;
    float3 color = source.sample(s, uv).rgb;
    if (options.y) {
        color = max(color, float3(0));
        color = select(color * 12.92, 1.055 * pow(color, float3(1.0 / 2.4)) - 0.055, color > 0.0031308);
    }
    target.write(float4(saturate(color), 1), gid);
}
