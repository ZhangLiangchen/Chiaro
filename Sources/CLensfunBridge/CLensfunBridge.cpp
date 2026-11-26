#include "CLensfunBridge.h"

#include <lensfun/lensfun.h>
#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <new>
#include <string>
#include <vector>

struct ChiaroLensfunHandle {
    lfDatabase *db;
    std::string primary_db_dir;
    int loaded_primary_db;
    int loaded_user_db;
    mutable std::mutex mutex;
};

namespace {

static bool is_non_empty(const char *s) {
    return s != nullptr && s[0] != '\0';
}

static bool contains_icase(const char *haystack, const char *needle) {
    if (!haystack || !needle || needle[0] == '\0') {
        return false;
    }
    std::string h(haystack);
    std::string n(needle);
    std::transform(h.begin(), h.end(), h.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    std::transform(n.begin(), n.end(), n.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return h.find(n) != std::string::npos;
}

static void copy_cstr(char *dst, size_t cap, const char *src) {
    if (!dst || cap == 0) {
        return;
    }
    if (!src) {
        dst[0] = '\0';
        return;
    }
    std::snprintf(dst, cap, "%s", src);
}

static bool should_use_sony_e_fallback(const ChiaroLensfunMatchQuery *query) {
    if (!query) {
        return false;
    }
    return contains_icase(query->camera_make, "sony") ||
           contains_icase(query->camera_model, "ilce") ||
           contains_icase(query->camera_model, "nex") ||
           contains_icase(query->camera_model, "sony") ||
           contains_icase(query->camera_override, "sony") ||
           contains_icase(query->camera_override, "ilce") ||
           contains_icase(query->lens_model, "fe ") ||
           contains_icase(query->lens_model, " e ") ||
           contains_icase(query->lens_model, "sony e") ||
           contains_icase(query->lens_override, "fe ") ||
           contains_icase(query->lens_override, " e ");
}

struct ResolvedMatchInternal {
    const lfCamera *db_camera = nullptr;
    lfCamera fallback_camera{};
    bool has_camera = false;
    bool is_sony_fallback = false;
    const lfLens *lens = nullptr;
    float effective_crop = 1.0f;
    std::string camera_label;
    std::string lens_label;
};

static ResolvedMatchInternal resolve_camera_and_lens_locked(const lfDatabase *db,
                                                            const ChiaroLensfunMatchQuery *query) {
    ResolvedMatchInternal res;
    if (!db || !query) {
        return res;
    }

    const lfCamera **cams = nullptr;
    if (is_non_empty(query->camera_override)) {
        cams = db->FindCameras(nullptr, query->camera_override);
        if (!cams || !cams[0]) {
            if (cams) lf_free(cams);
            cams = db->FindCamerasExt(nullptr, query->camera_override, LF_SEARCH_LOOSE);
        }
    } else if (is_non_empty(query->camera_model)) {
        const char *mk = is_non_empty(query->camera_make) ? query->camera_make : nullptr;
        cams = db->FindCameras(mk, query->camera_model);
        if ((!cams || !cams[0]) && !should_use_sony_e_fallback(query)) {
            if (cams) lf_free(cams);
            cams = db->FindCamerasExt(mk, query->camera_model, LF_SEARCH_LOOSE);
        }
    }

    const lfCamera *cam_ptr = nullptr;
    const bool has_camera_override = is_non_empty(query->camera_override);
    const bool wants_apsc_crop = (query->crop_factor >= 1.35f);
    if (cams && cams[0] &&
        (has_camera_override || !(wants_apsc_crop && cams[0]->CropFactor < 1.30f && should_use_sony_e_fallback(query)))) {
        res.db_camera = cams[0];
        res.has_camera = true;
        cam_ptr = cams[0];
        res.effective_crop = (cams[0]->CropFactor > 0.1f)
                                 ? cams[0]->CropFactor
                                 : (query->crop_factor > 0.1f ? query->crop_factor : 1.0f);
        const char *mk = cams[0]->Maker ? cams[0]->Maker : "";
        const char *md = cams[0]->Model ? cams[0]->Model : "";
        res.camera_label = (mk[0] != '\0') ? (std::string(mk) + " " + md) : std::string(md);
    } else if (should_use_sony_e_fallback(query)) {
        const float eff_crop = wants_apsc_crop ? 1.5f : (query->crop_factor > 0.1f ? query->crop_factor : 1.0f);
        res.fallback_camera.SetMaker("Sony");
        res.fallback_camera.SetModel(wants_apsc_crop ? "Sony E APS-C (1.5x)" : "Sony E Full-Frame (1.0x)");
        res.fallback_camera.SetMount("Sony E");
        res.fallback_camera.CropFactor = eff_crop;
        res.has_camera = true;
        res.is_sony_fallback = true;
        cam_ptr = &res.fallback_camera;
        res.effective_crop = eff_crop;
        res.camera_label = res.fallback_camera.Model ? std::string(res.fallback_camera.Model) : "Sony E";
    } else {
        res.effective_crop = (query->crop_factor > 0.1f) ? query->crop_factor : 1.0f;
    }
    if (cams) {
        lf_free(cams);
    }

    const bool using_lens_override = is_non_empty(query->lens_override);
    const char *lens_query = using_lens_override ? query->lens_override : query->lens_model;
    if (!is_non_empty(lens_query)) {
        return res;
    }

    const lfLens **lenses = nullptr;
    if (using_lens_override) {
        lenses = db->FindLenses(cam_ptr, nullptr, lens_query, LF_SEARCH_SORT_AND_UNIQUIFY);
        if ((!lenses || !lenses[0]) && cam_ptr != nullptr) {
            if (lenses) lf_free(lenses);
            lenses = db->FindLenses(nullptr, nullptr, lens_query, LF_SEARCH_SORT_AND_UNIQUIFY);
        }
    } else {
        const char *lmk = is_non_empty(query->lens_make) ? query->lens_make : nullptr;
        lenses = db->FindLenses(cam_ptr, lmk, lens_query, LF_SEARCH_SORT_AND_UNIQUIFY);
        if ((!lenses || !lenses[0]) && lmk != nullptr) {
            if (lenses) lf_free(lenses);
            lenses = db->FindLenses(cam_ptr, nullptr, lens_query, LF_SEARCH_SORT_AND_UNIQUIFY);
        }
        if ((!lenses || !lenses[0]) && cam_ptr == nullptr) {
            if (lenses) lf_free(lenses);
            lenses = db->FindLenses(nullptr, nullptr, lens_query, LF_SEARCH_SORT_AND_UNIQUIFY);
        }
    }

    if (lenses && lenses[0]) {
        res.lens = lenses[0];
        const char *mk = lenses[0]->Maker ? lenses[0]->Maker : "";
        const char *md = lenses[0]->Model ? lenses[0]->Model : "";
        if (mk[0] != '\0' && !contains_icase(md, mk)) {
            res.lens_label = std::string(mk) + " " + md;
        } else {
            res.lens_label = std::string(md);
        }
    }
    if (lenses) {
        lf_free(lenses);
    }

    return res;
}

static void fill_match_result(const ResolvedMatchInternal &resolved, ChiaroLensfunMatchResult *out_result) {
    if (!out_result) {
        return;
    }
    std::memset(out_result, 0, sizeof(*out_result));
    out_result->resolved_crop_factor = resolved.effective_crop;
    out_result->is_sony_e_fallback = resolved.is_sony_fallback ? 1 : 0;
    copy_cstr(out_result->camera_matched, sizeof(out_result->camera_matched), resolved.camera_label.c_str());

    if (!resolved.lens) {
        out_result->matched = 0;
        return;
    }

    out_result->matched = 1;
    copy_cstr(out_result->lens_matched, sizeof(out_result->lens_matched), resolved.lens_label.c_str());
    out_result->has_distortion = (resolved.lens->CalibDistortion && resolved.lens->CalibDistortion[0]) ? 1 : 0;
    out_result->has_tca = (resolved.lens->CalibTCA && resolved.lens->CalibTCA[0]) ? 1 : 0;
    out_result->has_vignetting = (resolved.lens->CalibVignetting && resolved.lens->CalibVignetting[0]) ? 1 : 0;
}

} /* namespace */

ChiaroLensfunHandle *chiaro_lensfun_create(const char *db_directory,
                                           const char *user_db_directory) {
    lfDatabase *db = lf_db_new();
    if (!db) {
        return nullptr;
    }

    int loaded_primary = 0;
    std::string primary_dir;
    if (is_non_empty(db_directory)) {
        primary_dir = db_directory;
        loaded_primary = db->LoadDirectory(db_directory) ? 1 : 0;
    }

    int loaded_user = 0;
    if (is_non_empty(user_db_directory)) {
        loaded_user = db->LoadDirectory(user_db_directory) ? 1 : 0;
    }

    ChiaroLensfunHandle *handle = new (std::nothrow) ChiaroLensfunHandle();
    if (!handle) {
        lf_db_destroy(db);
        return nullptr;
    }
    handle->db = db;
    handle->primary_db_dir = std::move(primary_dir);
    handle->loaded_primary_db = loaded_primary;
    handle->loaded_user_db = loaded_user;
    return handle;
}

void chiaro_lensfun_destroy(ChiaroLensfunHandle *handle) {
    if (!handle) {
        return;
    }
    {
        std::lock_guard<std::mutex> lock(handle->mutex);
        if (handle->db) {
            lf_db_destroy(handle->db);
            handle->db = nullptr;
        }
    }
    delete handle;
}

int chiaro_lensfun_reload_user_db(ChiaroLensfunHandle *handle,
                                  const char *user_db_directory) {
    if (!handle) {
        return -1;
    }
    std::lock_guard<std::mutex> lock(handle->mutex);
    lfDatabase *new_db = lf_db_new();
    if (!new_db) {
        return -1;
    }

    int loaded_primary = 0;
    if (!handle->primary_db_dir.empty()) {
        loaded_primary = new_db->LoadDirectory(handle->primary_db_dir.c_str()) ? 1 : 0;
    }
    int loaded_user = 0;
    if (is_non_empty(user_db_directory)) {
        loaded_user = new_db->LoadDirectory(user_db_directory) ? 1 : 0;
    }

    if (handle->db) {
        lf_db_destroy(handle->db);
    }
    handle->db = new_db;
    handle->loaded_primary_db = loaded_primary;
    handle->loaded_user_db = loaded_user;
    return 0;
}

int chiaro_lensfun_get_info(const ChiaroLensfunHandle *handle,
                            ChiaroLensfunLibraryInfo *out_info) {
    if (!out_info) {
        return -1;
    }
    std::memset(out_info, 0, sizeof(*out_info));
    out_info->version_major = LF_VERSION_MAJOR;
    out_info->version_minor = LF_VERSION_MINOR;
    out_info->version_micro = LF_VERSION_MICRO;

    if (!handle) {
        return -1;
    }
    std::lock_guard<std::mutex> lock(handle->mutex);
    if (!handle->db) {
        return -1;
    }

    out_info->loaded_primary_db = handle->loaded_primary_db;
    out_info->loaded_user_db = handle->loaded_user_db;

    int cam_count = 0;
    const lfCamera *const *cameras = handle->db->GetCameras();
    if (cameras) {
        while (cameras[cam_count] != nullptr) {
            ++cam_count;
        }
    }
    out_info->db_camera_count = cam_count;

    int lens_count = 0;
    const lfLens *const *lenses = handle->db->GetLenses();
    if (lenses) {
        while (lenses[lens_count] != nullptr) {
            ++lens_count;
        }
    }
    out_info->db_lens_count = lens_count;

    return 0;
}

int chiaro_lensfun_match(const ChiaroLensfunHandle *handle,
                         const ChiaroLensfunMatchQuery *query,
                         ChiaroLensfunMatchResult *out_result) {
    if (out_result) {
        std::memset(out_result, 0, sizeof(*out_result));
    }
    if (!handle || !query || !out_result) {
        return -1;
    }
    std::lock_guard<std::mutex> lock(handle->mutex);
    if (!handle->db) {
        return -1;
    }

    ResolvedMatchInternal resolved = resolve_camera_and_lens_locked(handle->db, query);
    fill_match_result(resolved, out_result);
    return resolved.lens ? 0 : -1;
}

int chiaro_lensfun_compute_lut(const ChiaroLensfunHandle *handle,
                               const ChiaroLensfunMatchQuery *query,
                               const ChiaroLensfunLUTParams *params,
                               float *out_warp_rgb_uv,
                               float *out_vig_gain,
                               ChiaroLensfunMatchResult *out_result) {
    if (out_result) {
        std::memset(out_result, 0, sizeof(*out_result));
    }
    if (!handle || !query || !params || !out_warp_rgb_uv || !out_vig_gain) {
        return -1;
    }
    if (params->image_width <= 1 || params->image_height <= 1 ||
        params->lut_width < 2 || params->lut_height < 2) {
        return -1;
    }

    std::lock_guard<std::mutex> lock(handle->mutex);
    if (!handle->db) {
        return -1;
    }

    ResolvedMatchInternal resolved = resolve_camera_and_lens_locked(handle->db, query);
    fill_match_result(resolved, out_result);
    if (!resolved.lens) {
        return -1;
    }

    const lfLens *lens = resolved.lens;
    const int img_w = params->image_width;
    const int img_h = params->image_height;
    const int lut_w = params->lut_width;
    const int lut_h = params->lut_height;
    const float inv_img_w = 1.0f / static_cast<float>(img_w - 1);
    const float inv_img_h = 1.0f / static_cast<float>(img_h - 1);

    float focal = (params->focal_length_mm > 0.0f && std::isfinite(params->focal_length_mm))
                      ? params->focal_length_mm
                      : (lens->MinFocal > 0.0f ? lens->MinFocal : 35.0f);
    if (lens->MinFocal > 0.0f && focal < lens->MinFocal) {
        focal = lens->MinFocal;
    }
    if (lens->MaxFocal > 0.0f && focal > lens->MaxFocal) {
        focal = lens->MaxFocal;
    }
    const float aperture = (params->aperture_f_number > 0.0f && std::isfinite(params->aperture_f_number))
                               ? params->aperture_f_number
                               : (lens->MinAperture > 0.0f ? lens->MinAperture : 4.0f);

    int flags = 0;
    if (params->enable_distortion) flags |= LF_MODIFY_DISTORTION;
    if (params->enable_tca)        flags |= LF_MODIFY_TCA;
    if (params->enable_vignetting) flags |= LF_MODIFY_VIGNETTING;
    if (params->enable_distortion && params->enable_auto_scale) flags |= LF_MODIFY_SCALE;

    lfModifier mod(lens, resolved.effective_crop, img_w, img_h);
    const int active = mod.Initialize(
        lens,
        LF_PF_F32,
        focal,
        aperture,
        1000.0f,
        (params->enable_auto_scale != 0) ? 0.0f : 1.0f,
        LF_RECTILINEAR,
        flags,
        false
    );

    if (out_result) {
        out_result->has_distortion = (active & LF_MODIFY_DISTORTION) ? 1 : 0;
        out_result->has_tca = (active & LF_MODIFY_TCA) ? 1 : 0;
        out_result->has_vignetting = (active & LF_MODIFY_VIGNETTING) ? 1 : 0;
    }

    const size_t slice_floats = static_cast<size_t>(lut_w) * static_cast<size_t>(lut_h) * 2u;
    float *slice_r = out_warp_rgb_uv;
    float *slice_g = out_warp_rgb_uv + slice_floats;
    float *slice_b = out_warp_rgb_uv + 2u * slice_floats;

    const bool do_geom = (active & (LF_MODIFY_DISTORTION | LF_MODIFY_TCA | LF_MODIFY_SCALE)) != 0;
    const bool do_vig = (active & LF_MODIFY_VIGNETTING) != 0;

    for (int gy = 0; gy < lut_h; ++gy) {
        const float v_dst = static_cast<float>(gy) / static_cast<float>(lut_h - 1);
        const float y_dst = v_dst * static_cast<float>(img_h - 1);

        for (int gx = 0; gx < lut_w; ++gx) {
            const float u_dst = static_cast<float>(gx) / static_cast<float>(lut_w - 1);
            const float x_dst = u_dst * static_cast<float>(img_w - 1);

            float coords6[6] = {x_dst, y_dst, x_dst, y_dst, x_dst, y_dst};
            if (do_geom) {
                if (!mod.ApplySubpixelGeometryDistortion(x_dst, y_dst, 1, 1, coords6)) {
                    coords6[0] = x_dst; coords6[1] = y_dst;
                    coords6[2] = x_dst; coords6[3] = y_dst;
                    coords6[4] = x_dst; coords6[5] = y_dst;
                }
            }

            const size_t px_idx = static_cast<size_t>(gy) * static_cast<size_t>(lut_w) + static_cast<size_t>(gx);
            const size_t uv_idx = px_idx * 2u;

            auto norm_coord = [&](float x, float y, float &out_u, float &out_v) {
                if (std::isfinite(x) && std::isfinite(y)) {
                    out_u = x * inv_img_w;
                    out_v = y * inv_img_h;
                } else {
                    out_u = u_dst;
                    out_v = v_dst;
                }
            };

            norm_coord(coords6[0], coords6[1], slice_r[uv_idx], slice_r[uv_idx + 1u]);
            norm_coord(coords6[2], coords6[3], slice_g[uv_idx], slice_g[uv_idx + 1u]);
            norm_coord(coords6[4], coords6[5], slice_b[uv_idx], slice_b[uv_idx + 1u]);

            float vig_gain = 1.0f;
            if (do_vig) {
                const float gx_src = std::isfinite(coords6[2]) ? coords6[2] : x_dst;
                const float gy_src = std::isfinite(coords6[3]) ? coords6[3] : y_dst;
                float rgba4[4] = {0.5f, 0.5f, 0.5f, 0.5f};
                if (mod.ApplyColorModification(rgba4,
                                               gx_src,
                                               gy_src,
                                               1,
                                               1,
                                               LF_CR_4(RED, GREEN, BLUE, UNKNOWN),
                                               4 * sizeof(float))) {
                    const float g = 2.0f * (rgba4[0] + rgba4[1] + rgba4[2]) / 3.0f;
                    if (std::isfinite(g)) {
                        vig_gain = std::min(std::max(g, 0.25f), 8.0f);
                    }
                }
            }
            out_vig_gain[px_idx] = vig_gain;
        }
    }

    return 0;
}

int chiaro_lensfun_list_lenses(const ChiaroLensfunHandle *handle,
                               const char *mount_filter,
                               char ***out_names,
                               int *out_count) {
    if (out_names) *out_names = nullptr;
    if (out_count) *out_count = 0;
    if (!handle || !out_names || !out_count) {
        return -1;
    }
    std::lock_guard<std::mutex> lock(handle->mutex);
    if (!handle->db) {
        return -1;
    }

    const lfLens *const *lenses = handle->db->GetLenses();
    if (!lenses) {
        return 0;
    }

    std::vector<std::string> names;
    const bool filter_mount = is_non_empty(mount_filter);
    for (int i = 0; lenses[i] != nullptr; ++i) {
        const lfLens *lens = lenses[i];
        if (filter_mount) {
            bool mount_ok = false;
            if (lens->Mounts) {
                for (int m = 0; lens->Mounts[m] != nullptr; ++m) {
                    if (contains_icase(lens->Mounts[m], mount_filter)) {
                        mount_ok = true;
                        break;
                    }
                }
            }
            if (!mount_ok) {
                continue;
            }
        }
        const char *mk = lens->Maker ? lens->Maker : "";
        const char *md = lens->Model ? lens->Model : "";
        if (md[0] == '\0') {
            continue;
        }
        if (mk[0] != '\0' && !contains_icase(md, mk)) {
            names.push_back(std::string(mk) + " " + md);
        } else {
            names.push_back(std::string(md));
        }
    }

    std::sort(names.begin(), names.end());
    names.erase(std::unique(names.begin(), names.end()), names.end());

    if (names.empty()) {
        return 0;
    }

    char **arr = static_cast<char **>(std::calloc(names.size(), sizeof(char *)));
    if (!arr) {
        return -1;
    }
    for (size_t i = 0; i < names.size(); ++i) {
        arr[i] = static_cast<char *>(std::malloc(names[i].size() + 1u));
        if (!arr[i]) {
            chiaro_lensfun_free_string_list(arr, static_cast<int>(i));
            return -1;
        }
        std::memcpy(arr[i], names[i].c_str(), names[i].size() + 1u);
    }

    *out_names = arr;
    *out_count = static_cast<int>(names.size());
    return 0;
}

void chiaro_lensfun_free_string_list(char **names, int count) {
    if (!names) {
        return;
    }
    for (int i = 0; i < count; ++i) {
        std::free(names[i]);
    }
    std::free(names);
}
