#ifndef CULTRAHDR_BRIDGE_H
#define CULTRAHDR_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct HDRUltraHDRBuffer {
    uint8_t *data;
    size_t size;
} HDRUltraHDRBuffer;

typedef enum HDRUltraHDRColorGamut {
    HDR_UHDR_CG_UNSPECIFIED = -1,
    HDR_UHDR_CG_BT_709 = 0,
    HDR_UHDR_CG_DISPLAY_P3 = 1,
    HDR_UHDR_CG_BT_2100 = 2
} HDRUltraHDRColorGamut;

typedef enum HDRUltraHDRDecodeOutputFormat {
    HDR_UHDR_DECODE_RGBA_8888_SRGB = 0,
    HDR_UHDR_DECODE_RGBA_HALF_FLOAT_LINEAR = 1
} HDRUltraHDRDecodeOutputFormat;

/* Mirrors uhdr_gainmap_metadata_t: boost and capacity fields are LINEAR multipliers (exp2(stops)).
 * With libultrahdr built with UHDR_WRITE_XMP=ON, use_base_cg must be non-zero (1) and all 3
 * channels of each array must be equal. hdr_capacity_max must be strictly > hdr_capacity_min >= 1.0f. */
typedef struct HDRUltraHDRGainMapMetadata {
    float max_content_boost[3];
    float min_content_boost[3];
    float gamma[3];
    float offset_sdr[3];
    float offset_hdr[3];
    float hdr_capacity_min;
    float hdr_capacity_max;
    int use_base_cg;
} HDRUltraHDRGainMapMetadata;

typedef struct HDRUltraHDREncodeInput {
    const uint8_t *base_jpeg_data;
    size_t base_jpeg_size;
    HDRUltraHDRColorGamut base_color_gamut;

    const uint8_t *gainmap_jpeg_data;
    size_t gainmap_jpeg_size;

    /* Optional clean EXIF payload ("Exif\0\0" + TIFF, or raw TIFF "II*\0"/"MM\0*").
     * Pass NULL / 0 to keep any EXIF already inside base_jpeg_data (or emit none). */
    const uint8_t *exif_data;
    size_t exif_size;

    HDRUltraHDRGainMapMetadata metadata;
} HDRUltraHDREncodeInput;

typedef struct HDRUltraHDRProbeResult {
    int is_valid;
    int base_width;
    int base_height;
    int gainmap_width;
    int gainmap_height;
    int gainmap_channels; /* 1 for grayscale, 3 for YCbCr/RGB, 0 if unknown */
    size_t exif_size;
    size_t icc_size;
    size_t base_jpeg_size;
    size_t gainmap_jpeg_size;
    HDRUltraHDRGainMapMetadata metadata;
    /* Populated only when extract_payloads != 0; otherwise {NULL, 0}. */
    HDRUltraHDRBuffer base_jpeg;
    HDRUltraHDRBuffer gainmap_jpeg;
    HDRUltraHDRBuffer exif_data;
    HDRUltraHDRBuffer icc_data;
} HDRUltraHDRProbeResult;

typedef struct HDRUltraHDRDecodedImage {
    int width;
    int height;
    HDRUltraHDRDecodeOutputFormat output_format;
    HDRUltraHDRColorGamut color_gamut;
    HDRUltraHDRBuffer pixels;          /* Tightly packed RGBA8888 (4 B/px) or RGBA16F (8 B/px) */
    int gainmap_width;
    int gainmap_height;
    int gainmap_channels;              /* 1 (Y8) or 4 (RGBA8888) */
    HDRUltraHDRBuffer gainmap_pixels;  /* Tightly packed */
    HDRUltraHDRGainMapMetadata metadata;
} HDRUltraHDRDecodedImage;

const char *hdr_ultrahdr_version(void);
void hdr_ultrahdr_free_buffer(HDRUltraHDRBuffer *buffer);
void cuhdr_free_error(char *error_message);

/* Returns 0 on success, non-zero uhdr_codec_err_t (or -1 for null args) on failure.
 * On failure, if out_error != NULL, *out_error receives a malloc'd UTF-8 message (free via cuhdr_free_error). */
int cuhdr_encode_api4(const HDRUltraHDREncodeInput *input,
                      HDRUltraHDRBuffer *out_jpeg,
                      char **out_error);

/* Probes an Ultra HDR JPEG without pixel decompression.
 * If extract_payloads != 0, copies base_jpeg, gainmap_jpeg, exif_data, icc_data into owned buffers. */
int cuhdr_probe(const uint8_t *jpeg_data,
                size_t jpeg_size,
                int extract_payloads,
                HDRUltraHDRProbeResult *out_probe,
                char **out_error);

void cuhdr_free_probe_result(HDRUltraHDRProbeResult *probe);

/* Decodes an Ultra HDR JPEG (pixels + gainmap + metadata) for verification/roundtrip tests.
 * Pass max_display_boost < 1.0f (e.g. 0.0f) to use default display boost. */
int cuhdr_decode(const uint8_t *jpeg_data,
                 size_t jpeg_size,
                 HDRUltraHDRDecodeOutputFormat output_format,
                 float max_display_boost,
                 HDRUltraHDRDecodedImage *out_image,
                 char **out_error);

void cuhdr_free_decoded_image(HDRUltraHDRDecodedImage *image);

#ifdef __cplusplus
}
#endif

#endif /* CULTRAHDR_BRIDGE_H */
