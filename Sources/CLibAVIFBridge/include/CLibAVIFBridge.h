#ifndef CLIBAVIF_BRIDGE_H
#define CLIBAVIF_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum HDRAVIFStatus {
    HDR_AVIF_OK = 0,
    HDR_AVIF_ERR_INVALID_ARGUMENT = 1,
    HDR_AVIF_ERR_INVALID_DIMENSIONS = 2,
    HDR_AVIF_ERR_REFORMAT_FAILED = 3,
    HDR_AVIF_ERR_GRID_FAILED = 4,
    HDR_AVIF_ERR_ENCODE_FAILED = 5,
    HDR_AVIF_ERR_DECODE_FAILED = 6,
    HDR_AVIF_ERR_OUT_OF_MEMORY = 7
} HDRAVIFStatus;

typedef enum HDRAVIFCodec {
    HDR_AVIF_CODEC_SVT = 0,
    HDR_AVIF_CODEC_AOM = 1
} HDRAVIFCodec;

typedef enum HDRAVIFPixelFormat {
    HDR_AVIF_PIXFMT_RGBA8 = 0,          /* 4x uint8_t  [0..255]   */
    HDR_AVIF_PIXFMT_BGRA8 = 1,          /* 4x uint8_t  [0..255]   */
    HDR_AVIF_PIXFMT_RGBA16 = 2,         /* 4x uint16_t [0..65535] */
    HDR_AVIF_PIXFMT_BGRA16 = 3,         /* 4x uint16_t [0..65535] */
    HDR_AVIF_PIXFMT_RGBA10_U16 = 4,     /* 4x uint16_t [0..1023]  */
    HDR_AVIF_PIXFMT_GRAY8 = 5           /* 1x uint8_t  [0..255]   */
} HDRAVIFPixelFormat;

typedef enum HDRAVIFColorPrimaries {
    HDR_AVIF_PRIMARIES_BT709_SRGB = 1,
    HDR_AVIF_PRIMARIES_DISPLAY_P3 = 12
} HDRAVIFColorPrimaries;

typedef struct HDRAVIFGridPlan {
    int use_grid;
    uint32_t cols;
    uint32_t rows;
    uint32_t base_tile_width;
    uint32_t base_tile_height;
    uint32_t base_last_width;
    uint32_t base_last_height;
    uint32_t gm_tile_width;
    uint32_t gm_tile_height;
    uint32_t gm_last_width;
    uint32_t gm_last_height;
} HDRAVIFGridPlan;

typedef struct HDRAVIFGainMapMetadata {
    /* Arrays of 3 values (if 1ch mono, replicate channel 0 across [0..2]). */
    double gain_map_min[3];
    double gain_map_max[3];
    double gain_map_gamma[3];
    double base_offset[3];
    double alternate_offset[3];
    double base_hdr_headroom_stops;
    double alternate_hdr_headroom_stops;
    int use_base_color_space;           /* 1 = true (default), 0 = false */
} HDRAVIFGainMapMetadata;

typedef struct HDRAVIFEncodeRequest {
    /* Base image pixels (already physically upright, Orientation=1) */
    const uint8_t *base_pixels;
    uint32_t base_width;
    uint32_t base_height;
    uint32_t base_row_bytes;
    HDRAVIFPixelFormat base_pixel_format;
    uint32_t target_bit_depth;          /* 8 or 10 */
    HDRAVIFColorPrimaries color_primaries; /* 12 (P3) or 1 (sRGB) */

    /* Optional gain map (set gain_map_pixels = NULL to encode SDR-only AVIF) */
    const uint8_t *gain_map_pixels;
    uint32_t gain_map_width;
    uint32_t gain_map_height;
    uint32_t gain_map_row_bytes;
    HDRAVIFPixelFormat gain_map_pixel_format; /* GRAY8 (1ch) or BGRA8/RGBA8 (3ch) */
    uint32_t gain_map_channels;         /* 1 -> YUV400 (auto-uses AOM), 3 -> YUV420 */
    HDRAVIFGainMapMetadata gain_map_meta;

    /* Optional ICC & Exif (raw TIFF or Exif\0\0TIFF; Orientation=1) */
    const uint8_t *icc_data;
    size_t icc_size;
    const uint8_t *exif_data;
    size_t exif_size;

    /* Encoder settings */
    HDRAVIFCodec codec;
    int quality;                        /* 0..100 (e.g. 80) */
    int gain_map_quality;               /* 0..100, or < 0 to match quality */
    int speed;                          /* 0..10, or < 0 for default (6) */
    int max_threads;                    /* <= 0 defaults to 4 */
    int enable_tune_iq;                 /* 1 = set tune=3 (SVT) / tune=iq (AOM) */
} HDRAVIFEncodeRequest;

typedef struct HDRAVIFBuffer {
    uint8_t *data;
    size_t size;
    int used_grid_tiling;
    int grid_rows;
    int grid_columns;
    HDRAVIFCodec actual_codec;
} HDRAVIFBuffer;

const char *hdr_libavif_version(void);
void hdr_libavif_codec_versions(char *out_buffer, size_t buffer_size);

HDRAVIFStatus hdr_avif_plan_grid(
    uint32_t base_width,
    uint32_t base_height,
    uint32_t gm_width,
    uint32_t gm_height,
    uint32_t gm_channels,
    HDRAVIFGridPlan *out_plan,
    char *out_error,
    size_t error_capacity
);

HDRAVIFStatus hdr_avif_encode(
    const HDRAVIFEncodeRequest *request,
    HDRAVIFBuffer *out_buffer,
    char *out_error,
    size_t error_capacity
);

void hdr_libavif_free_buffer(HDRAVIFBuffer *buffer);

#ifdef __cplusplus
}
#endif

#endif /* CLIBAVIF_BRIDGE_H */
