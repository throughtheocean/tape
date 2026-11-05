#include <metal_stdlib>
using namespace metal;

// All geometry is in drawable pixels, origin top left.

struct Uniforms {
    float2 viewport;
};

struct RectInstance {
    float4 rect;   // x, y, width, height
    float4 color;
};

struct LineInstance {
    float4 points; // x0, y0, x1, y1
    float4 color;
    float4 params; // thickness, cap (0 or 1), unused, unused
};

struct VertexOut {
    float4 position [[position]];
    float4 color;
};

static float4 toClip(float2 p, float2 viewport) {
    return float4(p.x / viewport.x * 2.0 - 1.0, 1.0 - p.y / viewport.y * 2.0, 0.0, 1.0);
}

vertex VertexOut rectVertex(uint vid [[vertex_id]],
                            uint iid [[instance_id]],
                            device const RectInstance *rects [[buffer(0)]],
                            constant Uniforms &u [[buffer(1)]]) {
    RectInstance r = rects[iid];
    float2 corner = float2(float(vid & 1), float(vid >> 1));
    VertexOut out;
    out.position = toClip(r.rect.xy + corner * r.rect.zw, u.viewport);
    out.color = r.color;
    return out;
}

vertex VertexOut lineVertex(uint vid [[vertex_id]],
                            uint iid [[instance_id]],
                            device const LineInstance *lines [[buffer(0)]],
                            constant Uniforms &u [[buffer(1)]]) {
    LineInstance l = lines[iid];
    float2 a = l.points.xy;
    float2 b = l.points.zw;
    float2 d = b - a;
    float len = length(d);
    float2 dir = len > 1e-4 ? d / len : float2(1.0, 0.0);
    float2 n = float2(-dir.y, dir.x);
    float h = l.params.x * 0.5;
    float cap = l.params.y * h;
    float2 base = (vid >> 1) ? b + dir * cap : a - dir * cap;
    float2 p = base + n * ((vid & 1) ? h : -h);
    VertexOut out;
    out.position = toClip(p, u.viewport);
    out.color = l.color;
    return out;
}

fragment float4 colorFragment(VertexOut in [[stage_in]]) {
    return float4(in.color.rgb * in.color.a, in.color.a);
}
