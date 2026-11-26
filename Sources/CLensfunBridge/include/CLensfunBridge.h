#ifndef CLENSFUN_BRIDGE_H
#define CLENSFUN_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ChiaroLensfunHandle ChiaroLensfunHandle;

typedef struct ChiaroLensfunLibraryInfo {
    int version_major;
    int version_minor;
    int version_micro;
    int db_camera_count;
    int db_lens_count;
    int loaded_primary_db;
    int loaded_user_db;
} ChiaroLensfunLibraryInfo;

typedef struct ChiaroLensfunMatchQuery {
    const char *camera_make;
    const char *camera_model;
    const char *lens_make;
    const char *lens_model;
    const char *camera_override;
    const char *lens_override;
    float crop_factor;
} ChiaroLensfunMatchQuery;

typedef struct ChiaroLensfunMatchResult {
    int matched;
    char camera_matched[128];
    char lens_matched[192];
    float resolved_crop_factor;
    int is_sony_e_fallback;
    int has_distortion;
    int has_tca;
    int has_vignetting;
} ChiaroLensfunMatchResult;

typedef struct ChiaroLensfunLUTParams {
    int image_width;
    int image_height;
    int lut_width;
    int lut_height;
    float focal_length_mm;
    float aperture_f_number;
    int enable_distortion;
    int enable_auto_scale;
    int enable_tca;
    int enable_vignetting;
} ChiaroLensfunLUTParams;

ChiaroLensfunHandle *chiaro_lensfun_create(const char *db_directory,
                                           const char *user_db_directory);

void chiaro_lensfun_destroy(ChiaroLensfunHandle *handle);

int chiaro_lensfun_reload_user_db(ChiaroLensfunHandle *handle,
                                  const char *user_db_directory);

int chiaro_lensfun_get_info(const ChiaroLensfunHandle *handle,
                            ChiaroLensfunLibraryInfo *out_info);

int chiaro_lensfun_match(const ChiaroLensfunHandle *handle,
                         const ChiaroLensfunMatchQuery *query,
                         ChiaroLensfunMatchResult *out_result);

int chiaro_lensfun_compute_lut(const ChiaroLensfunHandle *handle,
                               const ChiaroLensfunMatchQuery *query,
                               const ChiaroLensfunLUTParams *params,
                               float *out_warp_rgb_uv,
                               float *out_vig_gain,
                               ChiaroLensfunMatchResult *out_result);

int chiaro_lensfun_list_lenses(const ChiaroLensfunHandle *handle,
                               const char *mount_filter,
                               char ***out_names,
                               int *out_count);

void chiaro_lensfun_free_string_list(char **names, int count);

#ifdef __cplusplus
}
#endif

#endif /* CLENSFUN_BRIDGE_H */
