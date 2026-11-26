#ifndef CLIBRAW_BRIDGE_H
#define CLIBRAW_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum HDRLibRawStatus {
    HDR_LIBRAW_OK = 0,
    HDR_LIBRAW_ERR_INVALID_ARG = -1,
    HDR_LIBRAW_ERR_OPEN = -2,
    HDR_LIBRAW_ERR_UNPACK = -3,
    HDR_LIBRAW_ERR_PROCESS = -4,
    HDR_LIBRAW_ERR_MEMORY = -5,
    HDR_LIBRAW_ERR_UNSUPPORTED = -6,
    HDR_LIBRAW_ERR_INTERNAL = -7
} HDRLibRawStatus;

typedef enum HDRLibRawDecodeMode {
    HDR_LIBRAW_MODE_BAYER_OR_SRAW = 0,  /* 16-bit cropped Bayer if CFA; falls back to RGB16U for sRAW/YCC */
    HDR_LIBRAW_MODE_LINEAR_RGB16  = 1,  /* Full-res 16-bit linear RGB (dcraw_process, unclipped) */
    HDR_LIBRAW_MODE_PROXY_RGB16   = 2   /* Half-size 16-bit linear RGB (dcraw_process, half_size=1) */
} HDRLibRawDecodeMode;

typedef enum HDRLibRawPayloadKind {
    HDR_LIBRAW_PAYLOAD_NONE     = 0,
    HDR_LIBRAW_PAYLOAD_BAYER16U = 1,    /* 1 channel uint16_t, width * height */
    HDR_LIBRAW_PAYLOAD_RGB16U   = 2     /* 3 channels interleaved RGB uint16_t, width * height * 3 */
} HDRLibRawPayloadKind;

typedef enum HDRLibRawColorSpace {
    HDR_LIBRAW_CS_CAMERA_NATIVE = 0,    /* output_color = 0 */
    HDR_LIBRAW_CS_LINEAR_REC2020 = 1    /* output_color = 8 */
} HDRLibRawColorSpace;

typedef enum HDRLibRawCFAPattern {
    HDR_LIBRAW_CFA_UNKNOWN = 0,
    HDR_LIBRAW_CFA_RGGB    = 1,
    HDR_LIBRAW_CFA_BGGR    = 2,
    HDR_LIBRAW_CFA_GRBG    = 3,
    HDR_LIBRAW_CFA_GBRG    = 4
} HDRLibRawCFAPattern;

typedef enum HDRLibRawDemosaicAlgorithm {
    HDR_LIBRAW_DEMOSAIC_NONE  = -1,
    HDR_LIBRAW_DEMOSAIC_AMAZE = 0,
    HDR_LIBRAW_DEMOSAIC_LMMSE = 1,
    HDR_LIBRAW_DEMOSAIC_DCB   = 2,
    HDR_LIBRAW_DEMOSAIC_DHT   = 3,
    HDR_LIBRAW_DEMOSAIC_AHD   = 4
} HDRLibRawDemosaicAlgorithm;

typedef struct HDRLibRawEmbeddedSonyOptics {
    int32_t has_optics;
    int32_t distortion_node_count;          /* 0..16 */
    int16_t distortion_params[16];
    int32_t ca_node_count;                  /* 0..16 */
    int16_t ca_red_params[16];
    int16_t ca_blue_params[16];
    int32_t vignetting_node_count;          /* 0..16 */
    int16_t vignetting_params[16];
} HDRLibRawEmbeddedSonyOptics;

typedef struct HDRLibRawDecodeOptions {
    HDRLibRawDecodeMode mode;
    HDRLibRawColorSpace output_color_space; /* Used for LINEAR_RGB16 / PROXY_RGB16 / sRAW fallback */
    int highlight_mode;                     /* 1 = unclip (default), 2 = blend, 5 = rebuild */
    int max_threads;                        /* Capped [1..8]; LibRaw 0.22.3 built --disable-openmp */
    int apply_inset_crop;                   /* 1 = call adjust_to_raw_inset_crop(1, 0.55f) (default 1) */
    int sraw_no_rgb;                        /* 0 = default YCC->RGB; 1 = LIBRAW_RAWSPECIAL_SRAW_NO_RGB */
    HDRLibRawDemosaicAlgorithm demosaic_algorithm; /* Full Bayer demosaic: AMAZE (default), LMMSE, DCB, DHT, AHD */
} HDRLibRawDecodeOptions;

/* Pure Exif 2.32 whitelist — NEVER contains MakerNote (0x927C) */
typedef struct HDRLibRawExifMetadata {
    char *make;
    char *model;
    char *lens_make;
    char *lens_model;
    double focal_length_mm;                 /* <= 0 if absent */
    int32_t focal_length_35mm;              /* <= 0 if absent */
    double exposure_time_sec;               /* <= 0 if absent */
    double f_number;                        /* <= 0 if absent */
    int32_t iso_speed;                      /* <= 0 if absent */
    double exposure_bias_ev;
    int32_t has_exposure_bias;
    char *date_time_original;
    char *offset_time_original;
    char *subsec_time_original;
    int32_t has_gps;
    double gps_latitude;
    char *gps_latitude_ref;
    double gps_longitude;
    char *gps_longitude_ref;
    double gps_altitude;
    int32_t has_gps_altitude;
    int32_t gps_altitude_ref;
    char *gps_timestamp;
    char *gps_date_stamp;
    int32_t orientation;                    /* Standard EXIF 1..8 */
} HDRLibRawExifMetadata;

typedef struct HDRLibRawImage {
    uint16_t *rgb16_data;                   /* Interleaved RGB16U or 1ch Bayer16U (name preserved for M1 compat) */
    size_t data_bytes;                      /* Exact byte count of rgb16_data */
    HDRLibRawPayloadKind payload_kind;
    HDRLibRawColorSpace color_space;
    HDRLibRawCFAPattern cfa_pattern;
    int32_t bits_per_sample;                /* e.g. 14 for ARW raw_bps, 16 for processed RGB16U */

    int32_t width;                          /* Visible/cropped width */
    int32_t height;                         /* Visible/cropped height */
    int32_t raw_width;                      /* Full sensor raw_width */
    int32_t raw_height;                     /* Full sensor raw_height */
    int32_t crop_left;                      /* Visible crop X in sensor coords */
    int32_t crop_top;                       /* Visible crop Y in sensor coords */

    int32_t orientation;                    /* Standard EXIF Orientation 1..8 (mapped from sizes.flip) */
    int32_t is_lossless_ms;                 /* 1 if is_sraw() (Sony YCC M/S), else 0 */
    int32_t as_shot_wb_applied;             /* imgdata.color.as_shot_wb_applied != 0 */

    float cam_mul[4];                       /* [R, G1, B, G2] */
    float pre_mul[4];                       /* Daylight/fallback multipliers */
    float cam_xyz[12];                      /* 4x3 row-major */
    float rgb_cam[12];                      /* 3x4 row-major */
    float forward_matrix[9];                /* DNG ForwardMatrix1 (3x3 row-major) */
    int32_t has_forward_matrix;

    uint32_t black_level[4];                /* Per-channel black + cblack[0..3] */
    uint32_t white_level;                   /* imgdata.color.maximum */

    HDRLibRawDemosaicAlgorithm demosaic_used;
    HDRLibRawEmbeddedSonyOptics embedded_sony_optics;
    int32_t camera_format;                  /* imgdata.lens.makernotes.CameraFormat */

    HDRLibRawExifMetadata exif;
    int32_t error_code;                     /* HDRLibRawStatus or LibRaw error code */
    char error_message[256];
} HDRLibRawImage;

const char *hdr_libraw_version(void);
HDRLibRawDecodeOptions hdr_libraw_default_options(void);
HDRLibRawStatus hdr_libraw_decode_file(const char *path,
                                       const HDRLibRawDecodeOptions *options,
                                       HDRLibRawImage *out_image);
HDRLibRawStatus hdr_libraw_decode_buffer(const void *buffer,
                                         size_t length,
                                         const HDRLibRawDecodeOptions *options,
                                         HDRLibRawImage *out_image);
void hdr_libraw_free_image(HDRLibRawImage *image);
void clraw_free_image(HDRLibRawImage *image);

#ifdef __cplusplus
}
#endif

#endif /* CLIBRAW_BRIDGE_H */
