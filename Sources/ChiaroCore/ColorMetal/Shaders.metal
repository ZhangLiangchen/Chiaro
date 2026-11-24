#include <metal_stdlib>
using namespace metal;

kernel void hdr_passthrough_kernel(
    texture2d<half, access::read> inTex [[texture(0)]],
    texture2d<half, access::write> outTex [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) {
        return;
    }
    half4 color = inTex.read(gid);
    outTex.write(color, gid);
}

// MARK: - Color Space Matrices (Row-major math converted to Metal column-major float3x3)

constant float3 kRec2020Luma = float3(0.2627002120f, 0.6779980715f, 0.0593017165f);
constant float3 kDisplayP3Luma = float3(0.2289745641f, 0.6917385218f, 0.0792869141f);
constant float3 kSRGBLuma = float3(0.2126390059f, 0.7151686788f, 0.0721923154f);

inline float3x3 make_mat3(float3 r0, float3 r1, float3 r2) {
    return float3x3(
        float3(r0.x, r1.x, r2.x),
        float3(r0.y, r1.y, r2.y),
        float3(r0.z, r1.z, r2.z)
    );
}

constant float3x3 kM_P3_to_2020 = float3x3(
    float3(+0.7538330344f, +0.0457438490f, -0.0012103404f),
    float3(+0.1985973691f, +0.9417772198f, +0.0176017173f),
    float3(+0.0475695966f, +0.0124789312f, +0.9836086231f)
);

constant float3x3 kM_sRGB_to_2020 = float3x3(
    float3(+0.6274038959f, +0.0690972893f, +0.0163914389f),
    float3(+0.3292830384f, +0.9195403951f, +0.0880133079f),
    float3(+0.0433130657f, +0.0113623156f, +0.8955952532f)
);

constant float3x3 kM_2020_to_P3 = float3x3(
    float3(+1.3435782526f, -0.0652974528f, +0.0028217873f),
    float3(-0.2821796705f, +1.0757879158f, -0.0195984945f),
    float3(-0.0613985821f, -0.0104904631f, +1.0167767073f)
);

constant float3x3 kM_2020_to_sRGB = float3x3(
    float3(+1.6604910021f, -0.1245504745f, -0.0181507634f),
    float3(-0.5876411388f, +1.1328998971f, -0.1005788980f),
    float3(-0.0728498633f, -0.0083494226f, +1.1187296614f)
);

constant float3x3 kM_AgX_Inset_2020 = float3x3(
    float3(+0.91725069f, +0.06228230f, +0.03407876f),
    float3(+0.04110084f, +0.82450391f, +0.02361892f),
    float3(+0.04164848f, +0.11321379f, +0.94230231f)
);

constant float3x3 kM_AgX_Outset_2020 = float3x3(
    float3(+1.09540094f, -0.07757292f, -0.03767127f),
    float3(-0.05340171f, +1.22082098f, -0.02866873f),
    float3(-0.04199923f, -0.14324806f, +1.06634000f)
);

constant float3x3 kM_2020_to_LMS = float3x3(
    float3(+0.6167557872f, +0.2651330640f, +0.1001026342f),
    float3(+0.3601983994f, +0.6358393641f, +0.2039065194f),
    float3(+0.0230458134f, +0.0990275718f, +0.6959908464f)
);

constant float3x3 kM_LMS_to_P3 = float3x3(
    float3(+3.1277689867f, -1.0910090474f, -0.0260108132f),
    float3(-2.2571357953f, +2.4133317580f, -0.5080413256f),
    float3(+0.1293668086f, -0.3223227107f, +1.5340521389f)
);

constant float3x3 kM_LMS_to_sRGB = float3x3(
    float3(+4.0767416614f, -1.2684380041f, -0.0041960865f),
    float3(-3.3077115904f, +2.6097574005f, -0.7034186144f),
    float3(+0.2309699286f, -0.3413193961f, +1.7076147009f)
);

constant float3x3 kM_LMS_to_2020 = float3x3(
    float3(+2.1399067357f, -0.8847358625f, -0.0485737579f),
    float3(-1.2463895088f, +2.1632309820f, -0.4545031429f),
    float3(+0.1064827729f, -0.2784951193f, +1.5030769008f)
);

constant float3x3 kM_LMS_cbrt_to_OKLab = float3x3(
    float3(+0.2104542553f, +1.9779984951f, +0.0259040371f),
    float3(+0.7936177850f, -2.4285922050f, +0.7827717662f),
    float3(-0.0040720468f, +0.4505937099f, -0.8086757660f)
);

constant float3x3 kM_OKLab_to_LMS_cbrt = float3x3(
    float3(1.0f, 1.0f, 1.0f),
    float3(+0.3963377774f, -0.1055613458f, -0.0894841775f),
    float3(+0.2158037573f, -0.0638541728f, -1.2914855480f)
);

inline float signed_cbrt(float x) {
    return copysign(pow(abs(x), 1.0f / 3.0f), x);
}

inline float3 rec2020_to_oklab(float3 rgb) {
    float3 lms = kM_2020_to_LMS * rgb;
    float3 lms_c = float3(signed_cbrt(lms.x), signed_cbrt(lms.y), signed_cbrt(lms.z));
    return kM_LMS_cbrt_to_OKLab * lms_c;
}

inline float3 oklab_to_rec2020(float3 lab) {
    float3 lms_c = kM_OKLab_to_LMS_cbrt * lab;
    float3 lms = lms_c * lms_c * lms_c;
    return kM_LMS_to_2020 * lms;
}

inline float3 oklab_to_target_rgb(float3 lab, bool isSRGB) {
    float3 lms_c = kM_OKLab_to_LMS_cbrt * lab;
    float3 lms = lms_c * lms_c * lms_c;
    return isSRGB ? (kM_LMS_to_sRGB * lms) : (kM_LMS_to_P3 * lms);
}

// MARK: - Pass 1: Malvar-He-Cutler 5x5 Demosaic + Highlight Reconstruction

struct DemosaicUniforms {
    uint width;
    uint height;
    uint cfaPattern; // 0=RGGB, 1=BGGR, 2=GRBG, 3=GBRG
    float whiteLevel;
    float4 blackLevel;
    float4 wbGain;
    float clipThreshold;
    float pad0;
    float pad1;
    float pad2;
};

// Returns 0=R, 1=G(R-row), 2=B, 3=G(B-row)
inline uint cfa_channel_at(int x, int y, uint pattern) {
    uint px = uint(x & 1);
    uint py = uint(y & 1);
    uint idx = (py << 1) | px;
    if (pattern == 0u) { // RGGB: (0,0)=R, (1,0)=G_r, (0,1)=G_b, (1,1)=B
        const uint map[4] = { 0u, 1u, 3u, 2u };
        return map[idx];
    } else if (pattern == 1u) { // BGGR: (0,0)=B, (1,0)=G_b, (0,1)=G_r, (1,1)=R
        const uint map[4] = { 2u, 3u, 1u, 0u };
        return map[idx];
    } else if (pattern == 2u) { // GRBG: (0,0)=G_r, (1,0)=R, (0,1)=B, (1,1)=G_b
        const uint map[4] = { 1u, 0u, 2u, 3u };
        return map[idx];
    } else { // GBRG: (0,0)=G_b, (1,0)=B, (0,1)=R, (1,1)=G_r
        const uint map[4] = { 3u, 2u, 0u, 1u };
        return map[idx];
    }
}

inline float sample_bayer_norm(
    device const ushort* rawData,
    int x,
    int y,
    constant DemosaicUniforms& u
) {
    int cx = clamp(x, 0, int(u.width) - 1);
    int cy = clamp(y, 0, int(u.height) - 1);
    uint ch = cfa_channel_at(cx, cy, u.cfaPattern);
    float b = u.blackLevel[ch];
    float denom = max(u.whiteLevel - b, 1.0f);
    float v = (float(rawData[uint(cy) * u.width + uint(cx)]) - b) / denom;
    return max(v, -0.02f);
}

kernel void demosaic_bayer_malvar_5x5_kernel(
    device const ushort* rawData [[buffer(0)]],
    constant DemosaicUniforms& u [[buffer(1)]],
    texture2d<half, access::write> outTex [[texture(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= u.width || gid.y >= u.height) {
        return;
    }

    int x = int(gid.x);
    int y = int(gid.y);
    uint ch = cfa_channel_at(x, y, u.cfaPattern);

    float C = sample_bayer_norm(rawData, x, y, u);
    float N1 = sample_bayer_norm(rawData, x, y - 1, u);
    float S1 = sample_bayer_norm(rawData, x, y + 1, u);
    float W1 = sample_bayer_norm(rawData, x - 1, y, u);
    float E1 = sample_bayer_norm(rawData, x + 1, y, u);

    float NW = sample_bayer_norm(rawData, x - 1, y - 1, u);
    float NE = sample_bayer_norm(rawData, x + 1, y - 1, u);
    float SW = sample_bayer_norm(rawData, x - 1, y + 1, u);
    float SE = sample_bayer_norm(rawData, x + 1, y + 1, u);

    float N2 = sample_bayer_norm(rawData, x, y - 2, u);
    float S2 = sample_bayer_norm(rawData, x, y + 2, u);
    float W2 = sample_bayer_norm(rawData, x - 2, y, u);
    float E2 = sample_bayer_norm(rawData, x + 2, y, u);

    float r, g, b;
    if (ch == 0u) { // Red site
        r = C;
        g = (4.0f * C + 2.0f * (N1 + S1 + W1 + E1) - (N2 + S2 + W2 + E2)) * 0.125f;
        b = (6.0f * C + 2.0f * (NW + NE + SW + SE) - 1.5f * (N2 + S2 + W2 + E2)) * 0.125f;
    } else if (ch == 2u) { // Blue site
        b = C;
        g = (4.0f * C + 2.0f * (N1 + S1 + W1 + E1) - (N2 + S2 + W2 + E2)) * 0.125f;
        r = (6.0f * C + 2.0f * (NW + NE + SW + SE) - 1.5f * (N2 + S2 + W2 + E2)) * 0.125f;
    } else if (ch == 1u) { // Green on Red row (horizontal neighbors are R, vertical are B)
        g = C;
        r = (5.0f * C + 4.0f * (W1 + E1) - (NW + NE + SW + SE + W2 + E2) + 0.5f * (N2 + S2)) * 0.125f;
        b = (5.0f * C + 4.0f * (N1 + S1) - (NW + NE + SW + SE + N2 + S2) + 0.5f * (W2 + E2)) * 0.125f;
    } else { // Green on Blue row (horizontal neighbors are B, vertical are R)
        g = C;
        b = (5.0f * C + 4.0f * (W1 + E1) - (NW + NE + SW + SE + W2 + E2) + 0.5f * (N2 + S2)) * 0.125f;
        r = (5.0f * C + 4.0f * (N1 + S1) - (NW + NE + SW + SE + N2 + S2) + 0.5f * (W2 + E2)) * 0.125f;
    }

    // 3-bit clip mask over 3x3 same-color photosites
    uint clipMask = 0u;
    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            uint nch = cfa_channel_at(x + dx, y + dy, u.cfaPattern);
            float nv = sample_bayer_norm(rawData, x + dx, y + dy, u);
            if (nv >= u.clipThreshold) {
                if (nch == 0u) clipMask |= 1u;
                else if (nch == 2u) clipMask |= 4u;
                else clipMask |= 2u;
            }
        }
    }

    float3 rgb = max(float3(r, g, b), float3(0.0f)) * u.wbGain.xyz;
    outTex.write(half4(half3(rgb), half(clipMask)), gid);
}

struct HighlightReconUniforms {
    uint width;
    uint height;
    float minClipCeil;
    float maxClipCeil;
};

inline float3 mean_other_unclipped_ref(float3 rgb, uint mask, thread uint& unclippedCount) {
    float sum = 0.0f;
    unclippedCount = 0u;
    if ((mask & 1u) == 0u) { sum += rgb.r; unclippedCount++; }
    if ((mask & 2u) == 0u) { sum += rgb.g; unclippedCount++; }
    if ((mask & 4u) == 0u) { sum += rgb.b; unclippedCount++; }
    float meanVal = unclippedCount > 0u ? (sum / float(unclippedCount)) : max(rgb.r, max(rgb.g, rgb.b));
    return float3(meanVal);
}

kernel void opposed_inpaint_reduce_kernel(
    texture2d<half, access::read> inTex [[texture(0)]],
    device float* groupAccumBuf [[buffer(0)]], // per group: [sumR, sumG, sumB, cntR, cntG, cntB]
    constant HighlightReconUniforms& u [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 tid [[thread_position_in_threadgroup]],
    uint2 tgid [[threadgroup_position_in_grid]],
    uint2 tgCount [[threadgroups_per_grid]]
) {
    threadgroup float tgSum[256][3];
    threadgroup uint tgCnt[256][3];

    uint lid = tid.y * 16u + tid.x;
    float s0 = 0.0f, s1 = 0.0f, s2 = 0.0f;
    uint n0 = 0u, n1 = 0u, n2 = 0u;

    if (gid.x < u.width && gid.y < u.height) {
        half4 px = inTex.read(gid);
        float3 rgb = float3(px.rgb);
        uint mask = uint(round(float(px.a)));
        float maxRGB = max(rgb.r, max(rgb.g, rgb.b));

        if (maxRGB > 0.65f * u.minClipCeil) {
            uint c0 = (mask & 1u) == 0u ? 1u : 0u;
            uint c1 = (mask & 2u) == 0u ? 1u : 0u;
            uint c2 = (mask & 4u) == 0u ? 1u : 0u;
            if (c0 + c1 + c2 >= 2u) {
                if (c0 != 0u) {
                    s0 = clamp(rgb.r - (rgb.g + rgb.b) * 0.5f, -4.0f, 4.0f);
                    n0 = 1u;
                }
                if (c1 != 0u) {
                    s1 = clamp(rgb.g - (rgb.r + rgb.b) * 0.5f, -4.0f, 4.0f);
                    n1 = 1u;
                }
                if (c2 != 0u) {
                    s2 = clamp(rgb.b - (rgb.r + rgb.g) * 0.5f, -4.0f, 4.0f);
                    n2 = 1u;
                }
            }
        }
    }

    tgSum[lid][0] = s0; tgSum[lid][1] = s1; tgSum[lid][2] = s2;
    tgCnt[lid][0] = n0; tgCnt[lid][1] = n1; tgCnt[lid][2] = n2;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint stride = 128u; stride > 0u; stride >>= 1u) {
        if (lid < stride) {
            for (int c = 0; c < 3; ++c) {
                tgSum[lid][c] += tgSum[lid + stride][c];
                tgCnt[lid][c] += tgCnt[lid + stride][c];
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    if (lid == 0u) {
        uint gIdx = tgid.y * tgCount.x + tgid.x;
        uint base = gIdx * 6u;
        groupAccumBuf[base + 0u] = tgSum[0][0];
        groupAccumBuf[base + 1u] = tgSum[0][1];
        groupAccumBuf[base + 2u] = tgSum[0][2];
        groupAccumBuf[base + 3u] = float(tgCnt[0][0]);
        groupAccumBuf[base + 4u] = float(tgCnt[0][1]);
        groupAccumBuf[base + 5u] = float(tgCnt[0][2]);
    }
}

kernel void opposed_inpaint_finalize_kernel(
    device const float* groupAccumBuf [[buffer(0)]],
    device float* finalChromaBuf [[buffer(1)]], // [chromaR, chromaG, chromaB, 0]
    constant uint& groupCount [[buffer(2)]],
    uint lid [[thread_index_in_threadgroup]]
) {
    threadgroup float tgSum[256][3];
    threadgroup uint tgCnt[256][3];

    float localSum[3] = { 0.0f, 0.0f, 0.0f };
    float localComp[3] = { 0.0f, 0.0f, 0.0f };
    uint localCnt[3] = { 0u, 0u, 0u };

    for (uint g = lid; g < groupCount; g += 256u) {
        uint base = g * 6u;
        for (int c = 0; c < 3; ++c) {
            float val = groupAccumBuf[base + uint(c)];
            float y = val - localComp[c];
            float t = localSum[c] + y;
            localComp[c] = (t - localSum[c]) - y;
            localSum[c] = t;
            localCnt[c] += uint(round(groupAccumBuf[base + 3u + uint(c)]));
        }
    }

    for (int c = 0; c < 3; ++c) {
        tgSum[lid][c] = localSum[c];
        tgCnt[lid][c] = localCnt[c];
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint stride = 128u; stride > 0u; stride >>= 1u) {
        if (lid < stride) {
            for (int c = 0; c < 3; ++c) {
                tgSum[lid][c] += tgSum[lid + stride][c];
                tgCnt[lid][c] += tgCnt[lid + stride][c];
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    if (lid == 0u) {
        for (int c = 0; c < 3; ++c) {
            uint cnt = tgCnt[0][c];
            finalChromaBuf[c] = cnt > 0u ? clamp(tgSum[0][c] / float(cnt), -0.5f, 0.5f) : 0.0f;
        }
        finalChromaBuf[3] = 0.0f;
    }
}

kernel void opposed_inpaint_apply_kernel(
    texture2d<half, access::read> inTex [[texture(0)]],
    texture2d<half, access::write> outTex [[texture(1)]],
    device const float* finalChromaBuf [[buffer(0)]],
    constant HighlightReconUniforms& u [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= u.width || gid.y >= u.height) {
        return;
    }
    half4 px = inTex.read(gid);
    float3 rgb = float3(px.rgb);
    uint mask = uint(round(float(px.a)));

    if (mask == 0u) {
        outTex.write(half4(half3(rgb), 1.0h), gid);
        return;
    }

    if (mask == 7u) {
        float neutral = max(rgb.r, max(rgb.g, rgb.b));
        outTex.write(half4(half3(neutral), 1.0h), gid);
        return;
    }

    float3 globalChroma = float3(finalChromaBuf[0], finalChromaBuf[1], finalChromaBuf[2]);

    // Local 7x7 opposed chrominance estimate blended with global chrominance
    float3 localSum = float3(0.0f);
    float3 localCnt = float3(0.0f);
    int x0 = max(0, int(gid.x) - 3);
    int x1 = min(int(u.width) - 1, int(gid.x) + 3);
    int y0 = max(0, int(gid.y) - 3);
    int y1 = min(int(u.height) - 1, int(gid.y) + 3);

    for (int ny = y0; ny <= y1; ++ny) {
        for (int nx = x0; nx <= x1; ++nx) {
            half4 npx = inTex.read(uint2(nx, ny));
            uint nmask = uint(round(float(npx.a)));
            if (nmask == 0u) {
                float3 nrgb = float3(npx.rgb);
                if (max(nrgb.r, max(nrgb.g, nrgb.b)) > 0.55f * u.minClipCeil) {
                    localSum.r += nrgb.r - 0.5f * (nrgb.g + nrgb.b);
                    localSum.g += nrgb.g - 0.5f * (nrgb.r + nrgb.b);
                    localSum.b += nrgb.b - 0.5f * (nrgb.r + nrgb.g);
                    localCnt += float3(1.0f);
                }
            }
        }
    }

    float3 chroma = globalChroma;
    for (int c = 0; c < 3; ++c) {
        if (localCnt[c] >= 4.0f) {
            float lc = clamp(localSum[c] / localCnt[c], -0.5f, 0.5f);
            float w = clamp(localCnt[c] / 16.0f, 0.0f, 0.75f);
            chroma[c] = mix(globalChroma[c], lc, w);
        }
    }

    uint unclippedCount = 0u;
    float ref = mean_other_unclipped_ref(rgb, mask, unclippedCount).x;
    if ((mask & 1u) != 0u) rgb.r = max(rgb.r, ref + chroma.r);
    if ((mask & 2u) != 0u) rgb.g = max(rgb.g, ref + chroma.g);
    if ((mask & 4u) != 0u) rgb.b = max(rgb.b, ref + chroma.b);

    outTex.write(half4(half3(max(rgb, float3(0.0f))), 1.0h), gid);
}

kernel void highlight_blend_kernel(
    texture2d<half, access::read> inTex [[texture(0)]],
    texture2d<half, access::write> outTex [[texture(1)]],
    constant HighlightReconUniforms& u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= u.width || gid.y >= u.height) {
        return;
    }
    half4 px = inTex.read(gid);
    float3 rgb = float3(px.rgb);
    uint mask = uint(round(float(px.a)));
    if (mask == 0u) {
        outTex.write(half4(half3(rgb), 1.0h), gid);
        return;
    }
    uint unclippedCount = 0u;
    float L_unclipped = mean_other_unclipped_ref(rgb, mask, unclippedCount).x;
    float maxRGB = max(rgb.r, max(rgb.g, rgb.b));
    float target = max(L_unclipped, maxRGB);
    float alpha = (mask == 7u) ? 1.0f : smoothstep(0.90f * u.minClipCeil, max(u.maxClipCeil, 0.90f * u.minClipCeil + 1e-4f), maxRGB);
    float3 out = mix(rgb, float3(target), alpha);
    outTex.write(half4(half3(max(out, float3(0.0f))), 1.0h), gid);
}

kernel void rebuild_seed_kernel(
    texture2d<half, access::read> inTex [[texture(0)]],
    texture2d<half, access::write> seedTex [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= seedTex.get_width() || gid.y >= seedTex.get_height()) {
        return;
    }
    half4 px = inTex.read(gid);
    float3 rgb = float3(px.rgb);
    uint mask = uint(round(float(px.a)));
    if (mask == 0u) {
        float luma = max(dot(rgb, float3(0.25f, 0.5f, 0.25f)), 1e-4f);
        seedTex.write(half4(half3(rgb / luma), 1.0h), gid);
    } else {
        seedTex.write(half4(0.0h), gid);
    }
}

kernel void rebuild_pull_kernel(
    texture2d<half, access::read> fineTex [[texture(0)]],
    texture2d<half, access::write> coarseTex [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint cw = coarseTex.get_width();
    uint ch = coarseTex.get_height();
    if (gid.x >= cw || gid.y >= ch) {
        return;
    }
    uint fw = fineTex.get_width();
    uint fh = fineTex.get_height();
    float3 sum = float3(0.0f);
    float wSum = 0.0f;
    for (uint dy = 0u; dy < 2u; ++dy) {
        for (uint dx = 0u; dx < 2u; ++dx) {
            uint sx = min(gid.x * 2u + dx, fw - 1u);
            uint sy = min(gid.y * 2u + dy, fh - 1u);
            float4 s = float4(fineTex.read(uint2(sx, sy)));
            sum += s.rgb * s.a;
            wSum += s.a;
        }
    }
    if (wSum > 1e-5f) {
        coarseTex.write(half4(half3(sum / wSum), half(min(wSum * 0.25f, 1.0f))), gid);
    } else {
        coarseTex.write(half4(0.0h), gid);
    }
}

kernel void rebuild_push_kernel(
    texture2d<half, access::read> fineInTex [[texture(0)]],
    texture2d<half, access::read> coarseTex [[texture(1)]],
    texture2d<half, access::write> fineOutTex [[texture(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint fw = fineOutTex.get_width();
    uint fh = fineOutTex.get_height();
    if (gid.x >= fw || gid.y >= fh) {
        return;
    }
    float4 fine = float4(fineInTex.read(gid));
    if (fine.a > 0.5f) {
        fineOutTex.write(half4(fine), gid);
        return;
    }
    uint cw = coarseTex.get_width();
    uint ch = coarseTex.get_height();
    uint cx = min(gid.x / 2u, cw - 1u);
    uint cy = min(gid.y / 2u, ch - 1u);
    float4 coarse = float4(coarseTex.read(uint2(cx, cy)));
    if (coarse.a > 1e-5f) {
        fineOutTex.write(half4(half3(coarse.rgb), 1.0h), gid);
    } else {
        fineOutTex.write(half4(1.0h), gid);
    }
}

kernel void rebuild_apply_kernel(
    texture2d<half, access::read> inTex [[texture(0)]],
    texture2d<half, access::read> ratioTex [[texture(1)]],
    texture2d<half, access::write> outTex [[texture(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) {
        return;
    }
    half4 px = inTex.read(gid);
    float3 rgb = float3(px.rgb);
    uint mask = uint(round(float(px.a)));
    if (mask == 0u) {
        outTex.write(half4(half3(rgb), 1.0h), gid);
        return;
    }
    if (mask == 7u) {
        float neutral = max(rgb.r, max(rgb.g, rgb.b));
        outTex.write(half4(half3(neutral), 1.0h), gid);
        return;
    }
    float3 ratio = float3(ratioTex.read(gid).rgb);
    uint unclippedCount = 0u;
    float ref = mean_other_unclipped_ref(rgb, mask, unclippedCount).x;
    if ((mask & 1u) != 0u) rgb.r = max(rgb.r, ref * ratio.r);
    if ((mask & 2u) != 0u) rgb.g = max(rgb.g, ref * ratio.g);
    if ((mask & 4u) != 0u) rgb.b = max(rgb.b, ref * ratio.b);
    outTex.write(half4(half3(max(rgb, float3(0.0f))), 1.0h), gid);
}

// MARK: - Unpack 3ch/4ch UInt16 & Float16 Payloads

struct UnpackRGBUniforms {
    uint width;
    uint height;
    uint channelCount;
    float scaleFactor;
    float4 preCompClipThreshold; // xyz = per-channel clip threshold in rawNorm [0,1]; w = detectClipMask (0 or 1)
    float4 preMatCol0;
    float4 preMatCol1;
    float4 preMatCol2;
    uint usePreMat;
    float clipThreshScale;
    uint pad1;
    uint pad2;
};

kernel void unpack_rgb16u_to_rgba16f_kernel(
    device const ushort* srcData [[buffer(0)]],
    constant UnpackRGBUniforms& u [[buffer(1)]],
    texture2d<half, access::write> outTex [[texture(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= u.width || gid.y >= u.height) {
        return;
    }
    uint idx = (gid.y * u.width + gid.x) * u.channelCount;
    float3 rawNorm = float3(srcData[idx], srcData[idx + 1u], srcData[idx + 2u]) / 65535.0f;
    float3x3 preMat = float3x3(u.preMatCol0.xyz, u.preMatCol1.xyz, u.preMatCol2.xyz);
    float3 camNorm = preMat * rawNorm;
    float3 camEst = camNorm;
    float mask = 1.0f;
    if (u.preCompClipThreshold.w > 0.5f) {
        float3 thresh = u.preCompClipThreshold.xyz;
        if (u.usePreMat != 0u) {
            float3 ceilCam = thresh / max(u.clipThreshScale, 1e-4f);
            float3 cols[3] = { u.preMatCol0.xyz, u.preMatCol1.xyz, u.preMatCol2.xyz };
            for (int pass = 0; pass < 2; ++pass) {
                for (int ch = 0; ch < 3; ++ch) {
                    if (rawNorm[ch] >= 65534.5f / 65535.0f) {
                        float3 col = cols[ch];
                        float tMax = 1e9f;
                        bool hasBound = false;
                        for (int k = 0; k < 3; ++k) {
                            float p = col[k];
                            if (p > 1e-4f && (k == ch || camNorm[k] <= ceilCam[k] + 1e-4f)) {
                                tMax = min(tMax, (ceilCam[k] - camEst[k]) / p);
                                hasBound = true;
                            } else if (p < -1e-4f && (k == ch || camNorm[k] >= -1e-4f)) {
                                tMax = min(tMax, (0.0f - camEst[k]) / p);
                                hasBound = true;
                            }
                        }
                        if (hasBound && tMax > 0.0f) {
                            tMax = min(tMax, 10.0f);
                            camEst += tMax * col;
                        }
                    }
                }
            }
        }
        uint clipMask = 0u;
        if (camEst.r >= thresh.x) clipMask |= 1u;
        if (camEst.g >= thresh.y) clipMask |= 2u;
        if (camEst.b >= thresh.z) clipMask |= 4u;
        mask = float(clipMask);
    }
    float3 rgb = camEst * u.scaleFactor;
    outTex.write(half4(half3(rgb), half(mask)), gid);
}

kernel void unpack_rgb16f_to_rgba16f_kernel(
    device const half* srcData [[buffer(0)]],
    constant UnpackRGBUniforms& u [[buffer(1)]],
    texture2d<half, access::write> outTex [[texture(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= u.width || gid.y >= u.height) {
        return;
    }
    uint idx = (gid.y * u.width + gid.x) * u.channelCount;
    float3 rgb = float3(srcData[idx], srcData[idx + 1u], srcData[idx + 2u]) * u.scaleFactor;
    outTex.write(half4(half3(rgb), 1.0h), gid);
}

// MARK: - Pass 2: Camera Color Matrix / DCP HSV Table / Log-Shaper .cube LUT -> Linear Rec.2020

struct CameraColorLUTUniforms {
    float4 camToRec2020Col0;
    float4 camToRec2020Col1;
    float4 camToRec2020Col2;
    float4 lutDomainMin;
    float4 lutDomainMax;
    uint hasHueSatTable;
    uint hasLookTable;
    uint lutMode; // 0=none, 1=1D, 2=3D
    uint lutSize;
};

inline float3 rgb_to_hsv_hdr(float3 c) {
    float cmax = max(c.r, max(c.g, c.b));
    float cmin = min(c.r, min(c.g, c.b));
    float delta = cmax - cmin;
    float h = 0.0f;
    if (delta > 1e-6f) {
        if (cmax == c.r) h = fmod((c.g - c.b) / delta + 6.0f, 6.0f);
        else if (cmax == c.g) h = (c.b - c.r) / delta + 2.0f;
        else h = (c.r - c.g) / delta + 4.0f;
        h /= 6.0f;
    }
    float s = cmax > 1e-6f ? (delta / cmax) : 0.0f;
    return float3(h, s, cmax);
}

inline float3 hsv_to_rgb_hdr(float3 hsv) {
    float h = fract(hsv.x) * 6.0f;
    float s = clamp(hsv.y, 0.0f, 1.0f);
    float v = max(hsv.z, 0.0f);
    float c = v * s;
    float x = c * (1.0f - abs(fmod(h, 2.0f) - 1.0f));
    float m = v - c;
    float3 rgb;
    if (h < 1.0f) rgb = float3(c, x, 0.0f);
    else if (h < 2.0f) rgb = float3(x, c, 0.0f);
    else if (h < 3.0f) rgb = float3(0.0f, c, x);
    else if (h < 4.0f) rgb = float3(0.0f, x, c);
    else if (h < 5.0f) rgb = float3(x, 0.0f, c);
    else rgb = float3(c, 0.0f, x);
    return rgb + float3(m);
}

inline float3 apply_hsv_table(float3 rgb, texture3d<float, access::sample> hsvTex) {
    constexpr sampler s(
        coord::normalized,
        s_address::clamp_to_edge,
        t_address::repeat,
        r_address::clamp_to_edge,
        filter::linear
    );
    float3 hsv = rgb_to_hsv_hdr(max(rgb, float3(0.0f)));
    float hdrScale = max(hsv.z, 1.0f);
    float vIdx = min(hsv.z, 1.0f);
    // texture3d dimensions: x=sat, y=hue (periodic [0,1)), z=val
    float satN = float(hsvTex.get_width());
    float hueN = max(float(hsvTex.get_height()), 1.0f);
    float valN = float(hsvTex.get_depth());
    float uCoord = satN > 1.0f ? ((0.5f + clamp(hsv.y, 0.0f, 1.0f) * (satN - 1.0f)) / satN) : 0.5f;
    float vCoord = (0.5f + fract(hsv.x) * hueN) / hueN;
    float wCoord = valN > 1.0f ? ((0.5f + clamp(vIdx, 0.0f, 1.0f) * (valN - 1.0f)) / valN) : 0.5f;
    float3 delta = hsvTex.sample(s, float3(uCoord, vCoord, wCoord)).xyz;
    float h2 = fract(hsv.x + delta.x / 360.0f);
    float s2 = clamp(hsv.y * delta.y, 0.0f, 1.0f);
    float v2 = vIdx * delta.z * hdrScale;
    return hsv_to_rgb_hdr(float3(h2, s2, v2));
}

inline float3 shaper_fwd(float3 rgb) {
    float3 ev = log2(max(rgb, float3(0.0009765625f)));
    return clamp((ev - (-10.0f)) / 16.0f, 0.0f, 1.0f);
}

inline float3 shaper_inv(float3 t) {
    return exp2(min(t * 16.0f - 10.0f, float3(15.99f)));
}

inline float3 eval_lut_shaper_inv(float3 rgbIn, float3 mapped, float peakRatio) {
    float3 expVal = shaper_inv(mapped);
    float3 zeroFade = smoothstep(float3(0.0f), float3(1e-4f), mapped);
    float3 blackScale = mix(clamp(rgbIn / 0.0009765625f, float3(0.0f), float3(1.0f)), float3(1.0f), zeroFade);
    float3 outRGB = min(expVal * blackScale * peakRatio, float3(65000.0f));
    return select(float3(0.0f), max(outRGB, float3(0.0f)), isfinite(outRGB));
}

kernel void camera_to_rec2020_lut_kernel(
    texture2d<half, access::read> inTex [[texture(0)]],
    texture2d<half, access::write> outTex [[texture(1)]],
    texture3d<float, access::sample> hueSatTex [[texture(2)]],
    texture3d<float, access::sample> lookTex [[texture(3)]],
    texture2d<float, access::sample> lut1DTex [[texture(4)]],
    texture3d<float, access::sample> lut3DTex [[texture(5)]],
    constant CameraColorLUTUniforms& u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) {
        return;
    }

    float3x3 mat = float3x3(u.camToRec2020Col0.xyz, u.camToRec2020Col1.xyz, u.camToRec2020Col2.xyz);
    float3 rgb = mat * float3(inTex.read(gid).rgb);
    rgb = max(rgb, float3(0.0f));

    if (u.hasHueSatTable != 0u) {
        rgb = apply_hsv_table(rgb, hueSatTex);
    }
    if (u.hasLookTable != 0u) {
        rgb = apply_hsv_table(rgb, lookTex);
    }

    if (u.lutMode == 1u && u.lutSize >= 2u) {
        constexpr sampler s1(coord::normalized, address::clamp_to_edge, filter::linear);
        float peakRatio = max(max(rgb.r, max(rgb.g, rgb.b)) / 64.0f, 1.0f);
        float3 shaped = shaper_fwd(rgb);
        float3 norm = clamp((shaped - u.lutDomainMin.xyz) / max(u.lutDomainMax.xyz - u.lutDomainMin.xyz, float3(1e-5f)), 0.0f, 1.0f);
        float n = float(u.lutSize);
        float ur = (0.5f + norm.r * (n - 1.0f)) / n;
        float ug = (0.5f + norm.g * (n - 1.0f)) / n;
        float ub = (0.5f + norm.b * (n - 1.0f)) / n;
        float3 mapped = float3(
            lut1DTex.sample(s1, float2(ur, 0.5f)).r,
            lut1DTex.sample(s1, float2(ug, 0.5f)).g,
            lut1DTex.sample(s1, float2(ub, 0.5f)).b
        );
        rgb = eval_lut_shaper_inv(rgb, mapped, peakRatio);
    } else if (u.lutMode == 2u && u.lutSize >= 2u) {
        constexpr sampler s3(coord::normalized, address::clamp_to_edge, filter::linear);
        float peakRatio = max(max(rgb.r, max(rgb.g, rgb.b)) / 64.0f, 1.0f);
        float3 shaped = shaper_fwd(rgb);
        float3 norm = clamp((shaped - u.lutDomainMin.xyz) / max(u.lutDomainMax.xyz - u.lutDomainMin.xyz, float3(1e-5f)), 0.0f, 1.0f);
        float n = float(u.lutSize);
        float3 uvw = (0.5f + norm * (n - 1.0f)) / n;
        float3 mapped = lut3DTex.sample(s3, uvw).rgb;
        rgb = eval_lut_shaper_inv(rgb, mapped, peakRatio);
    }

    outTex.write(half4(half3(max(rgb, float3(0.0f))), 1.0h), gid);
}

// MARK: - Pass 3: Shared Scene Grading (Linear Rec.2020 D65)

struct SceneGradingUniforms {
    float4 wbCol0;
    float4 wbCol1;
    float4 wbCol2;
    float exposureLinear;
    float blackPoint;
    float shadowRecovery;
    float vibrance;
};

kernel void scene_grading_kernel(
    texture2d<half, access::read> inTex [[texture(0)]],
    texture2d<half, access::write> outTex [[texture(1)]],
    constant SceneGradingUniforms& u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) {
        return;
    }

    float3x3 wbMat = float3x3(u.wbCol0.xyz, u.wbCol1.xyz, u.wbCol2.xyz);
    float3 rgb = max(wbMat * float3(inTex.read(gid).rgb), float3(0.0f));

    // Exposure
    rgb *= u.exposureLinear;

    // Black Point (smooth shadow-weighted offset, leaves Y >= 0.18 untouched)
    if (abs(u.blackPoint) > 1e-5f) {
        float Y = dot(rgb, kRec2020Luma);
        float bp = u.blackPoint * 0.0002f;
        float w = 1.0f - smoothstep(0.0f, 0.18f, Y);
        rgb = max(rgb - bp * w, float3(0.0f));
    }

    // Shadow Recovery (C1 hue-preserving lift for Y < 0.36)
    if (u.shadowRecovery > 1e-5f) {
        float Y = dot(rgb, kRec2020Luma);
        float s = u.shadowRecovery * 0.01f;
        float t = max(1.0f - Y / 0.36f, 0.0f);
        float gain = exp2(s * 2.0f * (t * t));
        rgb *= gain;
    }

    // Skin-protected OKLab Vibrance
    if (abs(u.vibrance) > 1e-5f) {
        float3 lab = rec2020_to_oklab(rgb);
        float C = length(float2(lab.y, lab.z));
        float hueDeg = atan2(lab.z, lab.y) * (180.0f / M_PI_F);
        float skinProtect = 1.0f - 0.5f * exp(-pow((hueDeg - 38.0f) / 18.0f, 2.0f));
        float w = (1.0f - smoothstep(0.05f, 0.25f, C)) * (u.vibrance >= 0.0f ? skinProtect : 1.0f);
        float scale = max(1.0f + (u.vibrance * 0.01f) * 0.65f * w, 0.0f);
        lab.y *= scale;
        lab.z *= scale;
        rgb = max(oklab_to_rec2020(lab), float3(0.0f));
    }

    outTex.write(half4(half3(rgb), 1.0h), gid);
}

// MARK: - Pass 5A: Physical Orientation Baking (1..8 -> Upright), Crop & Linear-Light Resize

struct OrientCropResizeUniforms {
    uint srcWidth;
    uint srcHeight;
    uint cropX;
    uint cropY;
    uint cropWidth;
    uint cropHeight;
    uint outWidth;
    uint outHeight;
    uint orientation;
    uint isOneToOne;
    uint pad0;
    uint pad1;
};

inline float2 upright_to_source_coord(float ux, float uy, uint srcW, uint srcH, uint orientation) {
    float fw = float(srcW - 1u);
    float fh = float(srcH - 1u);
    switch (orientation) {
        case 2u: return float2(fw - ux, uy);
        case 3u: return float2(fw - ux, fh - uy);
        case 4u: return float2(ux, fh - uy);
        case 5u: return float2(uy, ux);
        case 6u: return float2(uy, fh - ux);
        case 7u: return float2(fw - uy, fh - ux);
        case 8u: return float2(fw - uy, ux);
        default: return float2(ux, uy); // orientation == 1
    }
}

inline float lanczos2_weight(float x) {
    float ax = abs(x);
    if (ax < 1e-5f) return 1.0f;
    if (ax >= 2.0f) return 0.0f;
    float pix = M_PI_F * ax;
    return (sin(pix) / pix) * (sin(pix * 0.5f) / (pix * 0.5f));
}

kernel void orient_crop_resize_kernel(
    texture2d<half, access::read> inTex [[texture(0)]],
    texture2d<half, access::write> outTex [[texture(1)]],
    constant OrientCropResizeUniforms& u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= u.outWidth || gid.y >= u.outHeight) {
        return;
    }

    if (u.isOneToOne != 0u) {
        float ux = float(u.cropX + gid.x);
        float uy = float(u.cropY + gid.y);
        float2 sc = upright_to_source_coord(ux, uy, u.srcWidth, u.srcHeight, u.orientation);
        uint2 iq = uint2(clamp(int(round(sc.x)), 0, int(u.srcWidth) - 1),
                         clamp(int(round(sc.y)), 0, int(u.srcHeight) - 1));
        outTex.write(inTex.read(iq), gid);
        return;
    }

    float scaleX = float(u.cropWidth) / float(u.outWidth);
    float scaleY = float(u.cropHeight) / float(u.outHeight);
    float uxCenter = float(u.cropX) + (float(gid.x) + 0.5f) * scaleX - 0.5f;
    float uyCenter = float(u.cropY) + (float(gid.y) + 0.5f) * scaleY - 0.5f;

    float supportX = max(1.0f, scaleX);
    float supportY = max(1.0f, scaleY);
    int radX = min(int(ceil(2.0f * supportX)), 6);
    int radY = min(int(ceil(2.0f * supportY)), 6);

    int cx = int(floor(uxCenter));
    int cy = int(floor(uyCenter));
    int minUX = int(u.cropX);
    int maxUX = int(u.cropX + u.cropWidth) - 1;
    int minUY = int(u.cropY);
    int maxUY = int(u.cropY + u.cropHeight) - 1;

    float3 sum = float3(0.0f);
    float wSum = 0.0f;
    for (int dy = -radY; dy <= radY; ++dy) {
        int uy = clamp(cy + dy, minUY, maxUY);
        float wy = lanczos2_weight((float(uy) - uyCenter) / supportY);
        if (abs(wy) < 1e-6f) continue;
        for (int dx = -radX; dx <= radX; ++dx) {
            int ux = clamp(cx + dx, minUX, maxUX);
            float wx = lanczos2_weight((float(ux) - uxCenter) / supportX);
            float w = wx * wy;
            if (abs(w) < 1e-6f) continue;
            float2 sc = upright_to_source_coord(float(ux), float(uy), u.srcWidth, u.srcHeight, u.orientation);
            uint2 iq = uint2(clamp(int(round(sc.x)), 0, int(u.srcWidth) - 1),
                             clamp(int(round(sc.y)), 0, int(u.srcHeight) - 1));
            sum += float3(inTex.read(iq).rgb) * w;
            wSum += w;
        }
    }
    float3 res = wSum > 1e-6f ? (sum / wSum) : float3(0.0f);
    outTex.write(half4(half3(max(res, float3(0.0f))), 1.0h), gid);
}

// MARK: - Pass 4: Midtone-Locked Dual-Branch Tone Mapping & OKLab Soft Gamut Mapping

struct ToneMapGamutUniforms {
    float midtoneAnchorP;
    float targetHeadroomStops;
    uint sdrToneMapper; // 0=agx, 1=neutralRational, 2=openDRT
    uint isSRGBBase;
    float sdrExposureLinear;
    float sdrHighlightCompression;
    float sdrContrast;
    float sdrSaturation;
    float hdrHighlightExcitation;
    float hdrRolloffSoftness;
    float pad0;
    float pad1;
};

inline float rational_shoulder(float x, float P, float Lmax, float p) {
    if (x <= P || Lmax <= P + 1e-5f) {
        return min(x, Lmax);
    }
    float span = Lmax - P;
    float u = (x - P) / span;
    float denom = pow(1.0f + pow(max(u, 0.0f), p), 1.0f / p);
    return P + span * (u / denom);
}

inline float hdr_rational_shoulder(float x, float P, float Lmax, float excite, float p) {
    if (x <= P || Lmax <= P + 1e-5f) {
        return min(x, Lmax);
    }
    float span = Lmax - P;
    float u = (x - P) / span;
    float uEff = u * (1.0f + (excite - 1.0f) * (u / (1.0f + u)));
    uEff = max(uEff, 0.0f);
    float denom = pow(1.0f + pow(uEff, p), 1.0f / p);
    return P + span * (uEff / denom);
}

inline float3 oklab_soft_gamut_map(float3 rgb2020, bool isSRGB, bool isSDR) {
    float3 rgbTarget = isSRGB ? (kM_2020_to_sRGB * rgb2020) : (kM_2020_to_P3 * rgb2020);
    float minC = min(rgbTarget.r, min(rgbTarget.g, rgbTarget.b));
    float maxC = max(rgbTarget.r, max(rgbTarget.g, rgbTarget.b));

    // Fast bypass preserves midtone lock bit-for-bit when well inside knee (<= 0.85 * cBound)
    if (minC >= 0.25f * max(maxC, 0.0f) && (!isSDR || maxC <= 0.85f)) {
        return max(rgbTarget, float3(0.0f));
    }

    float3 lab = rec2020_to_oklab(rgb2020);
    float L = isSDR ? clamp(lab.x, 0.0f, 1.0f) : max(lab.x, 0.0f);
    float C = length(float2(lab.y, lab.z));
    if (C < 1e-6f) {
        float l3 = L * L * L;
        return isSDR ? clamp(float3(l3), 0.0f, 1.0f) : max(float3(l3), float3(0.0f));
    }

    float cosH = lab.y / C;
    float sinH = lab.z / C;

    // Bracket and bisect along constant (L, h) for exact innermost gamut boundary C_bound
    float hi = max(C, 0.5f * max(L, 0.1f));
    for (int expand = 0; expand < 6; ++expand) {
        float3 testRGB = oklab_to_target_rgb(float3(L, hi * cosH, hi * sinH), isSRGB);
        float tMin = min(testRGB.r, min(testRGB.g, testRGB.b));
        float tMax = max(testRGB.r, max(testRGB.g, testRGB.b));
        bool ok = (tMin >= 0.0f) && (!isSDR || tMax <= 1.0f);
        if (!ok) {
            break;
        }
        hi *= 2.0f;
    }
    // Coarse forward march from 0 to hi in 32 uniform steps to isolate innermost !ok boundary
    float lo = 0.0f;
    float prevC = 0.0f;
    bool bracketed = false;
    for (int s = 1; s <= 32; ++s) {
        float currC = hi * (float(s) / 32.0f);
        float3 testRGB = oklab_to_target_rgb(float3(L, currC * cosH, currC * sinH), isSRGB);
        float tMin = min(testRGB.r, min(testRGB.g, testRGB.b));
        float tMax = max(testRGB.r, max(testRGB.g, testRGB.b));
        bool ok = (tMin >= 0.0f) && (!isSDR || tMax <= 1.0f);
        if (!ok) {
            lo = prevC;
            hi = currC;
            bracketed = true;
            break;
        }
        prevC = currC;
    }
    if (!bracketed) {
        lo = hi;
    } else {
        for (int iter = 0; iter < 12; ++iter) {
            float mid = 0.5f * (lo + hi);
            float3 testRGB = oklab_to_target_rgb(float3(L, mid * cosH, mid * sinH), isSRGB);
            float tMin = min(testRGB.r, min(testRGB.g, testRGB.b));
            float tMax = max(testRGB.r, max(testRGB.g, testRGB.b));
            bool ok = (tMin >= 0.0f) && (!isSDR || tMax <= 1.0f);
            if (ok) {
                lo = mid;
            } else {
                hi = mid;
            }
        }
    }
    float cBound = lo;
    float knee = 0.85f * cBound;
    float cOut = C;
    if (C > knee && cBound > knee + 1e-6f) {
        float span = cBound - knee;
        float d = C - knee;
        cOut = knee + span * d / (span + d);
    } else if (C > cBound) {
        cOut = cBound;
    }

    float3 outRGB = oklab_to_target_rgb(float3(L, cOut * cosH, cOut * sinH), isSRGB);
    if (!all(isfinite(outRGB))) {
        return float3(0.0f);
    }
    return isSDR ? clamp(outRGB, 0.0f, 1.0f) : max(outRGB, float3(0.0f));
}

kernel void dual_branch_tonemap_gamut_kernel(
    texture2d<half, access::read> inRec2020Tex [[texture(0)]],
    texture2d<half, access::write> sdrOutTex [[texture(1)]],
    texture2d<half, access::write> hdrOutTex [[texture(2)]],
    constant ToneMapGamutUniforms& u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= sdrOutTex.get_width() || gid.y >= sdrOutTex.get_height()) {
        return;
    }

    float3 rgb = max(float3(inRec2020Tex.read(gid).rgb), float3(0.0f));
    float P = clamp(u.midtoneAnchorP, 0.65f, 0.95f);
    bool isSRGB = (u.isSRGBBase != 0u);

    // --- SDR Branch (L_max = 1.0) ---
    float3 rgbS = rgb * u.sdrExposureLinear;
    if (abs(u.sdrContrast) > 1e-5f) {
        float power = 1.0f + u.sdrContrast * 0.005f;
        rgbS = 0.18f * pow(max(rgbS / 0.18f, float3(0.0f)), float3(power));
    }
    if (abs(u.sdrSaturation) > 1e-5f) {
        float3 labS = rec2020_to_oklab(rgbS);
        float satMul = max(1.0f + u.sdrSaturation * 0.01f, 0.0f);
        labS.y *= satMul;
        labS.z *= satMul;
        rgbS = max(oklab_to_rec2020(labS), float3(0.0f));
    }

    float pSDR = mix(1.45f, 0.70f, clamp(u.sdrHighlightCompression * 0.01f, 0.0f, 1.0f));
    float3 sdr2020;

    if (u.sdrToneMapper == 0u) { // .agx
        float3 inset = kM_AgX_Inset_2020 * rgbS;
        float3 compressed = float3(
            rational_shoulder(inset.r, P, 1.0f, pSDR),
            rational_shoulder(inset.g, P, 1.0f, pSDR),
            rational_shoulder(inset.b, P, 1.0f, pSDR)
        );
        sdr2020 = max(kM_AgX_Outset_2020 * compressed, float3(0.0f));
    } else if (u.sdrToneMapper == 1u) { // .neutralRational
        float Y = dot(rgbS, kRec2020Luma);
        float maxC = max(rgbS.r, max(rgbS.g, rgbS.b));
        if (maxC <= P) {
            sdr2020 = rgbS;
        } else {
            float3 perCh = float3(
                rational_shoulder(rgbS.r, P, 1.0f, pSDR),
                rational_shoulder(rgbS.g, P, 1.0f, pSDR),
                rational_shoulder(rgbS.b, P, 1.0f, pSDR)
            );
            float yOut = rational_shoulder(Y, P, 1.0f, pSDR);
            float3 lumaScaled = Y > 1e-6f ? (rgbS * (yOut / Y)) : float3(0.0f);
            float maxLS = max(lumaScaled.r, max(lumaScaled.g, lumaScaled.b));
            float wLuma = 0.35f * (1.0f - smoothstep(0.85f, 1.0f, maxLS));
            float3 mixed = mix(perCh, lumaScaled, wLuma);
            float desat = 0.35f * smoothstep(P, 2.5f, maxC);
            sdr2020 = mix(mixed, float3(yOut), desat);
        }
    } else { // .openDRT
        float norm = sqrt(dot(rgbS * rgbS, float3(0.30f, 0.55f, 0.15f)));
        if (norm <= P) {
            sdr2020 = rgbS;
        } else {
            float normOut = rational_shoulder(norm, P, 1.0f, pSDR);
            float3 scaled = rgbS * (normOut / max(norm, 1e-6f));
            float Y_out = dot(scaled, kRec2020Luma);
            float purity = pow(clamp((norm - P) / (norm + 0.5f), 0.0f, 1.0f), 1.5f);
            sdr2020 = mix(scaled, float3(Y_out), 0.45f * purity);
        }
    }

    // --- HDR Branch (L_max = 2^H_target) ---
    float3 sdrTarget = oklab_soft_gamut_map(sdr2020, isSRGB, true);
    float3 hdrTarget;
    if (u.targetHeadroomStops <= 0.0001f) {
        hdrTarget = sdrTarget;
    } else {
        float Lmax = exp2(u.targetHeadroomStops);
        float excite = mix(0.65f, 1.45f, clamp(u.hdrHighlightExcitation * 0.01f, 0.0f, 1.0f));
        float pHDR = mix(1.50f, 0.75f, clamp(u.hdrRolloffSoftness * 0.01f, 0.0f, 1.0f));
        float3x3 hdrInset = float3x3(
            mix(float3(1,0,0), kM_AgX_Inset_2020[0], 0.15f),
            mix(float3(0,1,0), kM_AgX_Inset_2020[1], 0.15f),
            mix(float3(0,0,1), kM_AgX_Inset_2020[2], 0.15f)
        );
        // Exact inverse of 15% inset blend (row-sum 1, invertible)
        float3 insetRGB = hdrInset * rgb;
        float3 compHDR = float3(
            hdr_rational_shoulder(insetRGB.r, P, Lmax, excite, pHDR),
            hdr_rational_shoulder(insetRGB.g, P, Lmax, excite, pHDR),
            hdr_rational_shoulder(insetRGB.b, P, Lmax, excite, pHDR)
        );
        // Invert 3x3 hdrInset analytically via inverse matrix
        float3 c0 = hdrInset[0], c1 = hdrInset[1], c2 = hdrInset[2];
        float3 r0 = cross(c1, c2);
        float3 r1 = cross(c2, c0);
        float3 r2 = cross(c0, c1);
        float det = dot(c0, r0);
        float3x3 hdrOutset = transpose(float3x3(r0, r1, r2)) * (1.0f / det);
        float3 hdr2020 = max(hdrOutset * compHDR, float3(0.0f));
        hdrTarget = oklab_soft_gamut_map(hdr2020, isSRGB, false);
    }

    sdrOutTex.write(half4(half3(sdrTarget), 1.0h), gid);
    hdrOutTex.write(half4(half3(hdrTarget), 1.0h), gid);
}

// MARK: - Pass 5B: sRGB OETF Quantization for sdrCGImage (8-bit RGBA8 / 16-bit RGBA16)

struct QuantizeOutputUniforms {
    uint width;
    uint height;
    uint is16Bit;
    uint pad0;
};

inline float srgb_oetf_scalar(float x) {
    float c = clamp(x, 0.0f, 1.0f);
    return (c <= 0.0031308f) ? (12.92f * c) : (1.055f * pow(c, 1.0f / 2.4f) - 0.055f);
}

inline float3 srgb_oetf(float3 rgb) {
    return float3(srgb_oetf_scalar(rgb.r), srgb_oetf_scalar(rgb.g), srgb_oetf_scalar(rgb.b));
}

inline float srgb_eotf_scalar(float c) {
    float v = clamp(c, 0.0f, 1.0f);
    return (v <= 0.04045f) ? (v / 12.92f) : pow((v + 0.055f) / 1.055f, 2.4f);
}

inline float3 srgb_eotf(float3 rgb) {
    return float3(srgb_eotf_scalar(rgb.r), srgb_eotf_scalar(rgb.g), srgb_eotf_scalar(rgb.b));
}

kernel void linear_to_srgb_oetf_quantize_kernel(
    texture2d<half, access::read> sdrLinearTex [[texture(0)]],
    device void* outBytes [[buffer(0)]],
    device const float* blueNoise64 [[buffer(1)]],
    constant QuantizeOutputUniforms& u [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= u.width || gid.y >= u.height) {
        return;
    }

    float3 lin = float3(sdrLinearTex.read(gid).rgb);
    float3 enc = srgb_oetf(lin);
    uint idx = (gid.y * u.width + gid.x) * 4u;

    if (u.is16Bit != 0u) {
        device ushort* dst = (device ushort*)outBytes;
        dst[idx + 0u] = ushort(clamp(round(enc.r * 65535.0f), 0.0f, 65535.0f));
        dst[idx + 1u] = ushort(clamp(round(enc.g * 65535.0f), 0.0f, 65535.0f));
        dst[idx + 2u] = ushort(clamp(round(enc.b * 65535.0f), 0.0f, 65535.0f));
        dst[idx + 3u] = 65535u;
    } else {
        device uchar* dst = (device uchar*)outBytes;
        for (uint c = 0u; c < 3u; ++c) {
            float v = enc[c];
            if (v <= 1e-6f) {
                dst[idx + c] = 0u;
            } else if (v >= 1.0f - 1e-6f) {
                dst[idx + c] = 255u;
            } else {
                uint bn1Idx = ((gid.y & 63u) << 6) | (gid.x & 63u);
                uint bn2Idx = (((gid.y + 19u + c * 41u) & 63u) << 6) | ((gid.x + 32u + c * 23u) & 63u);
                float d = blueNoise64[bn1Idx] + blueNoise64[bn2Idx] - 1.0f;
                dst[idx + c] = uchar(clamp(round(v * 255.0f + d), 0.0f, 255.0f));
            }
        }
        dst[idx + 3u] = 255u;
    }
}

kernel void srgb_eotf_to_linear_kernel(
    texture2d<half, access::read> srgbTex [[texture(0)]],
    texture2d<half, access::write> outLinearTex [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outLinearTex.get_width() || gid.y >= outLinearTex.get_height()) {
        return;
    }
    float3 c = float3(srgbTex.read(gid).rgb);
    outLinearTex.write(half4(half3(srgb_eotf(c)), 1.0h), gid);
}

// MARK: - ISO/IEC 21496-1:2025 Gain Map Synthesizer Kernels

struct GainMapLogUniforms {
    float kOffset;
    float midtoneAnchorP;
    float deadzoneScale;
    uint isSRGB;
    uint isMono;
    uint width;
    uint height;
    uint pad0;
};

struct GainMapMinMaxUniforms {
    uint channelCount;
    uint width;
    uint height;
    uint pad0;
};

struct GainMapHistUniforms {
    float4 rawMin;
    float4 rawMax;
    uint channelCount;
    uint width;
    uint height;
    uint pad0;
};

struct GainMapQuantizeUniforms {
    float4 gMin;
    float4 gMax;
    float4 gamma;
    uint isMono;
    uint width;
    uint height;
    uint enableDither;
};

kernel void downsample_linear_antihalo_2x_kernel(
    texture2d<half, access::read> inTex [[texture(0)]],
    texture2d<half, access::write> outTex [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint ow = outTex.get_width();
    uint oh = outTex.get_height();
    if (gid.x >= ow || gid.y >= oh) {
        return;
    }
    uint iw = inTex.get_width();
    uint ih = inTex.get_height();
    uint x0 = (ow >= iw) ? min(gid.x, iw - 1u) : min(gid.x * 2u, iw - 1u);
    uint x1 = (ow >= iw) ? x0 : min(gid.x * 2u + 1u, iw - 1u);
    uint y0 = (oh >= ih) ? min(gid.y, ih - 1u) : min(gid.y * 2u, ih - 1u);
    uint y1 = (oh >= ih) ? y0 : min(gid.y * 2u + 1u, ih - 1u);

    float3 s00 = max(float3(inTex.read(uint2(x0, y0)).rgb), float3(0.0f));
    float3 s10 = max(float3(inTex.read(uint2(x1, y0)).rgb), float3(0.0f));
    float3 s01 = max(float3(inTex.read(uint2(x0, y1)).rgb), float3(0.0f));
    float3 s11 = max(float3(inTex.read(uint2(x1, y1)).rgb), float3(0.0f));

    float3 avg = 0.25f * (s00 + s10 + s01 + s11);
    outTex.write(half4(half3(avg), 1.0h), gid);
}

kernel void gainmap_log_ratio_kernel(
    texture2d<half, access::read> sdrTex [[texture(0)]],
    texture2d<half, access::read> hdrTex [[texture(1)]],
    texture2d<half, access::write> logGainTex [[texture(2)]],
    constant GainMapLogUniforms& u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= u.width || gid.y >= u.height) {
        return;
    }
    float3 B = max(float3(sdrTex.read(gid).rgb), float3(0.0f));
    float3 H = max(float3(hdrTex.read(gid).rgb), float3(0.0f));
    float3 lumaCoeff = (u.isSRGB != 0u) ? kSRGBLuma : kDisplayP3Luma;
    float YB = dot(B, lumaCoeff);
    float YH = dot(H, lumaCoeff);
    float k = max(u.kOffset, 1e-6f);
    float tau = u.deadzoneScale * (1.0f - smoothstep(0.5f * u.midtoneAnchorP, u.midtoneAnchorP, max(YB, YH)));

    float3 G;
    if (u.isMono != 0u) {
        float g0 = log2((YH + k) / (YB + k));
        g0 = copysign(max(abs(g0) - tau, 0.0f), g0);
        G = float3(g0);
    } else {
        G = log2((H + float3(k)) / (B + float3(k)));
        for (int c = 0; c < 3; ++c) {
            G[c] = copysign(max(abs(G[c]) - tau, 0.0f), G[c]);
        }
    }
    logGainTex.write(half4(half3(G), 1.0h), gid);
}

kernel void gainmap_minmax_reduce_kernel(
    texture2d<half, access::read> logGainTex [[texture(0)]],
    device float* outGroupMinMax [[buffer(0)]], // per group: [min0,min1,min2,min3,max0,max1,max2,max3]
    constant GainMapMinMaxUniforms& u [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 tid [[thread_position_in_threadgroup]],
    uint2 tgid [[threadgroup_position_in_grid]],
    uint2 tgCount [[threadgroups_per_grid]]
) {
    threadgroup float tgMin[256][3];
    threadgroup float tgMax[256][3];

    uint lid = tid.y * 16u + tid.x;
    if (gid.x < u.width && gid.y < u.height) {
        float3 v = float3(logGainTex.read(gid).rgb);
        for (int c = 0; c < 3; ++c) {
            tgMin[lid][c] = isfinite(v[c]) ? v[c] : 1e30f;
            tgMax[lid][c] = isfinite(v[c]) ? v[c] : -1e30f;
        }
    } else {
        for (int c = 0; c < 3; ++c) {
            tgMin[lid][c] = 1e30f;
            tgMax[lid][c] = -1e30f;
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint stride = 128u; stride > 0u; stride >>= 1u) {
        if (lid < stride) {
            for (int c = 0; c < 3; ++c) {
                tgMin[lid][c] = min(tgMin[lid][c], tgMin[lid + stride][c]);
                tgMax[lid][c] = max(tgMax[lid][c], tgMax[lid + stride][c]);
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    if (lid == 0u) {
        uint gIdx = tgid.y * tgCount.x + tgid.x;
        uint base = gIdx * 8u;
        for (int c = 0; c < 3; ++c) {
            outGroupMinMax[base + uint(c)] = tgMin[0][c];
            outGroupMinMax[base + 4u + uint(c)] = tgMax[0][c];
        }
        outGroupMinMax[base + 3u] = 0.0f;
        outGroupMinMax[base + 7u] = 0.0f;
    }
}

kernel void gainmap_histogram_kernel(
    texture2d<half, access::read> logGainTex [[texture(0)]],
    device atomic_uint* histBuf [[buffer(0)]], // 4096 * 3
    constant GainMapHistUniforms& u [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= u.width || gid.y >= u.height) {
        return;
    }
    float3 G = float3(logGainTex.read(gid).rgb);
    for (uint c = 0u; c < u.channelCount; ++c) {
        float span = u.rawMax[c] - u.rawMin[c];
        if (span >= 1e-5f) {
            float t = clamp((G[c] - u.rawMin[c]) / span, 0.0f, 1.0f);
            uint bin = min(uint(floor(t * 4095.999f)), 4095u);
            atomic_fetch_add_explicit(&histBuf[c * 4096u + bin], 1u, memory_order_relaxed);
        }
    }
}

kernel void gainmap_quantize_dither_kernel(
    texture2d<half, access::read> logGainTex [[texture(0)]],
    device uchar* outBytes [[buffer(0)]],
    device const float* blueNoise64 [[buffer(1)]],
    constant GainMapQuantizeUniforms& u [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= u.width || gid.y >= u.height) {
        return;
    }
    float3 G = float3(logGainTex.read(gid).rgb);
    uchar q[3] = { 0u, 0u, 0u };
    uint chCount = (u.isMono != 0u) ? 1u : 3u;

    for (uint c = 0u; c < chCount; ++c) {
        float span = u.gMax[c] - u.gMin[c];
        if (span < 1e-5f) {
            q[c] = 0u;
            continue;
        }
        float mLin = clamp((G[c] - u.gMin[c]) / span, 0.0f, 1.0f);
        float mEnc = pow(mLin, u.gamma[c]);
        if (mEnc <= 1e-6f) {
            q[c] = 0u;
        } else if (mEnc >= 1.0f - 1e-6f) {
            q[c] = 255u;
        } else {
            float d = 0.0f;
            float code = 255.0f * mEnc;
            if (u.enableDither != 0u && abs(code - round(code)) >= 1e-3f) {
                uint bn1Idx = ((gid.y & 63u) << 6) | (gid.x & 63u);
                uint bn2Idx = (((gid.y + 19u + c * 41u) & 63u) << 6) | ((gid.x + 32u + c * 23u) & 63u);
                if (code < 1.0f || code > 254.0f) {
                    d = blueNoise64[bn1Idx] - 0.5f;
                } else {
                    d = blueNoise64[bn1Idx] + blueNoise64[bn2Idx] - 1.0f;
                }
            }
            q[c] = uchar(clamp(round(code + d), 0.0f, 255.0f));
        }
    }

    uint pxIdx = gid.y * u.width + gid.x;
    if (u.isMono != 0u) {
        outBytes[pxIdx] = q[0]; // L008
    } else {
        uint off = pxIdx * 4u;
        // BGRA8 layout: [B, G, R, 255] matching Apple ImageIO 'BGRA' and CLibAVIFBridge HDR_AVIF_PIXFMT_BGRA8
        outBytes[off + 0u] = q[2];
        outBytes[off + 1u] = q[1];
        outBytes[off + 2u] = q[0];
        outBytes[off + 3u] = 255u;
    }
}

// MARK: - HLG Video Shader: Extended Linear Display P3 -> BT.2020 NCL 10-bit 4:2:0 Video Range ('x420')

inline float hlg_diffuse_white_rolloff(float v) {
    // E_w = 0.26496256 maps 1.0 diffuse white to exact 75.00% HLG OETF
    constexpr float Ew = 0.26496256f;
    if (isnan(v)) {
        return 0.0f;
    }
    if (isinf(v) || v > 65000.0f) {
        return v > 0.0f ? 1.0f : 0.0f;
    }
    if (v <= 1.0f) {
        return max(v, 0.0f) * Ew;
    }
    float dv = (v - 1.0f) * Ew;
    float s = 1.0f - Ew;
    return Ew + (s * dv) / (s + dv);
}

inline float hlg_oetf(float e) {
    constexpr float a = 0.17883277f;
    constexpr float b = 0.28466892f;
    constexpr float c = 0.55991073f;
    float ec = clamp(e, 0.0f, 1.0f);
    if (ec <= (1.0f / 12.0f)) {
        return sqrt(3.0f * ec);
    }
    return a * log(12.0f * ec - b) + c;
}

struct HLGConvertUniforms {
    uint isSRGBBase;
    uint pad0;
    uint pad1;
    uint pad2;
};

kernel void hlg_p3_to_bt2020_420x10_kernel(
    texture2d<half, access::sample> hdrP3Tex [[texture(0)]],
    texture2d<ushort, access::write> outYPlane [[texture(1)]],
    texture2d<ushort, access::write> outCbCrPlane [[texture(2)]],
    constant HLGConvertUniforms& u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint uvW = outCbCrPlane.get_width();
    uint uvH = outCbCrPlane.get_height();
    if (gid.x >= uvW || gid.y >= uvH) {
        return;
    }

    uint outW = outYPlane.get_width();
    uint outH = outYPlane.get_height();
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);

    float cbSum = 0.0f;
    float crSum = 0.0f;
    uint count = 0u;

    for (uint dy = 0u; dy < 2u; ++dy) {
        for (uint dx = 0u; dx < 2u; ++dx) {
            uint px = gid.x * 2u + dx;
            uint py = gid.y * 2u + dy;
            if (px >= outW || py >= outH) continue;

            float2 uv = float2((float(px) + 0.5f) / float(outW), (float(py) + 0.5f) / float(outH));
            float3 rawP3 = float3(hdrP3Tex.sample(s, uv).rgb);
            float3 p3 = select(
                min(max(rawP3, float3(0.0f)), float3(65504.0f)),
                select(float3(0.0f), float3(65504.0f), rawP3 > float3(0.0f)),
                isinf(rawP3)
            );
            p3 = select(p3, float3(0.0f), isnan(rawP3));
            float3x3 to2020 = (u.isSRGBBase != 0u) ? kM_sRGB_to_2020 : kM_P3_to_2020;
            float3 bt2020 = max(to2020 * p3, float3(0.0f));

            float3 E = float3(
                hlg_diffuse_white_rolloff(bt2020.r),
                hlg_diffuse_white_rolloff(bt2020.g),
                hlg_diffuse_white_rolloff(bt2020.b)
            );
            float3 Ep = float3(hlg_oetf(E.r), hlg_oetf(E.g), hlg_oetf(E.b));

            // ITU-R BT.2020 NCL YCbCr
            float Yp = 0.2627f * Ep.r + 0.6780f * Ep.g + 0.0593f * Ep.b;
            float Cb = (Ep.b - Yp) / 1.8814f;
            float Cr = (Ep.r - Yp) / 1.4746f;

            uint Y10 = uint(clamp(round(64.0f + 876.0f * Yp), 64.0f, 940.0f));
            outYPlane.write(ushort4(ushort((Y10 & 0x3FFu) << 6u), 0u, 0u, 0u), uint2(px, py));

            cbSum += Cb;
            crSum += Cr;
            count++;
        }
    }

    float invCount = 1.0f / max(float(count), 1.0f);
    float CbAvg = cbSum * invCount;
    float CrAvg = crSum * invCount;
    uint Cb10 = uint(clamp(round(512.0f + 896.0f * CbAvg), 64.0f, 960.0f));
    uint Cr10 = uint(clamp(round(512.0f + 896.0f * CrAvg), 64.0f, 960.0f));
    outCbCrPlane.write(ushort4(ushort((Cb10 & 0x3FFu) << 6u), ushort((Cr10 & 0x3FFu) << 6u), 0u, 0u), gid);
}

// MARK: - 120Hz EDR Preview Shaders (Shared Render + Headless Compute + Dual-Zone Histogram)

struct EDRPreviewUniforms {
    uint mode; // 0=standardEDR, 1=splitScreenSwipe, 2=falseColorHeatmap, 3=gainMapDirectView
    uint sdrExposureScaleEnabled;
    uint isMonoGainMap;
    uint isSRGBBase;

    float displayLinearHeadroom;
    float baseHeadroomStops;
    float altHeadroomStops;
    float splitPosition;

    float dividerWidthUV;
    float clipThreshold;
    float kOffset;
    float pad0;

    float4 gainMapMin;
    float4 gainMapMax;
    float4 gamma;
};

struct EDRVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex EDRVertexOut edr_preview_vertex(uint vid [[vertex_id]]) {
    const float2 pos[4] = {
        float2(-1.0f, -1.0f),
        float2( 1.0f, -1.0f),
        float2(-1.0f,  1.0f),
        float2( 1.0f,  1.0f)
    };
    const float2 uvs[4] = {
        float2(0.0f, 1.0f),
        float2(1.0f, 1.0f),
        float2(0.0f, 0.0f),
        float2(1.0f, 0.0f)
    };
    EDRVertexOut out;
    out.position = float4(pos[vid & 3u], 0.0f, 1.0f);
    out.uv = uvs[vid & 3u];
    return out;
}

inline float3 evaluate_edr_preview(
    float3 sdrLin,
    float3 gmEnc,
    constant EDRPreviewUniforms& u,
    float2 uv,
    thread float3& outEDR
) {
    float dispStops = log2(max(u.displayLinearHeadroom, 1.0f));
    float spanStops = u.altHeadroomStops - u.baseHeadroomStops;
    float W = (abs(spanStops) > 1e-5f)
        ? clamp((dispStops - u.baseHeadroomStops) / spanStops, 0.0f, 1.0f)
        : 0.0f;

    if (u.mode == 1u && uv.x < u.splitPosition) {
        W = 0.0f;
    }

    float3 gm = (u.isMonoGainMap != 0u) ? float3(gmEnc.r) : gmEnc;
    float3 G = float3(0.0f);
    for (int c = 0; c < 3; ++c) {
        float invGam = 1.0f / max(u.gamma[c], 1e-4f);
        G[c] = u.gainMapMin[c] + (u.gainMapMax[c] - u.gainMapMin[c]) * pow(clamp(gm[c], 0.0f, 1.0f), invGam);
    }

    float k = max(u.kOffset, 1e-6f);
    float3 edr = max((max(sdrLin, float3(0.0f)) + float3(k)) * exp2(W * G) - float3(k), float3(0.0f));
    outEDR = edr;

    if (u.mode == 3u) { // gainMapDirectView ('G' key)
        return srgb_eotf(gm);
    }

    if (u.mode == 2u) { // falseColorHeatmap
        float peak = max(edr.r, max(edr.g, edr.b));
        float3 lumaCoeff = (u.isSRGBBase != 0u) ? kSRGBLuma : kDisplayP3Luma;
        float Y = dot(edr, lumaCoeff);
        if (peak >= u.clipThreshold && u.displayLinearHeadroom > 1.01f) {
            return float3(1.0f, 0.08f, 0.75f); // hard-clipped magenta-crimson
        }
        float stops = log2(max(peak, 1.0f));
        if (stops <= 0.001f) {
            float g = clamp(Y * 0.45f, 0.02f, 0.45f);
            return float3(g);
        } else if (stops <= 1.0f) {
            return mix(float3(0.0f, 0.75f, 0.85f), float3(0.15f, 0.90f, 0.35f), stops);
        } else if (stops <= 2.0f) {
            return mix(float3(0.15f, 0.90f, 0.35f), float3(1.0f, 0.82f, 0.05f), stops - 1.0f);
        } else {
            return mix(float3(1.0f, 0.82f, 0.05f), float3(1.0f, 0.18f, 0.05f), clamp((stops - 2.0f) / 1.5f, 0.0f, 1.0f));
        }
    }

    float3 result = edr;
    if (u.sdrExposureScaleEnabled != 0u) {
        result *= (1.0f / max(u.displayLinearHeadroom, 1.0f));
    }
    if (u.mode == 1u && abs(uv.x - u.splitPosition) < u.dividerWidthUV) {
        result = float3(1.0f);
    }
    return result;
}

fragment half4 edr_preview_fragment(
    EDRVertexOut in [[stage_in]],
    texture2d<half, access::sample> sdrLinearTex [[texture(0)]],
    texture2d<half, access::sample> gainMapTex [[texture(1)]],
    constant EDRPreviewUniforms& u [[buffer(0)]]
) {
    constexpr sampler sLin(coord::normalized, address::clamp_to_edge, filter::linear);
    float3 sdrLin = float3(sdrLinearTex.sample(sLin, in.uv).rgb);
    float3 gmEnc = float3(gainMapTex.sample(sLin, in.uv).rgb);
    float3 edrOut = float3(0.0f);
    float3 vis = evaluate_edr_preview(sdrLin, gmEnc, u, in.uv, edrOut);
    return half4(half3(vis), 1.0h);
}

kernel void edr_preview_compute(
    texture2d<half, access::sample> sdrLinearTex [[texture(0)]],
    texture2d<half, access::sample> gainMapTex [[texture(1)]],
    texture2d<half, access::write> outTex [[texture(2)]],
    constant EDRPreviewUniforms& u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint w = outTex.get_width();
    uint h = outTex.get_height();
    if (gid.x >= w || gid.y >= h) {
        return;
    }
    constexpr sampler sLin(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = float2((float(gid.x) + 0.5f) / float(w), (float(gid.y) + 0.5f) / float(h));
    float3 sdrLin = float3(sdrLinearTex.sample(sLin, uv).rgb);
    float3 gmEnc = float3(gainMapTex.sample(sLin, uv).rgb);
    float3 edrOut = float3(0.0f);
    float3 vis = evaluate_edr_preview(sdrLin, gmEnc, u, uv, edrOut);
    outTex.write(half4(half3(vis), 1.0h), gid);
}

kernel void dual_zone_histogram_kernel(
    texture2d<half, access::sample> sdrLinearTex [[texture(0)]],
    texture2d<half, access::sample> gainMapTex [[texture(1)]],
    device atomic_uint* bins [[buffer(0)]], // 256 bins: 0..127 SDR [-6..0 EV], 128..255 HDR (0..+4 EV]
    constant EDRPreviewUniforms& u [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint w = sdrLinearTex.get_width();
    uint h = sdrLinearTex.get_height();
    if (gid.x >= w || gid.y >= h) {
        return;
    }
    constexpr sampler sLin(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = float2((float(gid.x) + 0.5f) / float(w), (float(gid.y) + 0.5f) / float(h));
    float3 sdrLin = float3(sdrLinearTex.sample(sLin, uv).rgb);
    float3 gmEnc = float3(gainMapTex.sample(sLin, uv).rgb);
    float3 edr = float3(0.0f);
    evaluate_edr_preview(sdrLin, gmEnc, u, uv, edr);

    float3 lumaCoeff = (u.isSRGBBase != 0u) ? kSRGBLuma : kDisplayP3Luma;
    float Y = max(dot(edr, lumaCoeff), 0.0f);

    uint bin;
    if (Y <= 1.0f) {
        float ev = log2(max(Y, 1.0f / 64.0f)); // [-6, 0]
        bin = uint(clamp(int(floor((ev + 6.0f) / 6.0f * 128.0f)), 0, 127));
    } else {
        float ev = log2(Y); // (0, +4]
        bin = uint(clamp(128 + int(floor(ev / 4.0f * 128.0f)), 128, 255));
    }
    atomic_fetch_add_explicit(&bins[bin], 1u, memory_order_relaxed);
}
