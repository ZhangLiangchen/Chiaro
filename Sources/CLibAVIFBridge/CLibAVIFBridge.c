#include "CLibAVIFBridge.h"
#include <avif/avif.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define HDR_AVIF_MAX_CELL_DIM 4096U
#define HDR_AVIF_MAX_CELL_AREA 8912896ULL

static void set_errorf(char *out_error, size_t error_capacity, const char *fmt, ...) {
    if (!out_error || error_capacity == 0) {
        return;
    }
    if (!fmt) {
        out_error[0] = '\0';
        return;
    }
    va_list args;
    va_start(args, fmt);
    vsnprintf(out_error, error_capacity, fmt, args);
    va_end(args);
}

static void set_error(char *out_error, size_t error_capacity, const char *msg) {
    if (!out_error || error_capacity == 0) {
        return;
    }
    if (!msg) {
        out_error[0] = '\0';
        return;
    }
    set_errorf(out_error, error_capacity, "%s", msg);
}

static int clamp_int(int v, int lo, int hi) {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

static int lookup_canonical_grid(uint32_t w, uint32_t h, uint32_t *out_cols, uint32_t *out_rows) {
    struct CanonicalEntry {
        uint32_t w;
        uint32_t h;
        uint32_t cols;
        uint32_t rows;
    };
    static const struct CanonicalEntry kTable[] = {
        {6000U, 4000U, 2U, 2U},
        {4000U, 6000U, 2U, 2U},
        {7008U, 4672U, 4U, 2U},
        {4672U, 7008U, 2U, 4U},
        {7952U, 5304U, 4U, 2U},
        {5304U, 7952U, 2U, 4U},
        {9504U, 6336U, 4U, 3U},
        {6336U, 9504U, 3U, 4U}
    };
    for (size_t i = 0; i < sizeof(kTable) / sizeof(kTable[0]); ++i) {
        if (kTable[i].w == w && kTable[i].h == h) {
            *out_cols = kTable[i].cols;
            *out_rows = kTable[i].rows;
            return 1;
        }
    }
    return 0;
}

static int solve_axis_for_count(uint32_t dim,
                                uint32_t count,
                                int half_gm,
                                int gm_yuv420,
                                uint32_t *out_tile,
                                uint32_t *out_last) {
    if (count == 0) {
        return 0;
    }
    uint32_t min_cell = half_gm ? 128U : 64U;
    if (count == 1U) {
        if (dim < min_cell || dim > HDR_AVIF_MAX_CELL_DIM) {
            return 0;
        }
        if (half_gm && gm_yuv420 && ((dim / 2U) % 2U != 0U)) {
            return 0;
        }
        *out_tile = dim;
        *out_last = dim;
        return 1;
    }

    static const uint32_t kAlignsHalfYuv420[3] = {64U, 16U, 4U};
    static const uint32_t kAlignsDefault[3] = {64U, 16U, 2U};
    const uint32_t *aligns = (half_gm && gm_yuv420) ? kAlignsHalfYuv420 : kAlignsDefault;

    uint32_t min_tile = (dim + count - 1U) / count;
    for (int i = 0; i < 3; ++i) {
        uint32_t align = aligns[i];
        uint32_t tile = ((min_tile + align - 1U) / align) * align;
        if (tile > HDR_AVIF_MAX_CELL_DIM || tile < min_cell) {
            continue;
        }
        if ((uint64_t)(count - 1U) * (uint64_t)tile >= (uint64_t)dim) {
            continue;
        }
        uint32_t last = dim - (count - 1U) * tile;
        if (last < min_cell || last > tile || (last % 2U) != 0U) {
            continue;
        }
        if (half_gm) {
            uint32_t gm_tile = tile / 2U;
            uint32_t gm_last = last / 2U;
            if (gm_tile < 64U || gm_last < 64U) {
                continue;
            }
            if (gm_yuv420 && (((gm_tile % 2U) != 0U) || ((gm_last % 2U) != 0U))) {
                continue;
            }
        }
        *out_tile = tile;
        *out_last = last;
        return 1;
    }
    return 0;
}

static int solve_axis(uint32_t dim,
                      uint32_t initial_count,
                      int half_gm,
                      int gm_yuv420,
                      uint32_t *out_count,
                      uint32_t *out_tile,
                      uint32_t *out_last) {
    uint32_t count = initial_count < 1U ? 1U : initial_count;
    while (count >= 1U) {
        if (solve_axis_for_count(dim, count, half_gm, gm_yuv420, out_tile, out_last)) {
            *out_count = count;
            return 1;
        }
        if (count == 1U) {
            break;
        }
        count--;
    }
    return 0;
}

const char *hdr_libavif_version(void) {
    return avifVersion();
}

void hdr_libavif_codec_versions(char *out_buffer, size_t buffer_size) {
    if (!out_buffer || buffer_size == 0) {
        return;
    }
    char tmp[256];
    avifCodecVersions(tmp);
    tmp[sizeof(tmp) - 1] = '\0';
    snprintf(out_buffer, buffer_size, "%s", tmp);
}

HDRAVIFStatus hdr_avif_plan_grid(
    uint32_t base_width,
    uint32_t base_height,
    uint32_t gm_width,
    uint32_t gm_height,
    uint32_t gm_channels,
    HDRAVIFGridPlan *out_plan,
    char *out_error,
    size_t error_capacity
) {
    if (out_error && error_capacity > 0) {
        out_error[0] = '\0';
    }
    if (!out_plan) {
        set_error(out_error, error_capacity, "out_plan is NULL");
        return HDR_AVIF_ERR_INVALID_ARGUMENT;
    }
    memset(out_plan, 0, sizeof(*out_plan));

    if (base_width == 0U || base_height == 0U) {
        set_error(out_error, error_capacity, "Base image dimensions must be > 0");
        return HDR_AVIF_ERR_INVALID_DIMENSIONS;
    }

    int has_gm = (gm_width > 0U || gm_height > 0U) ? 1 : 0;
    int half_gm = 0;
    int gm_yuv420 = 0;

    if (has_gm) {
        if (gm_width == 0U || gm_height == 0U) {
            set_error(out_error, error_capacity, "Both gain map width and height must be > 0");
            return HDR_AVIF_ERR_INVALID_DIMENSIONS;
        }
        if (gm_channels != 1U && gm_channels != 3U) {
            set_error(out_error, error_capacity, "Gain map channels must be 1 or 3");
            return HDR_AVIF_ERR_INVALID_ARGUMENT;
        }
        gm_yuv420 = (gm_channels == 3U) ? 1 : 0;

        int is_full = (gm_width == base_width && gm_height == base_height) ? 1 : 0;
        int is_half = ((uint64_t)gm_width * 2ULL == (uint64_t)base_width &&
                       (uint64_t)gm_height * 2ULL == (uint64_t)base_height) ? 1 : 0;
        if (!is_full && !is_half) {
            set_error(out_error, error_capacity, "Gain map dimensions must be 1x or 0.5x of base dimensions");
            return HDR_AVIF_ERR_INVALID_DIMENSIONS;
        }
        half_gm = is_half;
    }

    uint64_t area = (uint64_t)base_width * (uint64_t)base_height;
    int needs_grid = (base_width > HDR_AVIF_MAX_CELL_DIM ||
                      base_height > HDR_AVIF_MAX_CELL_DIM ||
                      area > HDR_AVIF_MAX_CELL_AREA) ? 1 : 0;

    if (!needs_grid) {
        out_plan->use_grid = 0;
        out_plan->cols = 1U;
        out_plan->rows = 1U;
        out_plan->base_tile_width = base_width;
        out_plan->base_tile_height = base_height;
        out_plan->base_last_width = base_width;
        out_plan->base_last_height = base_height;
        out_plan->gm_tile_width = gm_width;
        out_plan->gm_tile_height = gm_height;
        out_plan->gm_last_width = gm_width;
        out_plan->gm_last_height = gm_height;
        return HDR_AVIF_OK;
    }

    /* MIAF Grid Tiling preconditions */
    if ((base_width % 2U) != 0U || (base_height % 2U) != 0U) {
        set_error(out_error, error_capacity, "Gridded YUV420 base image requires even width and height");
        return HDR_AVIF_ERR_INVALID_DIMENSIONS;
    }
    if (has_gm && gm_yuv420 && (((gm_width % 2U) != 0U) || ((gm_height % 2U) != 0U))) {
        set_error(out_error, error_capacity, "Gridded 3ch YUV420 gain map requires even width and height");
        return HDR_AVIF_ERR_INVALID_DIMENSIONS;
    }

    uint32_t min_base_cell = half_gm ? 128U : 64U;
    if (base_width < min_base_cell || base_height < min_base_cell) {
        set_error(out_error, error_capacity, "Gridded image dimensions are below minimum cell size");
        return HDR_AVIF_ERR_INVALID_DIMENSIONS;
    }

    uint32_t cols = 0U;
    uint32_t rows = 0U;
    uint32_t tile_w = 0U, last_w = 0U;
    uint32_t tile_h = 0U, last_h = 0U;

    uint32_t canon_cols = 0U, canon_rows = 0U;
    if (lookup_canonical_grid(base_width, base_height, &canon_cols, &canon_rows)) {
        if (solve_axis_for_count(base_width, canon_cols, half_gm, gm_yuv420, &tile_w, &last_w) &&
            solve_axis_for_count(base_height, canon_rows, half_gm, gm_yuv420, &tile_h, &last_h) &&
            ((uint64_t)tile_w * (uint64_t)tile_h <= HDR_AVIF_MAX_CELL_AREA)) {
            cols = canon_cols;
            rows = canon_rows;
        }
    }

    if (cols == 0U || rows == 0U) {
        uint32_t init_cols = (base_width + 2559U) / 2560U;
        uint32_t init_rows = (base_height + 2559U) / 2560U;
        if (!solve_axis(base_width, init_cols, half_gm, gm_yuv420, &cols, &tile_w, &last_w) ||
            !solve_axis(base_height, init_rows, half_gm, gm_yuv420, &rows, &tile_h, &last_h)) {
            set_error(out_error, error_capacity, "Unable to compute valid MIAF grid dimensions");
            return HDR_AVIF_ERR_INVALID_DIMENSIONS;
        }

        /* Ensure combined cell area <= 8,912,896 */
        while ((uint64_t)tile_w * (uint64_t)tile_h > HDR_AVIF_MAX_CELL_AREA) {
            if (tile_w >= tile_h) {
                uint32_t next_cols = cols + 1U;
                uint32_t nw = 0U, nl = 0U;
                if (!solve_axis_for_count(base_width, next_cols, half_gm, gm_yuv420, &nw, &nl)) {
                    set_error(out_error, error_capacity, "Unable to satisfy max cell pixel area on width");
                    return HDR_AVIF_ERR_INVALID_DIMENSIONS;
                }
                cols = next_cols;
                tile_w = nw;
                last_w = nl;
            } else {
                uint32_t next_rows = rows + 1U;
                uint32_t nh = 0U, nl = 0U;
                if (!solve_axis_for_count(base_height, next_rows, half_gm, gm_yuv420, &nh, &nl)) {
                    set_error(out_error, error_capacity, "Unable to satisfy max cell pixel area on height");
                    return HDR_AVIF_ERR_INVALID_DIMENSIONS;
                }
                rows = next_rows;
                tile_h = nh;
                last_h = nl;
            }
        }
    }

    out_plan->use_grid = 1;
    out_plan->cols = cols;
    out_plan->rows = rows;
    out_plan->base_tile_width = tile_w;
    out_plan->base_tile_height = tile_h;
    out_plan->base_last_width = last_w;
    out_plan->base_last_height = last_h;
    if (has_gm) {
        out_plan->gm_tile_width = half_gm ? (tile_w / 2U) : tile_w;
        out_plan->gm_tile_height = half_gm ? (tile_h / 2U) : tile_h;
        out_plan->gm_last_width = half_gm ? (last_w / 2U) : last_w;
        out_plan->gm_last_height = half_gm ? (last_h / 2U) : last_h;
    }
    return HDR_AVIF_OK;
}

static int map_base_pixel_format(HDRAVIFPixelFormat fmt, avifRGBFormat *out_rgb_fmt, uint32_t *out_depth) {
    switch (fmt) {
        case HDR_AVIF_PIXFMT_RGBA8:
            *out_rgb_fmt = AVIF_RGB_FORMAT_RGBA;
            *out_depth = 8U;
            return 1;
        case HDR_AVIF_PIXFMT_BGRA8:
            *out_rgb_fmt = AVIF_RGB_FORMAT_BGRA;
            *out_depth = 8U;
            return 1;
        case HDR_AVIF_PIXFMT_RGBA16:
            *out_rgb_fmt = AVIF_RGB_FORMAT_RGBA;
            *out_depth = 16U;
            return 1;
        case HDR_AVIF_PIXFMT_BGRA16:
            *out_rgb_fmt = AVIF_RGB_FORMAT_BGRA;
            *out_depth = 16U;
            return 1;
        case HDR_AVIF_PIXFMT_RGBA10_U16:
            *out_rgb_fmt = AVIF_RGB_FORMAT_RGBA;
            *out_depth = 10U;
            return 1;
        default:
            return 0;
    }
}

static int populate_gainmap_metadata(avifGainMap *gm,
                                      const HDRAVIFGainMapMetadata *meta,
                                      avifColorPrimaries alt_primaries,
                                      uint32_t alt_depth,
                                      char *out_error,
                                      size_t error_capacity) {
    if (!gm || !meta) {
        return 0;
    }
    for (int i = 0; i < 3; ++i) {
        if (!isfinite(meta->gain_map_min[i]) ||
            !isfinite(meta->gain_map_max[i]) ||
            !isfinite(meta->gain_map_gamma[i]) ||
            !isfinite(meta->base_offset[i]) ||
            !isfinite(meta->alternate_offset[i]) ||
            meta->gain_map_gamma[i] <= 0.0) {
            set_error(out_error, error_capacity, "Invalid gain map metadata values");
            return 0;
        }
        if (!avifDoubleToSignedFraction(meta->gain_map_min[i], &gm->gainMapMin[i]) ||
            !avifDoubleToSignedFraction(meta->gain_map_max[i], &gm->gainMapMax[i]) ||
            !avifDoubleToUnsignedFraction(meta->gain_map_gamma[i], &gm->gainMapGamma[i]) ||
            !avifDoubleToSignedFraction(meta->base_offset[i], &gm->baseOffset[i]) ||
            !avifDoubleToSignedFraction(meta->alternate_offset[i], &gm->alternateOffset[i])) {
            set_error(out_error, error_capacity, "Failed converting gain map metadata channel to fraction");
            return 0;
        }
    }
    if (!isfinite(meta->base_hdr_headroom_stops) ||
        !isfinite(meta->alternate_hdr_headroom_stops) ||
        meta->base_hdr_headroom_stops < 0.0 ||
        meta->alternate_hdr_headroom_stops < 0.0) {
        set_error(out_error, error_capacity, "Invalid HDR headroom stops in gain map metadata");
        return 0;
    }
    if (!avifDoubleToUnsignedFraction(meta->base_hdr_headroom_stops, &gm->baseHdrHeadroom) ||
        !avifDoubleToUnsignedFraction(meta->alternate_hdr_headroom_stops, &gm->alternateHdrHeadroom)) {
        set_error(out_error, error_capacity, "Failed converting HDR headroom stops to fraction");
        return 0;
    }

    gm->useBaseColorSpace = meta->use_base_color_space ? AVIF_TRUE : AVIF_FALSE;
    gm->altColorPrimaries = alt_primaries;
    gm->altTransferCharacteristics = AVIF_TRANSFER_CHARACTERISTICS_PQ;
    gm->altMatrixCoefficients = AVIF_MATRIX_COEFFICIENTS_UNSPECIFIED;
    gm->altYUVRange = AVIF_RANGE_FULL;
    gm->altDepth = alt_depth;
    gm->altPlaneCount = 3U;
    return 1;
}

static void copy_gainmap_metadata_fields(avifGainMap *dst, const avifGainMap *src) {
    for (int i = 0; i < 3; ++i) {
        dst->gainMapMin[i] = src->gainMapMin[i];
        dst->gainMapMax[i] = src->gainMapMax[i];
        dst->gainMapGamma[i] = src->gainMapGamma[i];
        dst->baseOffset[i] = src->baseOffset[i];
        dst->alternateOffset[i] = src->alternateOffset[i];
    }
    dst->baseHdrHeadroom = src->baseHdrHeadroom;
    dst->alternateHdrHeadroom = src->alternateHdrHeadroom;
    dst->useBaseColorSpace = src->useBaseColorSpace;
    dst->altColorPrimaries = src->altColorPrimaries;
    dst->altTransferCharacteristics = src->altTransferCharacteristics;
    dst->altMatrixCoefficients = src->altMatrixCoefficients;
    dst->altYUVRange = src->altYUVRange;
    dst->altDepth = src->altDepth;
    dst->altPlaneCount = src->altPlaneCount;
}

HDRAVIFStatus hdr_avif_encode(
    const HDRAVIFEncodeRequest *request,
    HDRAVIFBuffer *out_buffer,
    char *out_error,
    size_t error_capacity
) {
    if (out_error && error_capacity > 0) {
        out_error[0] = '\0';
    }
    if (!out_buffer) {
        set_error(out_error, error_capacity, "out_buffer is NULL");
        return HDR_AVIF_ERR_INVALID_ARGUMENT;
    }
    memset(out_buffer, 0, sizeof(*out_buffer));

    if (!request || !request->base_pixels) {
        set_error(out_error, error_capacity, "request or base_pixels is NULL");
        return HDR_AVIF_ERR_INVALID_ARGUMENT;
    }
    if (request->target_bit_depth != 8U && request->target_bit_depth != 10U) {
        set_error(out_error, error_capacity, "target_bit_depth must be 8 or 10");
        return HDR_AVIF_ERR_INVALID_ARGUMENT;
    }
    if (request->color_primaries != HDR_AVIF_PRIMARIES_BT709_SRGB &&
        request->color_primaries != HDR_AVIF_PRIMARIES_DISPLAY_P3) {
        set_error(out_error, error_capacity, "Unsupported color_primaries (expected 1 or 12)");
        return HDR_AVIF_ERR_INVALID_ARGUMENT;
    }
    if (request->codec != HDR_AVIF_CODEC_SVT && request->codec != HDR_AVIF_CODEC_AOM) {
        set_error(out_error, error_capacity, "Unsupported codec (expected SVT or AOM)");
        return HDR_AVIF_ERR_INVALID_ARGUMENT;
    }

    avifRGBFormat base_rgb_fmt = AVIF_RGB_FORMAT_RGBA;
    uint32_t base_rgb_depth = 8U;
    if (!map_base_pixel_format(request->base_pixel_format, &base_rgb_fmt, &base_rgb_depth)) {
        set_error(out_error, error_capacity, "Unsupported base_pixel_format");
        return HDR_AVIF_ERR_INVALID_ARGUMENT;
    }
    uint64_t min_base_row_bytes = (uint64_t)request->base_width * 4ULL * (base_rgb_depth == 8U ? 1ULL : 2ULL);
    if (min_base_row_bytes > (uint64_t)UINT32_MAX || (uint64_t)request->base_row_bytes < min_base_row_bytes) {
        set_error(out_error, error_capacity, "base_row_bytes is smaller than minimum row stride");
        return HDR_AVIF_ERR_INVALID_ARGUMENT;
    }

    int has_gm = (request->gain_map_pixels != NULL) ? 1 : 0;
    if (has_gm) {
        if (request->gain_map_width == 0U || request->gain_map_height == 0U) {
            set_error(out_error, error_capacity, "gain_map_width and gain_map_height must be > 0 when gain_map_pixels is non-NULL");
            return HDR_AVIF_ERR_INVALID_DIMENSIONS;
        }
        if (request->gain_map_channels != 1U && request->gain_map_channels != 3U) {
            set_error(out_error, error_capacity, "gain_map_channels must be 1 or 3");
            return HDR_AVIF_ERR_INVALID_ARGUMENT;
        }
        if (request->gain_map_channels == 1U && request->gain_map_pixel_format != HDR_AVIF_PIXFMT_GRAY8) {
            set_error(out_error, error_capacity, "1-channel gain map requires GRAY8 pixel format");
            return HDR_AVIF_ERR_INVALID_ARGUMENT;
        }
        if (request->gain_map_channels == 3U &&
            request->gain_map_pixel_format != HDR_AVIF_PIXFMT_BGRA8 &&
            request->gain_map_pixel_format != HDR_AVIF_PIXFMT_RGBA8) {
            set_error(out_error, error_capacity, "3-channel gain map requires BGRA8 or RGBA8 pixel format");
            return HDR_AVIF_ERR_INVALID_ARGUMENT;
        }
        uint64_t gm_bpp = (request->gain_map_pixel_format == HDR_AVIF_PIXFMT_GRAY8) ? 1ULL : 4ULL;
        uint64_t min_gm_row_bytes = (uint64_t)request->gain_map_width * gm_bpp;
        if (min_gm_row_bytes > (uint64_t)UINT32_MAX || (uint64_t)request->gain_map_row_bytes < min_gm_row_bytes) {
            set_error(out_error, error_capacity, "gain_map_row_bytes is smaller than minimum row stride");
            return HDR_AVIF_ERR_INVALID_ARGUMENT;
        }
    }

    HDRAVIFGridPlan plan;
    HDRAVIFStatus plan_status = hdr_avif_plan_grid(
        request->base_width,
        request->base_height,
        has_gm ? request->gain_map_width : 0U,
        has_gm ? request->gain_map_height : 0U,
        has_gm ? request->gain_map_channels : 0U,
        &plan,
        out_error,
        error_capacity
    );
    if (plan_status != HDR_AVIF_OK) {
        return plan_status;
    }

    HDRAVIFStatus status = HDR_AVIF_OK;
    avifImage *base = NULL;
    avifImage *gm = NULL;
    avifGainMap *gm_template = NULL;
    avifEncoder *encoder = NULL;
    avifImage **cells = NULL;
    uint32_t total_cells = 0U;
    avifRWData raw_out = AVIF_DATA_EMPTY;

    base = avifImageCreate(request->base_width,
                           request->base_height,
                           request->target_bit_depth,
                           AVIF_PIXEL_FORMAT_YUV420);
    if (!base) {
        set_error(out_error, error_capacity, "avifImageCreate failed for base image");
        status = HDR_AVIF_ERR_OUT_OF_MEMORY;
        goto cleanup;
    }

    base->yuvRange = AVIF_RANGE_FULL;
    base->colorPrimaries = (avifColorPrimaries)request->color_primaries;
    base->transferCharacteristics = AVIF_TRANSFER_CHARACTERISTICS_SRGB;
    base->matrixCoefficients = AVIF_MATRIX_COEFFICIENTS_BT601;

    avifRGBImage base_rgb;
    avifRGBImageSetDefaults(&base_rgb, base);
    base_rgb.format = base_rgb_fmt;
    base_rgb.depth = base_rgb_depth;
    base_rgb.ignoreAlpha = AVIF_TRUE;
    base_rgb.chromaDownsampling = AVIF_CHROMA_DOWNSAMPLING_BEST_QUALITY;
    base_rgb.isFloat = AVIF_FALSE;
    base_rgb.maxThreads = (request->max_threads > 0) ? request->max_threads : 4;
    base_rgb.pixels = (uint8_t *)request->base_pixels;
    base_rgb.rowBytes = request->base_row_bytes;

    avifResult res = avifImageRGBToYUV(base, &base_rgb);
    if (res != AVIF_RESULT_OK) {
        set_errorf(out_error, error_capacity, "avifImageRGBToYUV(base) failed: %s", avifResultToString(res));
        status = HDR_AVIF_ERR_REFORMAT_FAILED;
        goto cleanup;
    }

    if (has_gm) {
        avifPixelFormat gm_yuv_fmt = (request->gain_map_channels == 1U)
                                         ? AVIF_PIXEL_FORMAT_YUV400
                                         : AVIF_PIXEL_FORMAT_YUV420;
        gm = avifImageCreate(request->gain_map_width,
                             request->gain_map_height,
                             8U,
                             gm_yuv_fmt);
        if (!gm) {
            set_error(out_error, error_capacity, "avifImageCreate failed for gain map");
            status = HDR_AVIF_ERR_OUT_OF_MEMORY;
            goto cleanup;
        }
        gm->yuvRange = AVIF_RANGE_FULL;
        gm->colorPrimaries = AVIF_COLOR_PRIMARIES_UNSPECIFIED;
        gm->transferCharacteristics = AVIF_TRANSFER_CHARACTERISTICS_UNSPECIFIED;
        gm->matrixCoefficients = AVIF_MATRIX_COEFFICIENTS_BT601;

        avifRGBImage gm_rgb;
        avifRGBImageSetDefaults(&gm_rgb, gm);
        if (request->gain_map_pixel_format == HDR_AVIF_PIXFMT_GRAY8) {
            gm_rgb.format = AVIF_RGB_FORMAT_GRAY;
        } else if (request->gain_map_pixel_format == HDR_AVIF_PIXFMT_BGRA8) {
            gm_rgb.format = AVIF_RGB_FORMAT_BGRA;
        } else {
            gm_rgb.format = AVIF_RGB_FORMAT_RGBA;
        }
        gm_rgb.depth = 8U;
        gm_rgb.ignoreAlpha = AVIF_TRUE;
        gm_rgb.chromaDownsampling = AVIF_CHROMA_DOWNSAMPLING_BEST_QUALITY;
        gm_rgb.isFloat = AVIF_FALSE;
        gm_rgb.maxThreads = (request->max_threads > 0) ? request->max_threads : 4;
        gm_rgb.pixels = (uint8_t *)request->gain_map_pixels;
        gm_rgb.rowBytes = request->gain_map_row_bytes;

        res = avifImageRGBToYUV(gm, &gm_rgb);
        if (res != AVIF_RESULT_OK) {
            set_errorf(out_error, error_capacity, "avifImageRGBToYUV(gain_map) failed: %s", avifResultToString(res));
            status = HDR_AVIF_ERR_REFORMAT_FAILED;
            goto cleanup;
        }

        gm_template = avifGainMapCreate();
        if (!gm_template) {
            set_error(out_error, error_capacity, "avifGainMapCreate failed");
            status = HDR_AVIF_ERR_OUT_OF_MEMORY;
            goto cleanup;
        }
        if (!populate_gainmap_metadata(gm_template,
                                       &request->gain_map_meta,
                                       base->colorPrimaries,
                                       request->target_bit_depth,
                                       out_error,
                                       error_capacity)) {
            status = HDR_AVIF_ERR_INVALID_ARGUMENT;
            goto cleanup;
        }
    }

    encoder = avifEncoderCreate();
    if (!encoder) {
        set_error(out_error, error_capacity, "avifEncoderCreate failed");
        status = HDR_AVIF_ERR_OUT_OF_MEMORY;
        goto cleanup;
    }

    /* SVT-AV1 4.3.0 rejects YUV400; automatically switch to libaom for 1ch gain maps. */
    HDRAVIFCodec actual_codec = (has_gm && request->gain_map_channels == 1U)
                                    ? HDR_AVIF_CODEC_AOM
                                    : request->codec;
    encoder->codecChoice = (actual_codec == HDR_AVIF_CODEC_SVT)
                               ? AVIF_CODEC_CHOICE_SVT
                               : AVIF_CODEC_CHOICE_AOM;
    encoder->quality = clamp_int(request->quality, AVIF_QUALITY_WORST, AVIF_QUALITY_BEST);
    encoder->qualityGainMap = (request->gain_map_quality >= 0)
                                  ? clamp_int(request->gain_map_quality, AVIF_QUALITY_WORST, AVIF_QUALITY_BEST)
                                  : encoder->quality;
    encoder->speed = (request->speed >= 0) ? clamp_int(request->speed, 0, 10) : 6;
    encoder->maxThreads = (request->max_threads > 0) ? request->max_threads : 4;
    encoder->autoTiling = AVIF_TRUE;

    if (request->enable_tune_iq) {
        if (actual_codec == HDR_AVIF_CODEC_SVT) {
            res = avifEncoderSetCodecSpecificOption(encoder, "tune", "3");
            if (res != AVIF_RESULT_OK) {
                set_errorf(out_error, error_capacity, "avifEncoderSetCodecSpecificOption(tune=3) failed: %s",
                           avifResultToString(res));
                status = HDR_AVIF_ERR_ENCODE_FAILED;
                goto cleanup;
            }
        } else if (encoder->quality != AVIF_QUALITY_BEST &&
                   (!has_gm || encoder->qualityGainMap != AVIF_QUALITY_BEST)) {
            /* libaom rejects tune=iq when --lossless=1 (quality == AVIF_QUALITY_BEST / 100). */
            res = avifEncoderSetCodecSpecificOption(encoder, "tune", "iq");
            if (res != AVIF_RESULT_OK) {
                set_errorf(out_error, error_capacity, "avifEncoderSetCodecSpecificOption(tune=iq) failed: %s",
                           avifResultToString(res));
                status = HDR_AVIF_ERR_ENCODE_FAILED;
                goto cleanup;
            }
        }
    }

    if (!plan.use_grid) {
        if (request->icc_data && request->icc_size > 0) {
            res = avifImageSetProfileICC(base, request->icc_data, request->icc_size);
            if (res != AVIF_RESULT_OK) {
                set_errorf(out_error, error_capacity, "avifImageSetProfileICC failed: %s", avifResultToString(res));
                status = HDR_AVIF_ERR_ENCODE_FAILED;
                goto cleanup;
            }
        }
        if (request->exif_data && request->exif_size > 0) {
            res = avifImageSetMetadataExif(base, request->exif_data, request->exif_size);
            if (res != AVIF_RESULT_OK) {
                set_errorf(out_error, error_capacity, "avifImageSetMetadataExif failed: %s", avifResultToString(res));
                status = HDR_AVIF_ERR_ENCODE_FAILED;
                goto cleanup;
            }
        }
        if (has_gm) {
            base->gainMap = gm_template;
            base->gainMap->image = gm;
            gm_template = NULL;
            gm = NULL;
        }
        res = avifEncoderAddImage(encoder, base, 1, AVIF_ADD_IMAGE_FLAG_SINGLE);
        if (res != AVIF_RESULT_OK) {
            set_errorf(out_error, error_capacity, "avifEncoderAddImage failed: %s (%s)",
                       avifResultToString(res), encoder->diag.error);
            status = HDR_AVIF_ERR_ENCODE_FAILED;
            goto cleanup;
        }
    } else {
        total_cells = plan.cols * plan.rows;
        cells = (avifImage **)calloc(total_cells, sizeof(avifImage *));
        if (!cells) {
            set_error(out_error, error_capacity, "Out of memory allocating grid cell pointers");
            status = HDR_AVIF_ERR_OUT_OF_MEMORY;
            goto cleanup;
        }

        for (uint32_t r = 0; r < plan.rows; ++r) {
            for (uint32_t c = 0; c < plan.cols; ++c) {
                uint32_t idx = r * plan.cols + c;
                cells[idx] = avifImageCreateEmpty();
                if (!cells[idx]) {
                    set_error(out_error, error_capacity, "avifImageCreateEmpty failed for grid cell");
                    status = HDR_AVIF_ERR_OUT_OF_MEMORY;
                    goto cleanup;
                }

                avifCropRect base_rect;
                base_rect.x = c * plan.base_tile_width;
                base_rect.y = r * plan.base_tile_height;
                base_rect.width = (c + 1U == plan.cols) ? plan.base_last_width : plan.base_tile_width;
                base_rect.height = (r + 1U == plan.rows) ? plan.base_last_height : plan.base_tile_height;

                res = avifImageSetViewRect(cells[idx], base, &base_rect);
                if (res != AVIF_RESULT_OK) {
                    set_errorf(out_error, error_capacity, "avifImageSetViewRect(base) failed: %s",
                               avifResultToString(res));
                    status = HDR_AVIF_ERR_GRID_FAILED;
                    goto cleanup;
                }

                if (idx == 0U) {
                    if (request->icc_data && request->icc_size > 0) {
                        res = avifImageSetProfileICC(cells[0], request->icc_data, request->icc_size);
                        if (res != AVIF_RESULT_OK) {
                            set_errorf(out_error, error_capacity, "avifImageSetProfileICC(cell0) failed: %s",
                                       avifResultToString(res));
                            status = HDR_AVIF_ERR_GRID_FAILED;
                            goto cleanup;
                        }
                    }
                    if (request->exif_data && request->exif_size > 0) {
                        res = avifImageSetMetadataExif(cells[0], request->exif_data, request->exif_size);
                        if (res != AVIF_RESULT_OK) {
                            set_errorf(out_error, error_capacity, "avifImageSetMetadataExif(cell0) failed: %s",
                                       avifResultToString(res));
                            status = HDR_AVIF_ERR_GRID_FAILED;
                            goto cleanup;
                        }
                    }
                }

                if (has_gm) {
                    cells[idx]->gainMap = avifGainMapCreate();
                    if (!cells[idx]->gainMap) {
                        set_error(out_error, error_capacity, "avifGainMapCreate failed for grid cell");
                        status = HDR_AVIF_ERR_OUT_OF_MEMORY;
                        goto cleanup;
                    }
                    cells[idx]->gainMap->image = avifImageCreateEmpty();
                    if (!cells[idx]->gainMap->image) {
                        set_error(out_error, error_capacity, "avifImageCreateEmpty failed for gain map cell");
                        status = HDR_AVIF_ERR_OUT_OF_MEMORY;
                        goto cleanup;
                    }

                    avifCropRect gm_rect;
                    gm_rect.x = c * plan.gm_tile_width;
                    gm_rect.y = r * plan.gm_tile_height;
                    gm_rect.width = (c + 1U == plan.cols) ? plan.gm_last_width : plan.gm_tile_width;
                    gm_rect.height = (r + 1U == plan.rows) ? plan.gm_last_height : plan.gm_tile_height;

                    res = avifImageSetViewRect(cells[idx]->gainMap->image, gm, &gm_rect);
                    if (res != AVIF_RESULT_OK) {
                        set_errorf(out_error, error_capacity, "avifImageSetViewRect(gainMap) failed: %s",
                                   avifResultToString(res));
                        status = HDR_AVIF_ERR_GRID_FAILED;
                        goto cleanup;
                    }
                    copy_gainmap_metadata_fields(cells[idx]->gainMap, gm_template);
                }
            }
        }

        res = avifEncoderAddImageGrid(encoder,
                                      plan.cols,
                                      plan.rows,
                                      (const avifImage * const *)cells,
                                      AVIF_ADD_IMAGE_FLAG_SINGLE);
        if (res != AVIF_RESULT_OK) {
            set_errorf(out_error, error_capacity, "avifEncoderAddImageGrid failed: %s (%s)",
                       avifResultToString(res), encoder->diag.error);
            status = HDR_AVIF_ERR_ENCODE_FAILED;
            goto cleanup;
        }
    }

    res = avifEncoderFinish(encoder, &raw_out);
    if (res != AVIF_RESULT_OK || !raw_out.data || raw_out.size == 0) {
        set_errorf(out_error, error_capacity, "avifEncoderFinish failed: %s (%s)",
                   avifResultToString(res), encoder->diag.error);
        status = HDR_AVIF_ERR_ENCODE_FAILED;
        goto cleanup;
    }

    uint8_t *out_copy = (uint8_t *)malloc(raw_out.size);
    if (!out_copy) {
        set_error(out_error, error_capacity, "Out of memory copying encoded AVIF output");
        status = HDR_AVIF_ERR_OUT_OF_MEMORY;
        goto cleanup;
    }
    memcpy(out_copy, raw_out.data, raw_out.size);

    out_buffer->data = out_copy;
    out_buffer->size = raw_out.size;
    out_buffer->used_grid_tiling = plan.use_grid;
    out_buffer->grid_rows = (int)plan.rows;
    out_buffer->grid_columns = (int)plan.cols;
    out_buffer->actual_codec = actual_codec;

cleanup:
    avifRWDataFree(&raw_out);
    if (cells) {
        for (uint32_t i = 0; i < total_cells; ++i) {
            if (cells[i]) {
                avifImageDestroy(cells[i]);
            }
        }
        free(cells);
    }
    if (encoder) {
        avifEncoderDestroy(encoder);
    }
    if (gm_template) {
        avifGainMapDestroy(gm_template);
    }
    if (gm) {
        avifImageDestroy(gm);
    }
    if (base) {
        avifImageDestroy(base);
    }
    return status;
}

void hdr_libavif_free_buffer(HDRAVIFBuffer *buffer) {
    if (!buffer) {
        return;
    }
    if (buffer->data) {
        free(buffer->data);
        buffer->data = NULL;
    }
    buffer->size = 0;
    buffer->used_grid_tiling = 0;
    buffer->grid_rows = 0;
    buffer->grid_columns = 0;
    buffer->actual_codec = HDR_AVIF_CODEC_SVT;
}
