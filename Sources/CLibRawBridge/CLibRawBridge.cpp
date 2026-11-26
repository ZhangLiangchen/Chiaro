#include "CLibRawBridge.h"
#include <arpa/inet.h>
#include <dispatch/dispatch.h>
#include <libraw/libraw.h>
#include <rtprocess/librtprocess.h>
#include <algorithm>
#include <cctype>
#include <cfloat>
#include <climits>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace {

class ChiaroLibRaw : public LibRaw {
public:
    explicit ChiaroLibRaw(unsigned int flags = LIBRAW_OPTIONS_NONE) : LibRaw(flags) {}

    HDRLibRawDemosaicAlgorithm requested_demosaic = HDR_LIBRAW_DEMOSAIC_AMAZE;
    bool bayer_callback_invoked = false;
    bool fallback_to_ahd = false;

    void set_bayer_demosaic_callback(void (*cb)(void *)) {
        callbacks.interpolate_bayer_cb = cb;
    }

    int fc_at(int row, int col) {
        return FC(row, col);
    }

    void run_ahd_fallback() {
        ahd_interpolate();
        fallback_to_ahd = true;
    }
};

struct ExifCallbackContext {
    std::string raw_make;
    std::string date_time_original;
    std::string offset_time_original;
    std::string offset_time_fallback;
    std::string subsec_time_original;
    std::string subsec_time_fallback;
    std::string gps_date_stamp;
    double exposure_bias_ev = 0.0;
    bool has_exposure_bias = false;
    bool has_gps_altitude_tag = false;

    bool has_distortion = false;
    int32_t distortion_node_count = 0;
    int16_t distortion_params[16] = {};

    bool has_ca = false;
    int32_t ca_node_count = 0;
    int16_t ca_red_params[16] = {};
    int16_t ca_blue_params[16] = {};

    bool has_vignetting = false;
    int32_t vignetting_node_count = 0;
    int16_t vignetting_params[16] = {};

    bool has_sr2_offset = false;
    bool has_sr2_length = false;
    bool has_sr2_key = false;
    bool sr2_decrypt_attempted = false;
    uint32_t sr2_offset = 0;
    uint32_t sr2_length = 0;
    uint32_t sr2_key = 0;
    unsigned int sr2_ord = 0x4949;
    INT64 sr2_base = 0;
};

static std::string trim_ascii(const char *buf, size_t max_len) {
    if (!buf || max_len == 0) {
        return {};
    }
    size_t n = 0;
    while (n < max_len && buf[n] != '\0') {
        ++n;
    }
    while (n > 0 && std::isspace(static_cast<unsigned char>(buf[n - 1]))) {
        --n;
    }
    size_t start = 0;
    while (start < n && std::isspace(static_cast<unsigned char>(buf[start]))) {
        ++start;
    }
    return std::string(buf + start, n - start);
}

static char *dup_non_empty(const char *s) {
    if (!s || s[0] == '\0') {
        return nullptr;
    }
    size_t len = std::strlen(s);
    char *copy = static_cast<char *>(std::malloc(len + 1));
    if (!copy) {
        return nullptr;
    }
    std::memcpy(copy, s, len + 1);
    return copy;
}

static char *dup_non_empty_trimmed(const char *s, size_t max_len) {
    std::string t = trim_ascii(s, max_len);
    return t.empty() ? nullptr : dup_non_empty(t.c_str());
}

static uint16_t read_u16(const uint8_t *p, unsigned int ord) {
    if (ord == 0x4D4D) { /* 'MM' big-endian */
        return static_cast<uint16_t>((static_cast<uint16_t>(p[0]) << 8) | static_cast<uint16_t>(p[1]));
    }
    return static_cast<uint16_t>(static_cast<uint16_t>(p[0]) | (static_cast<uint16_t>(p[1]) << 8));
}

static uint32_t read_u32(const uint8_t *p, unsigned int ord) {
    if (ord == 0x4D4D) { /* 'MM' big-endian */
        return (static_cast<uint32_t>(p[0]) << 24) |
               (static_cast<uint32_t>(p[1]) << 16) |
               (static_cast<uint32_t>(p[2]) << 8) |
               static_cast<uint32_t>(p[3]);
    }
    /* 'II' (0x4949) little-endian */
    return static_cast<uint32_t>(p[0]) |
           (static_cast<uint32_t>(p[1]) << 8) |
           (static_cast<uint32_t>(p[2]) << 16) |
           (static_cast<uint32_t>(p[3]) << 24);
}

static std::vector<int16_t> read_i16_array_from_stream(LibRaw_abstract_datastream *stream,
                                                       int len,
                                                       unsigned int ord) {
    if (!stream || len <= 0 || len > 64) {
        return {};
    }
    const size_t bytes_needed = static_cast<size_t>(len) * 2u;
    std::vector<uint8_t> raw(bytes_needed, 0);
    if (stream->read(raw.data(), 1, bytes_needed) != static_cast<int>(bytes_needed)) {
        return {};
    }
    std::vector<int16_t> out(static_cast<size_t>(len), 0);
    for (int i = 0; i < len; ++i) {
        out[static_cast<size_t>(i)] = static_cast<int16_t>(read_u16(raw.data() + static_cast<size_t>(i) * 2u, ord));
    }
    return out;
}

static void parse_sony_distortion_array(const std::vector<int16_t> &arr, ExifCallbackContext *ctx) {
    if (!ctx || ctx->has_distortion || arr.size() < 2) {
        return;
    }
    int32_t nc = static_cast<int32_t>(arr[0]);
    if (nc <= 0 || nc > 16 || arr.size() < static_cast<size_t>(1 + nc)) {
        return;
    }
    ctx->distortion_node_count = nc;
    std::memset(ctx->distortion_params, 0, sizeof(ctx->distortion_params));
    for (int32_t i = 0; i < nc; ++i) {
        ctx->distortion_params[i] = arr[static_cast<size_t>(1 + i)];
    }
    ctx->has_distortion = true;
}

static void parse_sony_ca_array(const std::vector<int16_t> &arr, ExifCallbackContext *ctx) {
    if (!ctx || ctx->has_ca || arr.size() < 3) {
        return;
    }
    int32_t total = static_cast<int32_t>(arr[0]);
    if (total <= 0 || (total & 1) != 0) {
        return;
    }
    int32_t nc = total / 2;
    if (nc <= 0 || nc > 16 || arr.size() < static_cast<size_t>(1 + 2 * nc)) {
        return;
    }
    ctx->ca_node_count = nc;
    std::memset(ctx->ca_red_params, 0, sizeof(ctx->ca_red_params));
    std::memset(ctx->ca_blue_params, 0, sizeof(ctx->ca_blue_params));
    for (int32_t i = 0; i < nc; ++i) {
        ctx->ca_red_params[i] = arr[static_cast<size_t>(1 + i)];
        ctx->ca_blue_params[i] = arr[static_cast<size_t>(1 + nc + i)];
    }
    ctx->has_ca = true;
}

static void parse_sony_vignetting_array(const std::vector<int16_t> &arr, ExifCallbackContext *ctx) {
    if (!ctx || ctx->has_vignetting || arr.size() < 2) {
        return;
    }
    int32_t nc = static_cast<int32_t>(arr[0]);
    if (nc <= 0 || nc > 16 || arr.size() < static_cast<size_t>(1 + nc)) {
        return;
    }
    ctx->vignetting_node_count = nc;
    std::memset(ctx->vignetting_params, 0, sizeof(ctx->vignetting_params));
    for (int32_t i = 0; i < nc; ++i) {
        ctx->vignetting_params[i] = arr[static_cast<size_t>(1 + i)];
    }
    ctx->has_vignetting = true;
}

/* Exact Sony SR2 decryption algorithm matching LibRaw::sony_decrypt */
static void sony_decrypt_words(uint32_t *data, size_t len_words, uint32_t key) {
    if (!data || len_words == 0) {
        return;
    }
    uint32_t pad[128] = {};
    unsigned int p = 0;
    for (p = 0; p < 4; ++p) {
        key = static_cast<uint32_t>(static_cast<uint64_t>(key) * 48828125ULL + 1ULL);
        pad[p] = key;
    }
    pad[3] = (pad[3] << 1) | ((pad[0] ^ pad[2]) >> 31);
    for (p = 4; p < 127; ++p) {
        pad[p] = ((pad[p - 4] ^ pad[p - 2]) << 1) | ((pad[p - 3] ^ pad[p - 1]) >> 31);
    }
    for (p = 0; p < 127; ++p) {
        pad[p] = htonl(pad[p]);
    }
    p = 127;
    for (size_t i = 0; i < len_words; ++i) {
        uint32_t next_pad = pad[(p + 1) & 127] ^ pad[(p + 65) & 127];
        pad[p & 127] = next_pad;
        data[i] ^= next_pad;
        ++p;
    }
}

static void try_decrypt_sr2_subifd(LibRaw_abstract_datastream *stream, ExifCallbackContext *ctx) {
    if (!stream || !ctx || ctx->sr2_decrypt_attempted) {
        return;
    }
    if (!ctx->has_sr2_offset || !ctx->has_sr2_length || !ctx->has_sr2_key) {
        return;
    }
    if (ctx->has_distortion && ctx->has_ca && ctx->has_vignetting) {
        return;
    }
    ctx->sr2_decrypt_attempted = true;

    if (ctx->sr2_length < 16 || ctx->sr2_length > 10240000u) {
        return;
    }

    const INT64 saved_pos = stream->tell();
    const INT64 target_pos = static_cast<INT64>(ctx->sr2_offset) + ctx->sr2_base;
    if (target_pos < 0 || stream->seek(target_pos, SEEK_SET) != 0) {
        stream->seek(saved_pos, SEEK_SET);
        return;
    }

    const size_t padded_bytes = ((static_cast<size_t>(ctx->sr2_length) + 3u) / 4u) * 4u;
    std::vector<uint8_t> buf(padded_bytes, 0);
    const int got = stream->read(buf.data(), 1, static_cast<size_t>(ctx->sr2_length));
    stream->seek(saved_pos, SEEK_SET);
    if (got != static_cast<int>(ctx->sr2_length)) {
        return;
    }

    sony_decrypt_words(reinterpret_cast<uint32_t *>(buf.data()),
                       static_cast<size_t>(ctx->sr2_length) / 4u,
                       ctx->sr2_key);

    const unsigned int ord = ctx->sr2_ord;
    const uint16_t entries = read_u16(buf.data(), ord);
    if (entries == 0 || entries > 512) {
        return;
    }

    for (uint16_t i = 0; i < entries; ++i) {
        const size_t entry_off = 2u + static_cast<size_t>(i) * 12u;
        if (entry_off + 12u > static_cast<size_t>(ctx->sr2_length)) {
            break;
        }
        const uint16_t sr2_tag = read_u16(buf.data() + entry_off, ord);
        const uint16_t sr2_type = read_u16(buf.data() + entry_off + 2u, ord);
        const uint32_t sr2_count = read_u32(buf.data() + entry_off + 4u, ord);
        const uint32_t sr2_val_off = read_u32(buf.data() + entry_off + 8u, ord);

        if (sr2_tag != 0x7982 && sr2_tag != 0x7980 && sr2_tag != 0x797d) {
            continue;
        }
        if (sr2_type != LIBRAW_EXIFTAG_TYPE_SSHORT && sr2_type != LIBRAW_EXIFTAG_TYPE_SHORT) {
            continue;
        }
        if (sr2_count == 0 || sr2_count > 64) {
            continue;
        }

        const size_t data_bytes = static_cast<size_t>(sr2_count) * 2u;
        size_t rel_off = 0;
        if (data_bytes <= 4u) {
            rel_off = entry_off + 8u;
        } else {
            if (sr2_val_off < ctx->sr2_offset) {
                continue;
            }
            rel_off = static_cast<size_t>(sr2_val_off - ctx->sr2_offset);
        }
        if (rel_off + data_bytes > static_cast<size_t>(ctx->sr2_length)) {
            continue;
        }

        std::vector<int16_t> arr(sr2_count, 0);
        for (uint32_t k = 0; k < sr2_count; ++k) {
            arr[k] = static_cast<int16_t>(read_u16(buf.data() + rel_off + static_cast<size_t>(k) * 2u, ord));
        }

        if (sr2_tag == 0x7982) {
            parse_sony_distortion_array(arr, ctx);
        } else if (sr2_tag == 0x7980) {
            parse_sony_ca_array(arr, ctx);
        } else if (sr2_tag == 0x797d) {
            parse_sony_vignetting_array(arr, ctx);
        }
    }
}

static std::string read_ascii_tag(LibRaw_abstract_datastream *stream, int len) {
    if (!stream || len <= 0 || len > 512) {
        return {};
    }
    std::vector<char> buf(static_cast<size_t>(len) + 1, '\0');
    int got = stream->read(buf.data(), 1, static_cast<size_t>(len));
    if (got <= 0) {
        return {};
    }
    return trim_ascii(buf.data(), static_cast<size_t>(got));
}

static void hdr_exif_parser_cb(void *context,
                               int tag,
                               int type,
                               int len,
                               unsigned int ord,
                               void *ifp,
                               INT64 base) {
    if (!context || !ifp) {
        return;
    }
    /* Never extract MakerNote (0x927C) under any circumstance. */
    if ((tag & 0xFFFF) == 0x927C) {
        return;
    }

    auto *ctx = static_cast<ExifCallbackContext *>(context);
    auto *stream = static_cast<LibRaw_abstract_datastream *>(ifp);

    if (tag >= 0x100000) {
        const int low_tag = tag & 0xFFFF;
        if (low_tag == 0x7037 &&
            (type == LIBRAW_EXIFTAG_TYPE_SSHORT || type == LIBRAW_EXIFTAG_TYPE_SHORT)) {
            parse_sony_distortion_array(read_i16_array_from_stream(stream, len, ord), ctx);
            return;
        }
        if (low_tag == 0x7035 &&
            (type == LIBRAW_EXIFTAG_TYPE_SSHORT || type == LIBRAW_EXIFTAG_TYPE_SHORT)) {
            parse_sony_ca_array(read_i16_array_from_stream(stream, len, ord), ctx);
            return;
        }
        if (low_tag == 0x7032 &&
            (type == LIBRAW_EXIFTAG_TYPE_SSHORT || type == LIBRAW_EXIFTAG_TYPE_SHORT)) {
            parse_sony_vignetting_array(read_i16_array_from_stream(stream, len, ord), ctx);
            return;
        }
        if (low_tag == 0x7200 && len >= 1) {
            uint8_t raw4[4] = {0};
            if (stream->read(raw4, 1, 4) == 4) {
                ctx->sr2_offset = read_u32(raw4, ord);
                ctx->sr2_ord = ord;
                ctx->sr2_base = base;
                ctx->has_sr2_offset = true;
                try_decrypt_sr2_subifd(stream, ctx);
            }
            return;
        }
        if (low_tag == 0x7201 && len >= 1) {
            uint8_t raw4[4] = {0};
            if (stream->read(raw4, 1, 4) == 4) {
                ctx->sr2_length = read_u32(raw4, ord);
                ctx->sr2_ord = ord;
                ctx->sr2_base = base;
                ctx->has_sr2_length = true;
                try_decrypt_sr2_subifd(stream, ctx);
            }
            return;
        }
        if (low_tag == 0x7221 && len >= 1) {
            uint8_t raw4[4] = {0};
            if (stream->read(raw4, 1, 4) == 4) {
                ctx->sr2_key = read_u32(raw4, ord);
                ctx->sr2_ord = ord;
                ctx->sr2_base = base;
                ctx->has_sr2_key = true;
                try_decrypt_sr2_subifd(stream, ctx);
            }
            return;
        }
    }

    switch (tag) {
        case (0x100000 | 0x010F): /* IFD0 Make (raw ASCII before LibRaw simplify_make_model) */
            if (ctx->raw_make.empty() &&
                (type == LIBRAW_EXIFTAG_TYPE_ASCII || type == LIBRAW_EXIFTAG_TYPE_UNDEFINED)) {
                ctx->raw_make = read_ascii_tag(stream, len);
            }
            break;
        case 0x9003: /* DateTimeOriginal */
            if (ctx->date_time_original.empty()) {
                ctx->date_time_original = read_ascii_tag(stream, len);
            }
            break;
        case 0x9011: /* OffsetTimeOriginal */
            if (ctx->offset_time_original.empty()) {
                ctx->offset_time_original = read_ascii_tag(stream, len);
            }
            break;
        case 0x9010: /* OffsetTime */
            if (ctx->offset_time_fallback.empty()) {
                ctx->offset_time_fallback = read_ascii_tag(stream, len);
            }
            break;
        case 0x9291: /* SubSecTimeOriginal */
            if (ctx->subsec_time_original.empty()) {
                ctx->subsec_time_original = read_ascii_tag(stream, len);
            }
            break;
        case 0x9290: /* SubSecTime */
            if (ctx->subsec_time_fallback.empty()) {
                ctx->subsec_time_fallback = read_ascii_tag(stream, len);
            }
            break;
        case 0x9204: /* ExposureBiasValue (SRATIONAL) */
            if (!ctx->has_exposure_bias && len >= 1 &&
                (type == LIBRAW_EXIFTAG_TYPE_SRATIONAL || type == LIBRAW_EXIFTAG_TYPE_RATIONAL)) {
                uint8_t raw[8] = {0};
                if (stream->read(raw, 1, 8) == 8) {
                    if (type == LIBRAW_EXIFTAG_TYPE_SRATIONAL) {
                        int32_t num = static_cast<int32_t>(read_u32(raw, ord));
                        int32_t den = static_cast<int32_t>(read_u32(raw + 4, ord));
                        if (den != 0) {
                            ctx->exposure_bias_ev = static_cast<double>(num) / static_cast<double>(den);
                            ctx->has_exposure_bias = true;
                        }
                    } else {
                        uint32_t num = read_u32(raw, ord);
                        uint32_t den = read_u32(raw + 4, ord);
                        if (den != 0) {
                            ctx->exposure_bias_ev = static_cast<double>(num) / static_cast<double>(den);
                            ctx->has_exposure_bias = true;
                        }
                    }
                }
            }
            break;
        case (0x50000 | 0x0006): /* GPSAltitude */
            ctx->has_gps_altitude_tag = true;
            break;
        case (0x50000 | 0x001D): /* GPSDateStamp */
            if (ctx->gps_date_stamp.empty()) {
                ctx->gps_date_stamp = read_ascii_tag(stream, len);
            }
            break;
        default:
            break;
    }
}

static void set_image_error(HDRLibRawImage *out_image,
                            HDRLibRawStatus status,
                            int32_t raw_err,
                            const char *msg) {
    if (!out_image) {
        return;
    }
    out_image->error_code = (raw_err != 0) ? raw_err : static_cast<int32_t>(status);
    if (msg) {
        std::snprintf(out_image->error_message, sizeof(out_image->error_message), "%s", msg);
    } else {
        out_image->error_message[0] = '\0';
    }
}

static HDRLibRawCFAPattern detect_cfa_pattern(LibRaw *lr, int32_t crop_top, int32_t crop_left) {
    if (!lr || lr->imgdata.idata.filters == 0) {
        return HDR_LIBRAW_CFA_UNKNOWN;
    }
    const char *cdesc = lr->imgdata.idata.cdesc;
    char quad[5] = {0, 0, 0, 0, 0};
    int coords[4][2] = {
        {crop_top, crop_left},
        {crop_top, crop_left + 1},
        {crop_top + 1, crop_left},
        {crop_top + 1, crop_left + 1}
    };
    for (int i = 0; i < 4; ++i) {
        int c = lr->COLOR(coords[i][0], coords[i][1]);
        if (c < 0 || c > 3) {
            return HDR_LIBRAW_CFA_UNKNOWN;
        }
        char ch = cdesc[c];
        if (ch != 'R' && ch != 'G' && ch != 'B') {
            return HDR_LIBRAW_CFA_UNKNOWN;
        }
        quad[i] = ch;
    }
    if (std::strcmp(quad, "RGGB") == 0) return HDR_LIBRAW_CFA_RGGB;
    if (std::strcmp(quad, "BGGR") == 0) return HDR_LIBRAW_CFA_BGGR;
    if (std::strcmp(quad, "GRBG") == 0) return HDR_LIBRAW_CFA_GRBG;
    if (std::strcmp(quad, "GBRG") == 0) return HDR_LIBRAW_CFA_GBRG;
    return HDR_LIBRAW_CFA_UNKNOWN;
}

static void populate_metadata_and_matrices(LibRaw *lr,
                                           const ExifCallbackContext &cb_ctx,
                                           HDRLibRawImage *out_image) {
    static constexpr int32_t kFlipToExif[8] = {1, 2, 4, 3, 5, 8, 6, 7};
    int32_t exif_orient = kFlipToExif[lr->imgdata.sizes.flip & 7];

    out_image->orientation = exif_orient;
    out_image->as_shot_wb_applied = (lr->imgdata.color.as_shot_wb_applied != 0) ? 1 : 0;

    for (int i = 0; i < 4; ++i) {
        out_image->cam_mul[i] = lr->imgdata.color.cam_mul[i];
        out_image->pre_mul[i] = lr->imgdata.color.pre_mul[i];
        uint32_t bl = static_cast<uint32_t>(std::max(0, static_cast<int>(lr->imgdata.color.black) +
                                                        static_cast<int>(lr->imgdata.color.cblack[i])));
        out_image->black_level[i] = bl;
    }
    out_image->white_level = static_cast<uint32_t>(lr->imgdata.color.maximum);

    for (int r = 0; r < 4; ++r) {
        for (int c = 0; c < 3; ++c) {
            out_image->cam_xyz[r * 3 + c] = lr->imgdata.color.cam_xyz[r][c];
        }
    }
    for (int r = 0; r < 3; ++r) {
        for (int c = 0; c < 4; ++c) {
            out_image->rgb_cam[r * 4 + c] = lr->imgdata.color.rgb_cam[r][c];
        }
    }

    int fm_idx = -1;
    if ((lr->imgdata.color.dng_color[0].parsedfields & LIBRAW_DNGFM_FORWARDMATRIX) != 0) {
        fm_idx = 0;
    } else if ((lr->imgdata.color.dng_color[1].parsedfields & LIBRAW_DNGFM_FORWARDMATRIX) != 0) {
        fm_idx = 1;
    }
    if (fm_idx >= 0) {
        out_image->has_forward_matrix = 1;
        for (int r = 0; r < 3; ++r) {
            for (int c = 0; c < 3; ++c) {
                out_image->forward_matrix[r * 3 + c] = lr->imgdata.color.dng_color[fm_idx].forwardmatrix[r][c];
            }
        }
    } else {
        out_image->has_forward_matrix = 0;
    }

    out_image->camera_format = static_cast<int32_t>(lr->imgdata.lens.makernotes.CameraFormat);

    HDRLibRawEmbeddedSonyOptics &opt = out_image->embedded_sony_optics;
    std::memset(&opt, 0, sizeof(opt));
    if (cb_ctx.has_distortion) {
        opt.distortion_node_count = cb_ctx.distortion_node_count;
        std::memcpy(opt.distortion_params, cb_ctx.distortion_params, sizeof(opt.distortion_params));
    }
    if (cb_ctx.has_ca) {
        opt.ca_node_count = cb_ctx.ca_node_count;
        std::memcpy(opt.ca_red_params, cb_ctx.ca_red_params, sizeof(opt.ca_red_params));
        std::memcpy(opt.ca_blue_params, cb_ctx.ca_blue_params, sizeof(opt.ca_blue_params));
    }
    if (cb_ctx.has_vignetting) {
        opt.vignetting_node_count = cb_ctx.vignetting_node_count;
        std::memcpy(opt.vignetting_params, cb_ctx.vignetting_params, sizeof(opt.vignetting_params));
    }
    opt.has_optics = (cb_ctx.has_distortion || cb_ctx.has_ca || cb_ctx.has_vignetting) ? 1 : 0;

    HDRLibRawExifMetadata &ex = out_image->exif;
    ex.orientation = exif_orient;
    ex.make = !cb_ctx.raw_make.empty()
                  ? dup_non_empty(cb_ctx.raw_make.c_str())
                  : dup_non_empty_trimmed(lr->imgdata.idata.make, sizeof(lr->imgdata.idata.make));
    ex.model = dup_non_empty_trimmed(lr->imgdata.idata.model, sizeof(lr->imgdata.idata.model));
    ex.lens_make = dup_non_empty_trimmed(lr->imgdata.lens.LensMake, sizeof(lr->imgdata.lens.LensMake));

    ex.lens_model = dup_non_empty_trimmed(lr->imgdata.lens.Lens, sizeof(lr->imgdata.lens.Lens));
    if (!ex.lens_model) {
        ex.lens_model = dup_non_empty_trimmed(lr->imgdata.lens.makernotes.Lens, sizeof(lr->imgdata.lens.makernotes.Lens));
    }
    if (!ex.lens_model && lr->imgdata.lens.MinFocal > 0.0f) {
        char lens_buf[64];
        if (lr->imgdata.lens.MaxFocal > lr->imgdata.lens.MinFocal) {
            std::snprintf(lens_buf, sizeof(lens_buf), "%.0f-%.0fmm",
                          lr->imgdata.lens.MinFocal, lr->imgdata.lens.MaxFocal);
        } else {
            std::snprintf(lens_buf, sizeof(lens_buf), "%.0fmm", lr->imgdata.lens.MinFocal);
        }
        ex.lens_model = dup_non_empty(lens_buf);
    }

    ex.focal_length_mm = (lr->imgdata.other.focal_len > 0.0f) ? static_cast<double>(lr->imgdata.other.focal_len) : 0.0;
    if (lr->imgdata.lens.FocalLengthIn35mmFormat > 0) {
        ex.focal_length_35mm = static_cast<int32_t>(lr->imgdata.lens.FocalLengthIn35mmFormat);
    } else if (lr->imgdata.lens.makernotes.FocalLengthIn35mmFormat > 0.0f) {
        ex.focal_length_35mm = static_cast<int32_t>(std::lroundf(lr->imgdata.lens.makernotes.FocalLengthIn35mmFormat));
    } else {
        ex.focal_length_35mm = 0;
    }

    ex.exposure_time_sec = (lr->imgdata.other.shutter > 0.0f) ? static_cast<double>(lr->imgdata.other.shutter) : 0.0;
    ex.f_number = (lr->imgdata.other.aperture > 0.0f) ? static_cast<double>(lr->imgdata.other.aperture) : 0.0;
    ex.iso_speed = (lr->imgdata.other.iso_speed > 0.0f) ? static_cast<int32_t>(std::lroundf(lr->imgdata.other.iso_speed)) : 0;

    if (cb_ctx.has_exposure_bias) {
        ex.exposure_bias_ev = cb_ctx.exposure_bias_ev;
        ex.has_exposure_bias = 1;
    }

    if (!cb_ctx.date_time_original.empty()) {
        ex.date_time_original = dup_non_empty(cb_ctx.date_time_original.c_str());
    } else if (lr->imgdata.other.timestamp > 0) {
        std::tm tm_val{};
        time_t ts = lr->imgdata.other.timestamp;
        if (gmtime_r(&ts, &tm_val)) {
            char dt_buf[32];
            std::snprintf(dt_buf, sizeof(dt_buf), "%04d:%02d:%02d %02d:%02d:%02d",
                          tm_val.tm_year + 1900, tm_val.tm_mon + 1, tm_val.tm_mday,
                          tm_val.tm_hour, tm_val.tm_min, tm_val.tm_sec);
            ex.date_time_original = dup_non_empty(dt_buf);
        }
    }

    if (!cb_ctx.offset_time_original.empty()) {
        ex.offset_time_original = dup_non_empty(cb_ctx.offset_time_original.c_str());
    } else if (!cb_ctx.offset_time_fallback.empty()) {
        ex.offset_time_original = dup_non_empty(cb_ctx.offset_time_fallback.c_str());
    }

    if (!cb_ctx.subsec_time_original.empty()) {
        ex.subsec_time_original = dup_non_empty(cb_ctx.subsec_time_original.c_str());
    } else if (!cb_ctx.subsec_time_fallback.empty()) {
        ex.subsec_time_original = dup_non_empty(cb_ctx.subsec_time_fallback.c_str());
    }

    const libraw_gps_info_t &gps = lr->imgdata.other.parsed_gps;
    if (gps.gpsparsed != 0 && gps.latref != 0 && gps.longref != 0) {
        ex.has_gps = 1;
        ex.gps_latitude = static_cast<double>(gps.latitude[0]) +
                          static_cast<double>(gps.latitude[1]) / 60.0 +
                          static_cast<double>(gps.latitude[2]) / 3600.0;
        ex.gps_longitude = static_cast<double>(gps.longitude[0]) +
                           static_cast<double>(gps.longitude[1]) / 60.0 +
                           static_cast<double>(gps.longitude[2]) / 3600.0;
        char lat_ref[2] = {static_cast<char>(gps.latref), '\0'};
        ex.gps_latitude_ref = dup_non_empty(lat_ref);
        char lon_ref[2] = {static_cast<char>(gps.longref), '\0'};
        ex.gps_longitude_ref = dup_non_empty(lon_ref);
        if (cb_ctx.has_gps_altitude_tag && std::isfinite(gps.altitude)) {
            ex.has_gps_altitude = 1;
            ex.gps_altitude = static_cast<double>(gps.altitude);
            ex.gps_altitude_ref = static_cast<int32_t>(gps.altref);
        }
        char ts_buf[32];
        std::snprintf(ts_buf, sizeof(ts_buf), "%02.0f:%02.0f:%05.2f",
                      gps.gpstimestamp[0], gps.gpstimestamp[1], gps.gpstimestamp[2]);
        ex.gps_timestamp = dup_non_empty(ts_buf);
        if (!cb_ctx.gps_date_stamp.empty()) {
            ex.gps_date_stamp = dup_non_empty(cb_ctx.gps_date_stamp.c_str());
        }
    }
}

static HDRLibRawStatus validate_decode_options(const HDRLibRawDecodeOptions &opts,
                                               HDRLibRawImage *out_image) {
    if (opts.mode != HDR_LIBRAW_MODE_BAYER_OR_SRAW &&
        opts.mode != HDR_LIBRAW_MODE_LINEAR_RGB16 &&
        opts.mode != HDR_LIBRAW_MODE_PROXY_RGB16) {
        set_image_error(out_image, HDR_LIBRAW_ERR_INVALID_ARG, 0, "Invalid decode mode");
        return HDR_LIBRAW_ERR_INVALID_ARG;
    }
    if (opts.demosaic_algorithm != HDR_LIBRAW_DEMOSAIC_AMAZE &&
        opts.demosaic_algorithm != HDR_LIBRAW_DEMOSAIC_LMMSE &&
        opts.demosaic_algorithm != HDR_LIBRAW_DEMOSAIC_DCB &&
        opts.demosaic_algorithm != HDR_LIBRAW_DEMOSAIC_DHT &&
        opts.demosaic_algorithm != HDR_LIBRAW_DEMOSAIC_AHD) {
        set_image_error(out_image, HDR_LIBRAW_ERR_INVALID_ARG, 0, "Invalid demosaic algorithm");
        return HDR_LIBRAW_ERR_INVALID_ARG;
    }
    if (opts.sraw_no_rgb != 0) {
        set_image_error(out_image,
                        HDR_LIBRAW_ERR_UNSUPPORTED,
                        0,
                        "sraw_no_rgb is not supported by BAYER16U/RGB16U payloads");
        return HDR_LIBRAW_ERR_UNSUPPORTED;
    }
    return HDR_LIBRAW_OK;
}

struct ProxyDmaxContext {
    const uint16_t *raw_crop;
    size_t raw_stride_u16;
    int32_t out_w;
    int32_t out_h;
    size_t num_chunks;
    uint16_t local_max[8][4];
};

static void proxy_dmax_worker(void *raw_ctx, size_t chunk_idx) {
    auto *ctx = static_cast<ProxyDmaxContext *>(raw_ctx);
    const int32_t r_start = static_cast<int32_t>(
        (static_cast<int64_t>(ctx->out_h) * static_cast<int64_t>(chunk_idx)) /
        static_cast<int64_t>(ctx->num_chunks));
    const int32_t r_end = static_cast<int32_t>(
        (static_cast<int64_t>(ctx->out_h) * static_cast<int64_t>(chunk_idx + 1)) /
        static_cast<int64_t>(ctx->num_chunks));
    const size_t stride = ctx->raw_stride_u16;
    const int32_t out_w = ctx->out_w;

    uint16_t m00 = 0, m01 = 0, m10 = 0, m11 = 0;
    for (int32_t r = r_start; r < r_end; ++r) {
        const uint16_t *r0 = ctx->raw_crop + static_cast<size_t>(2 * r) * stride;
        const uint16_t *r1 = r0 + stride;
        for (int32_t c = 0; c < out_w; ++c) {
            const size_t x = static_cast<size_t>(c) * 2;
            const uint16_t v00 = r0[x];
            const uint16_t v01 = r0[x + 1];
            const uint16_t v10 = r1[x];
            const uint16_t v11 = r1[x + 1];
            if (v00 > m00) m00 = v00;
            if (v01 > m01) m01 = v01;
            if (v10 > m10) m10 = v10;
            if (v11 > m11) m11 = v11;
        }
    }
    ctx->local_max[chunk_idx][0] = m00;
    ctx->local_max[chunk_idx][1] = m01;
    ctx->local_max[chunk_idx][2] = m10;
    ctx->local_max[chunk_idx][3] = m11;
}

struct ProxyBayerContext {
    const uint16_t *raw_crop;
    size_t raw_stride_u16;
    uint16_t *dst;
    int32_t out_w;
    int32_t out_h;
    size_t num_chunks;
    uint32_t black_q[4];
    float scale_q[4];
    int rgb_slot[4];
};

static void proxy_bayer_worker(void *raw_ctx, size_t chunk_idx) {
    auto *ctx = static_cast<ProxyBayerContext *>(raw_ctx);
    const int32_t r_start = static_cast<int32_t>(
        (static_cast<int64_t>(ctx->out_h) * static_cast<int64_t>(chunk_idx)) /
        static_cast<int64_t>(ctx->num_chunks));
    const int32_t r_end = static_cast<int32_t>(
        (static_cast<int64_t>(ctx->out_h) * static_cast<int64_t>(chunk_idx + 1)) /
        static_cast<int64_t>(ctx->num_chunks));
    const size_t stride = ctx->raw_stride_u16;
    const int32_t out_w = ctx->out_w;

    const uint32_t bl00 = ctx->black_q[0];
    const uint32_t bl01 = ctx->black_q[1];
    const uint32_t bl10 = ctx->black_q[2];
    const uint32_t bl11 = ctx->black_q[3];
    const float sc00 = ctx->scale_q[0];
    const float sc01 = ctx->scale_q[1];
    const float sc10 = ctx->scale_q[2];
    const float sc11 = ctx->scale_q[3];
    const int s00 = ctx->rgb_slot[0];
    const int s01 = ctx->rgb_slot[1];
    const int s10 = ctx->rgb_slot[2];
    const int s11 = ctx->rgb_slot[3];

    for (int32_t r = r_start; r < r_end; ++r) {
        const uint16_t *r0 = ctx->raw_crop + static_cast<size_t>(2 * r) * stride;
        const uint16_t *r1 = r0 + stride;
        uint16_t *out_row = ctx->dst + static_cast<size_t>(r) * static_cast<size_t>(out_w) * 3;
        for (int32_t c = 0; c < out_w; ++c) {
            const size_t x = static_cast<size_t>(c) * 2;
            uint16_t ch[4];

            const uint16_t raw00 = r0[x];
            if (raw00 <= bl00) {
                ch[s00] = 0;
            } else {
                const int v = static_cast<int>(static_cast<float>(raw00 - bl00) * sc00);
                ch[s00] = static_cast<uint16_t>(v <= 0 ? 0 : (v >= 65535 ? 65535 : v));
            }

            const uint16_t raw01 = r0[x + 1];
            if (raw01 <= bl01) {
                ch[s01] = 0;
            } else {
                const int v = static_cast<int>(static_cast<float>(raw01 - bl01) * sc01);
                ch[s01] = static_cast<uint16_t>(v <= 0 ? 0 : (v >= 65535 ? 65535 : v));
            }

            const uint16_t raw10 = r1[x];
            if (raw10 <= bl10) {
                ch[s10] = 0;
            } else {
                const int v = static_cast<int>(static_cast<float>(raw10 - bl10) * sc10);
                ch[s10] = static_cast<uint16_t>(v <= 0 ? 0 : (v >= 65535 ? 65535 : v));
            }

            const uint16_t raw11 = r1[x + 1];
            if (raw11 <= bl11) {
                ch[s11] = 0;
            } else {
                const int v = static_cast<int>(static_cast<float>(raw11 - bl11) * sc11);
                ch[s11] = static_cast<uint16_t>(v <= 0 ? 0 : (v >= 65535 ? 65535 : v));
            }

            uint16_t *px = out_row + static_cast<size_t>(c) * 3;
            px[0] = ch[0];
            px[1] = static_cast<uint16_t>((static_cast<uint32_t>(ch[1]) + static_cast<uint32_t>(ch[3])) >> 1);
            px[2] = ch[2];
        }
    }
}

/* Direct half-size Bayer-to-RGB16U fast path matching LibRaw dcraw_process()
 * with half_size=1, user_qual=0, output_bps=16, gamm={1,1}, use_camera_wb=1,
 * output_color=0, no_auto_bright=1, user_flip=0, highlight in {0, 1}.
 * Returns true if handled (check out_status), false to fall back to dcraw_process(). */
static bool try_fast_proxy_rgb16(LibRaw *lr,
                                 const HDRLibRawDecodeOptions &opts,
                                 int is_sraw,
                                 HDRLibRawImage *out_image,
                                 HDRLibRawStatus *out_status) {
    const int highlight_mode = (opts.highlight_mode >= 0 && opts.highlight_mode <= 9) ? opts.highlight_mode : 1;
    if (opts.mode != HDR_LIBRAW_MODE_PROXY_RGB16 ||
        opts.output_color_space != HDR_LIBRAW_CS_CAMERA_NATIVE ||
        (highlight_mode != 0 && highlight_mode != 1) ||
        is_sraw ||
        lr->imgdata.rawdata.raw_image == nullptr ||
        lr->imgdata.rawdata.color3_image != nullptr ||
        lr->imgdata.rawdata.color4_image != nullptr ||
        lr->imgdata.rawdata.float3_image != nullptr ||
        lr->imgdata.rawdata.float4_image != nullptr ||
        lr->imgdata.idata.filters <= 1000 ||
        lr->imgdata.idata.colors != 3 ||
        std::strncmp(lr->imgdata.idata.cdesc, "RGBG", 4) != 0 ||
        lr->imgdata.rawdata.ioparams.fuji_width != 0 ||
        lr->imgdata.rawdata.ioparams.zero_is_bad != 0 ||
        lr->imgdata.sizes.pixel_aspect < 0.995 ||
        lr->imgdata.sizes.pixel_aspect > 1.005 ||
        lr->imgdata.color.as_shot_wb_applied != 0 ||
        lr->imgdata.color.cam_mul[0] <= 0.00001f ||
        lr->imgdata.color.cam_mul[2] <= 0.00001f ||
        std::strncmp(lr->imgdata.idata.make, "Canon", 5) == 0) {
        return false;
    }

    const int32_t w = static_cast<int32_t>(lr->imgdata.sizes.width);
    const int32_t h = static_cast<int32_t>(lr->imgdata.sizes.height);
    const int32_t left = static_cast<int32_t>(lr->imgdata.sizes.left_margin);
    const int32_t top = static_cast<int32_t>(lr->imgdata.sizes.top_margin);
    const int32_t rw = static_cast<int32_t>(lr->imgdata.sizes.raw_width);
    const int32_t rh = static_cast<int32_t>(lr->imgdata.sizes.raw_height);

    if (w <= 0 || h <= 0 || (w & 1) != 0 || (h & 1) != 0 ||
        left < 0 || top < 0 || (left & 1) != 0 || (top & 1) != 0 ||
        left + w > rw || top + h > rh) {
        return false;
    }

    size_t raw_pitch_bytes = static_cast<size_t>(lr->imgdata.sizes.raw_pitch);
    if (raw_pitch_bytes < static_cast<size_t>(rw) * sizeof(uint16_t)) {
        raw_pitch_bytes = static_cast<size_t>(rw) * sizeof(uint16_t);
    }
    if ((raw_pitch_bytes & 1u) != 0) {
        return false;
    }
    const size_t raw_stride_u16 = raw_pitch_bytes / sizeof(uint16_t);

    const int c00 = lr->COLOR(0, 0);
    const int c01 = lr->COLOR(0, 1);
    const int c10 = lr->COLOR(1, 0);
    const int c11 = lr->COLOR(1, 1);
    if (c00 < 0 || c00 > 3 || c01 < 0 || c01 > 3 || c10 < 0 || c10 > 3 || c11 < 0 || c11 > 3) {
        return false;
    }
    const int mask = (1 << c00) | (1 << c01) | (1 << c10) | (1 << c11);
    if (mask != 0xF) {
        return false;
    }

    int64_t cblack_local[4] = {
        static_cast<int64_t>(lr->imgdata.color.cblack[0]),
        static_cast<int64_t>(lr->imgdata.color.cblack[1]),
        static_cast<int64_t>(lr->imgdata.color.cblack[2]),
        static_cast<int64_t>(lr->imgdata.color.cblack[3])
    };
    const unsigned cb_h = lr->imgdata.color.cblack[4];
    const unsigned cb_w = lr->imgdata.color.cblack[5];
    if (cb_h == 0 && cb_w == 0) {
        /* No repeating cblack block */
    } else if ((cb_h == 1 || cb_h == 2) && (cb_w == 1 || cb_w == 2)) {
        int clrs[4] = {c00, c01, c10, c11};
        int lastg = -1;
        int gcnt = 0;
        for (int c = 0; c < 4; ++c) {
            if (clrs[c] == 1) {
                ++gcnt;
                lastg = c;
            }
        }
        if (gcnt > 1 && lastg >= 0) {
            clrs[lastg] = 3;
        }
        for (int c = 0; c < 4; ++c) {
            const size_t idx = 6u + (static_cast<size_t>(c / 2) % cb_h) * cb_w + (static_cast<size_t>(c % 2) % cb_w);
            cblack_local[clrs[c]] += static_cast<int64_t>(lr->imgdata.color.cblack[idx]);
        }
    } else {
        return false;
    }

    int64_t min_cb = cblack_local[3];
    for (int c = 0; c < 3; ++c) {
        if (min_cb > cblack_local[c]) {
            min_cb = cblack_local[c];
        }
    }
    const int64_t common_black = static_cast<int64_t>(lr->imgdata.color.black) + min_cb;
    int64_t maximum = static_cast<int64_t>(lr->imgdata.color.maximum) - common_black;
    if (maximum <= 0) {
        return false;
    }

    uint32_t cblack[4];
    for (int i = 0; i < 4; ++i) {
        const int64_t bl_val = (cblack_local[i] - min_cb) + common_black;
        cblack[i] = (bl_val > 0) ? static_cast<uint32_t>(bl_val) : 0u;
    }

    const int32_t out_w = w >> 1;
    const int32_t out_h = h >> 1;
    if (out_w <= 0 || out_h <= 0 ||
        static_cast<size_t>(out_w) > (SIZE_MAX / (3u * sizeof(uint16_t))) / static_cast<size_t>(out_h)) {
        set_image_error(out_image, HDR_LIBRAW_ERR_MEMORY, 0, "Proxy output buffer size overflow");
        *out_status = HDR_LIBRAW_ERR_MEMORY;
        return true;
    }
    const size_t out_bytes = static_cast<size_t>(out_w) * static_cast<size_t>(out_h) * 3u * sizeof(uint16_t);

    const uint16_t *raw_base = lr->imgdata.rawdata.raw_image;
    const uint16_t *raw_crop = raw_base + static_cast<size_t>(top) * raw_stride_u16 + static_cast<size_t>(left);

    const int threads = std::min(std::max(opts.max_threads, 1), 8);
    const size_t num_chunks = std::min(static_cast<size_t>(threads), static_cast<size_t>(out_h));
    dispatch_queue_t q = (num_chunks > 1)
                             ? dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0)
                             : nullptr;

    libraw_decoder_info_t di{};
    lr->get_decoder_info(&di);
    if (!(di.decoder_flags & LIBRAW_DECODER_FIXEDMAXC) &&
        lr->imgdata.params.adjust_maximum_thr >= 0.00001f) {
        ProxyDmaxContext dmax_ctx{};
        dmax_ctx.raw_crop = raw_crop;
        dmax_ctx.raw_stride_u16 = raw_stride_u16;
        dmax_ctx.out_w = out_w;
        dmax_ctx.out_h = out_h;
        dmax_ctx.num_chunks = num_chunks;
        if (num_chunks > 1) {
            dispatch_apply_f(num_chunks, q, &dmax_ctx, proxy_dmax_worker);
        } else {
            proxy_dmax_worker(&dmax_ctx, 0);
        }

        uint16_t max_raw[4] = {0, 0, 0, 0};
        for (size_t chunk = 0; chunk < num_chunks; ++chunk) {
            for (int p = 0; p < 4; ++p) {
                if (dmax_ctx.local_max[chunk][p] > max_raw[p]) {
                    max_raw[p] = dmax_ctx.local_max[chunk][p];
                }
            }
        }
        const int quad_c[4] = {c00, c01, c10, c11};
        int64_t data_max = 0;
        for (int p = 0; p < 4; ++p) {
            int64_t sub = static_cast<int64_t>(max_raw[p]) - static_cast<int64_t>(cblack[quad_c[p]]);
            if (sub > data_max) {
                data_max = sub;
            }
        }
        const float thr = lr->imgdata.params.adjust_maximum_thr;
        const float auto_threshold = (thr > 0.99999f) ? LIBRAW_DEFAULT_ADJUST_MAXIMUM_THRESHOLD : thr;
        if (data_max > 0 &&
            data_max < maximum &&
            static_cast<float>(data_max) > static_cast<float>(maximum) * auto_threshold) {
            maximum = data_max;
        }
    }

    float pre_mul[4];
    std::memcpy(pre_mul, lr->imgdata.color.cam_mul, sizeof(pre_mul));
    if (pre_mul[1] == 0.0f) {
        pre_mul[1] = 1.0f;
    }
    if (pre_mul[3] == 0.0f) {
        pre_mul[3] = pre_mul[1];
    }
    double dmin = DBL_MAX;
    double dmax_wb = 0.0;
    for (int c = 0; c < 4; ++c) {
        if (dmin > pre_mul[c]) dmin = pre_mul[c];
        if (dmax_wb < pre_mul[c]) dmax_wb = pre_mul[c];
    }
    if (highlight_mode == 0) {
        dmax_wb = dmin;
    }
    float scale_mul[4];
    if (dmax_wb > 0.00001 && maximum > 0) {
        const float denom = static_cast<float>(dmax_wb);
        const float max_f = static_cast<float>(maximum);
        for (int c = 0; c < 4; ++c) {
            pre_mul[c] /= denom;
            scale_mul[c] = pre_mul[c] * 65535.f / max_f;
        }
    } else {
        for (int c = 0; c < 4; ++c) {
            scale_mul[c] = 1.0f;
        }
    }

    uint16_t *dst = static_cast<uint16_t *>(std::malloc(out_bytes));
    if (!dst) {
        set_image_error(out_image, HDR_LIBRAW_ERR_MEMORY, 0, "Out of memory allocating RGB16 proxy buffer");
        *out_status = HDR_LIBRAW_ERR_MEMORY;
        return true;
    }

    ProxyBayerContext bayer_ctx{};
    bayer_ctx.raw_crop = raw_crop;
    bayer_ctx.raw_stride_u16 = raw_stride_u16;
    bayer_ctx.dst = dst;
    bayer_ctx.out_w = out_w;
    bayer_ctx.out_h = out_h;
    bayer_ctx.num_chunks = num_chunks;
    bayer_ctx.rgb_slot[0] = c00;
    bayer_ctx.rgb_slot[1] = c01;
    bayer_ctx.rgb_slot[2] = c10;
    bayer_ctx.rgb_slot[3] = c11;
    for (int p = 0; p < 4; ++p) {
        const int ch = bayer_ctx.rgb_slot[p];
        bayer_ctx.black_q[p] = cblack[ch];
        bayer_ctx.scale_q[p] = scale_mul[ch];
    }

    if (num_chunks > 1) {
        dispatch_apply_f(num_chunks, q, &bayer_ctx, proxy_bayer_worker);
    } else {
        proxy_bayer_worker(&bayer_ctx, 0);
    }

    out_image->rgb16_data = dst;
    out_image->data_bytes = out_bytes;
    out_image->payload_kind = HDR_LIBRAW_PAYLOAD_RGB16U;
    out_image->color_space = HDR_LIBRAW_CS_CAMERA_NATIVE;
    out_image->cfa_pattern = HDR_LIBRAW_CFA_UNKNOWN;
    out_image->bits_per_sample = 16;
    out_image->width = out_w;
    out_image->height = out_h;
    out_image->demosaic_used = HDR_LIBRAW_DEMOSAIC_NONE;

    *out_status = HDR_LIBRAW_OK;
    return true;
}

static void chiaro_interpolate_bayer_cb(void *data) {
    if (!data) {
        return;
    }
    auto *lr = static_cast<ChiaroLibRaw *>(data);
    const int w = static_cast<int>(lr->imgdata.sizes.width);
    const int h = static_cast<int>(lr->imgdata.sizes.height);
    if (w <= 0 || h <= 0 || lr->imgdata.image == nullptr || lr->imgdata.idata.colors != 3) {
        lr->run_ahd_fallback();
        return;
    }

    const unsigned cfarray[2][2] = {
        { static_cast<unsigned>(lr->fc_at(0, 0)), static_cast<unsigned>(lr->fc_at(0, 1)) },
        { static_cast<unsigned>(lr->fc_at(1, 0)), static_cast<unsigned>(lr->fc_at(1, 1)) }
    };
    for (int r = 0; r < 2; ++r) {
        for (int c = 0; c < 2; ++c) {
            if (cfarray[r][c] > 2u) {
                lr->run_ahd_fallback();
                return;
            }
        }
    }
    if ((cfarray[0][0] & 1u) != (cfarray[1][1] & 1u)) {
        lr->run_ahd_fallback();
        return;
    }

    // Serialize the temporary float32 R/G/B/raw demosaic planes (~524 MB for 33MP)
    // across concurrent LibRaw decode workers to bound batch peak RSS <= 4.5 GiB.
    static std::mutex bayer_planes_mutex;
    std::lock_guard<std::mutex> bayer_planes_lock(bayer_planes_mutex);

    const size_t row_stride = static_cast<size_t>(w) + 16u;
    const size_t total_floats = static_cast<size_t>(h) * row_stride;
    std::vector<float> raw_plane(total_floats, 0.0f);
    std::vector<float> red_plane(total_floats, 0.0f);
    std::vector<float> green_plane(total_floats, 0.0f);
    std::vector<float> blue_plane(total_floats, 0.0f);

    std::vector<float *> raw_rows(static_cast<size_t>(h), nullptr);
    std::vector<float *> red_rows(static_cast<size_t>(h), nullptr);
    std::vector<float *> green_rows(static_cast<size_t>(h), nullptr);
    std::vector<float *> blue_rows(static_cast<size_t>(h), nullptr);

    for (int row = 0; row < h; ++row) {
        const size_t off = static_cast<size_t>(row) * row_stride;
        float *raw_row = raw_plane.data() + off;
        raw_rows[static_cast<size_t>(row)] = raw_row;
        red_rows[static_cast<size_t>(row)] = red_plane.data() + off;
        green_rows[static_cast<size_t>(row)] = green_plane.data() + off;
        blue_rows[static_cast<size_t>(row)] = blue_plane.data() + off;

        for (int col = 0; col < w; ++col) {
            const int ch = lr->fc_at(row, col);
            const size_t px_idx = static_cast<size_t>(row) * static_cast<size_t>(w) + static_cast<size_t>(col);
            raw_row[col] = static_cast<float>(lr->imgdata.image[px_idx][ch]);
        }
    }

    auto never_cancel = [](double) -> bool { return false; };
    rpError err = RP_WRONG_CFA;
    if (lr->requested_demosaic == HDR_LIBRAW_DEMOSAIC_LMMSE) {
        err = lmmse_demosaic(
            w, h,
            raw_rows.data(),
            red_rows.data(),
            green_rows.data(),
            blue_rows.data(),
            cfarray,
            never_cancel,
            2
        );
    } else {
        err = amaze_demosaic(
            w, h, 0, 0, w, h,
            raw_rows.data(),
            red_rows.data(),
            green_rows.data(),
            blue_rows.data(),
            cfarray,
            never_cancel,
            1.0,
            0,
            65535.0f,
            65535.0f,
            2,
            false
        );
    }

    if (err != RP_NO_ERROR) {
        lr->run_ahd_fallback();
        return;
    }

    auto clamp_u16 = [](float v) -> ushort {
        if (!std::isfinite(v)) {
            return 0;
        }
        long lv = std::lroundf(v);
        if (lv <= 0) {
            return 0;
        }
        if (lv >= 65535) {
            return 65535;
        }
        return static_cast<ushort>(lv);
    };

    for (int row = 0; row < h; ++row) {
        const float *r_row = red_rows[static_cast<size_t>(row)];
        const float *g_row = green_rows[static_cast<size_t>(row)];
        const float *b_row = blue_rows[static_cast<size_t>(row)];
        for (int col = 0; col < w; ++col) {
            const size_t px_idx = static_cast<size_t>(row) * static_cast<size_t>(w) + static_cast<size_t>(col);
            lr->imgdata.image[px_idx][0] = clamp_u16(r_row[col]);
            lr->imgdata.image[px_idx][1] = clamp_u16(g_row[col]);
            lr->imgdata.image[px_idx][2] = clamp_u16(b_row[col]);
        }
    }
    lr->bayer_callback_invoked = true;
}

static HDRLibRawStatus run_decode(ChiaroLibRaw *lr,
                                  const ExifCallbackContext &cb_ctx,
                                  const HDRLibRawDecodeOptions &opts,
                                  HDRLibRawImage *out_image) {
    HDRLibRawStatus opt_status = validate_decode_options(opts, out_image);
    if (opt_status != HDR_LIBRAW_OK) {
        return opt_status;
    }

    if (opts.apply_inset_crop != 0) {
        lr->adjust_to_raw_inset_crop(1, 0.55f);
    }

    int is_sraw = lr->is_sraw();
    out_image->is_lossless_ms = is_sraw ? 1 : 0;

    int unpack_err = lr->unpack();
    if (unpack_err != LIBRAW_SUCCESS) {
        set_image_error(out_image, HDR_LIBRAW_ERR_UNPACK, unpack_err, LibRaw::strerror(unpack_err));
        return HDR_LIBRAW_ERR_UNPACK;
    }

    out_image->raw_width = static_cast<int32_t>(lr->imgdata.sizes.raw_width);
    out_image->raw_height = static_cast<int32_t>(lr->imgdata.sizes.raw_height);
    out_image->crop_left = static_cast<int32_t>(lr->imgdata.sizes.left_margin);
    out_image->crop_top = static_cast<int32_t>(lr->imgdata.sizes.top_margin);

    populate_metadata_and_matrices(lr, cb_ctx, out_image);

    const bool can_extract_bayer =
        (opts.mode == HDR_LIBRAW_MODE_BAYER_OR_SRAW) &&
        !is_sraw &&
        (lr->imgdata.rawdata.raw_image != nullptr) &&
        (lr->imgdata.idata.filters != 0);

    if (can_extract_bayer) {
        int32_t w = static_cast<int32_t>(lr->imgdata.sizes.width);
        int32_t h = static_cast<int32_t>(lr->imgdata.sizes.height);
        int32_t left = static_cast<int32_t>(lr->imgdata.sizes.left_margin);
        int32_t top = static_cast<int32_t>(lr->imgdata.sizes.top_margin);
        int32_t rw = static_cast<int32_t>(lr->imgdata.sizes.raw_width);
        int32_t rh = static_cast<int32_t>(lr->imgdata.sizes.raw_height);

        if (w <= 0 || h <= 0 || left < 0 || top < 0 || left + w > rw || top + h > rh) {
            set_image_error(out_image, HDR_LIBRAW_ERR_PROCESS, 0, "Invalid raw crop bounds");
            return HDR_LIBRAW_ERR_PROCESS;
        }

        size_t bytes = static_cast<size_t>(w) * static_cast<size_t>(h) * sizeof(uint16_t);
        uint16_t *dst = static_cast<uint16_t *>(std::malloc(bytes));
        if (!dst) {
            set_image_error(out_image, HDR_LIBRAW_ERR_MEMORY, 0, "Out of memory allocating Bayer buffer");
            return HDR_LIBRAW_ERR_MEMORY;
        }

        size_t raw_pitch_bytes = static_cast<size_t>(lr->imgdata.sizes.raw_pitch);
        if (raw_pitch_bytes < static_cast<size_t>(rw) * sizeof(uint16_t)) {
            raw_pitch_bytes = static_cast<size_t>(rw) * sizeof(uint16_t);
        }
        const uint8_t *raw_base = reinterpret_cast<const uint8_t *>(lr->imgdata.rawdata.raw_image);
        const size_t row_bytes = static_cast<size_t>(w) * sizeof(uint16_t);
        for (int32_t r = 0; r < h; ++r) {
            const uint8_t *src_row = raw_base +
                                     static_cast<size_t>(top + r) * raw_pitch_bytes +
                                     static_cast<size_t>(left) * sizeof(uint16_t);
            std::memcpy(reinterpret_cast<uint8_t *>(dst) + static_cast<size_t>(r) * row_bytes, src_row, row_bytes);
        }

        out_image->rgb16_data = dst;
        out_image->data_bytes = bytes;
        out_image->payload_kind = HDR_LIBRAW_PAYLOAD_BAYER16U;
        out_image->color_space = HDR_LIBRAW_CS_CAMERA_NATIVE;
        out_image->cfa_pattern = detect_cfa_pattern(lr, top, left);
        out_image->bits_per_sample = (lr->imgdata.color.raw_bps > 0) ? static_cast<int32_t>(lr->imgdata.color.raw_bps) : 14;
        out_image->width = w;
        out_image->height = h;
        out_image->demosaic_used = HDR_LIBRAW_DEMOSAIC_NONE;
        return HDR_LIBRAW_OK;
    }

    HDRLibRawStatus fast_proxy_status = HDR_LIBRAW_OK;
    if (try_fast_proxy_rgb16(lr, opts, is_sraw, out_image, &fast_proxy_status)) {
        return fast_proxy_status;
    }

    /* LINEAR_RGB16, PROXY_RGB16, or sRAW fallback */
    lr->imgdata.params.no_auto_bright = 1;
    lr->imgdata.params.highlight = (opts.highlight_mode >= 0 && opts.highlight_mode <= 9) ? opts.highlight_mode : 1;
    lr->imgdata.params.output_bps = 16;
    lr->imgdata.params.gamm[0] = 1.0;
    lr->imgdata.params.gamm[1] = 1.0;
    lr->imgdata.params.use_camera_wb = 1;
    lr->imgdata.params.user_flip = 0;
    lr->imgdata.params.output_color = (opts.output_color_space == HDR_LIBRAW_CS_LINEAR_REC2020) ? 8 : 0;

    lr->requested_demosaic = opts.demosaic_algorithm;
    lr->bayer_callback_invoked = false;
    lr->fallback_to_ahd = false;

    if (opts.mode == HDR_LIBRAW_MODE_PROXY_RGB16) {
        lr->set_bayer_demosaic_callback(nullptr);
        lr->imgdata.params.half_size = 1;
        lr->imgdata.params.user_qual = 0;
    } else if (is_sraw) {
        lr->set_bayer_demosaic_callback(nullptr);
        lr->imgdata.params.half_size = 0;
        lr->imgdata.params.user_qual = 3;
    } else {
        lr->imgdata.params.half_size = 0;
        switch (opts.demosaic_algorithm) {
            case HDR_LIBRAW_DEMOSAIC_AMAZE:
            case HDR_LIBRAW_DEMOSAIC_LMMSE:
                lr->set_bayer_demosaic_callback(chiaro_interpolate_bayer_cb);
                lr->imgdata.params.user_qual = 3; /* Safe fallback if filters <= 1000 */
                break;
            case HDR_LIBRAW_DEMOSAIC_DCB:
                lr->set_bayer_demosaic_callback(nullptr);
                lr->imgdata.params.user_qual = 4;
                lr->imgdata.params.dcb_iterations = 1;
                lr->imgdata.params.dcb_enhance_fl = 1;
                break;
            case HDR_LIBRAW_DEMOSAIC_DHT:
                lr->set_bayer_demosaic_callback(nullptr);
                lr->imgdata.params.user_qual = 11;
                break;
            case HDR_LIBRAW_DEMOSAIC_AHD:
            default:
                lr->set_bayer_demosaic_callback(nullptr);
                lr->imgdata.params.user_qual = 3;
                break;
        }
    }

    int proc_err = lr->dcraw_process();
    if (proc_err != LIBRAW_SUCCESS) {
        set_image_error(out_image, HDR_LIBRAW_ERR_PROCESS, proc_err, LibRaw::strerror(proc_err));
        return HDR_LIBRAW_ERR_PROCESS;
    }

    int mem_err = LIBRAW_SUCCESS;
    libraw_processed_image_t *mem_img = lr->dcraw_make_mem_image(&mem_err);
    if (!mem_img || mem_err != LIBRAW_SUCCESS) {
        if (mem_img) {
            LibRaw::dcraw_clear_mem(mem_img);
        }
        set_image_error(out_image, HDR_LIBRAW_ERR_PROCESS, mem_err, LibRaw::strerror(mem_err));
        return HDR_LIBRAW_ERR_PROCESS;
    }

    if (mem_img->type != LIBRAW_IMAGE_BITMAP || mem_img->bits != 16 || mem_img->colors != 3 || mem_img->data_size == 0) {
        LibRaw::dcraw_clear_mem(mem_img);
        set_image_error(out_image, HDR_LIBRAW_ERR_UNSUPPORTED, 0, "Unexpected processed image format");
        return HDR_LIBRAW_ERR_UNSUPPORTED;
    }

    uint16_t *dst = static_cast<uint16_t *>(std::malloc(mem_img->data_size));
    if (!dst) {
        LibRaw::dcraw_clear_mem(mem_img);
        set_image_error(out_image, HDR_LIBRAW_ERR_MEMORY, 0, "Out of memory allocating RGB16 buffer");
        return HDR_LIBRAW_ERR_MEMORY;
    }
    std::memcpy(dst, mem_img->data, mem_img->data_size);

    out_image->rgb16_data = dst;
    out_image->data_bytes = static_cast<size_t>(mem_img->data_size);
    out_image->payload_kind = HDR_LIBRAW_PAYLOAD_RGB16U;
    out_image->color_space = (lr->imgdata.params.output_color == 8) ? HDR_LIBRAW_CS_LINEAR_REC2020 : HDR_LIBRAW_CS_CAMERA_NATIVE;
    out_image->cfa_pattern = HDR_LIBRAW_CFA_UNKNOWN;
    out_image->bits_per_sample = 16;
    out_image->width = static_cast<int32_t>(mem_img->width);
    out_image->height = static_cast<int32_t>(mem_img->height);
    if (opts.mode == HDR_LIBRAW_MODE_PROXY_RGB16 || is_sraw) {
        out_image->demosaic_used = HDR_LIBRAW_DEMOSAIC_NONE;
    } else if (lr->fallback_to_ahd || (lr->imgdata.process_warnings & LIBRAW_WARN_FALLBACK_TO_AHD) != 0) {
        out_image->demosaic_used = HDR_LIBRAW_DEMOSAIC_AHD;
    } else {
        out_image->demosaic_used = opts.demosaic_algorithm;
    }

    LibRaw::dcraw_clear_mem(mem_img);
    return HDR_LIBRAW_OK;
}

} /* namespace */

extern "C" {

const char *hdr_libraw_version(void) {
    return libraw_version();
}

HDRLibRawDecodeOptions hdr_libraw_default_options(void) {
    HDRLibRawDecodeOptions opts;
    opts.mode = HDR_LIBRAW_MODE_BAYER_OR_SRAW;
    opts.output_color_space = HDR_LIBRAW_CS_CAMERA_NATIVE;
    opts.highlight_mode = 1;
    opts.max_threads = 2;
    opts.apply_inset_crop = 1;
    opts.sraw_no_rgb = 0;
    opts.demosaic_algorithm = HDR_LIBRAW_DEMOSAIC_AMAZE;
    return opts;
}

HDRLibRawStatus hdr_libraw_decode_file(const char *path,
                                       const HDRLibRawDecodeOptions *options,
                                       HDRLibRawImage *out_image) {
    if (!out_image) {
        return HDR_LIBRAW_ERR_INVALID_ARG;
    }
    std::memset(out_image, 0, sizeof(*out_image));
    if (!path || path[0] == '\0') {
        set_image_error(out_image, HDR_LIBRAW_ERR_INVALID_ARG, 0, "Null or empty file path");
        return HDR_LIBRAW_ERR_INVALID_ARG;
    }

    HDRLibRawDecodeOptions opts = options ? *options : hdr_libraw_default_options();
    HDRLibRawStatus opt_status = validate_decode_options(opts, out_image);
    if (opt_status != HDR_LIBRAW_OK) {
        return opt_status;
    }

    try {
        std::unique_ptr<ChiaroLibRaw> lr(new ChiaroLibRaw(LIBRAW_OPTIONS_NO_DATAERR_CALLBACK));
        ExifCallbackContext cb_ctx;
        lr->set_exifparser_handler(hdr_exif_parser_cb, &cb_ctx);

        int open_err = lr->open_file(path);
        if (open_err != LIBRAW_SUCCESS) {
            set_image_error(out_image, HDR_LIBRAW_ERR_OPEN, open_err, LibRaw::strerror(open_err));
            return HDR_LIBRAW_ERR_OPEN;
        }

        HDRLibRawStatus status = run_decode(lr.get(), cb_ctx, opts, out_image);
        if (status != HDR_LIBRAW_OK) {
            uint16_t *tmp_data = out_image->rgb16_data;
            out_image->rgb16_data = nullptr;
            std::free(tmp_data);
            HDRLibRawExifMetadata saved_exif = out_image->exif;
            std::memset(&out_image->exif, 0, sizeof(out_image->exif));
            std::free(saved_exif.make);
            std::free(saved_exif.model);
            std::free(saved_exif.lens_make);
            std::free(saved_exif.lens_model);
            std::free(saved_exif.date_time_original);
            std::free(saved_exif.offset_time_original);
            std::free(saved_exif.subsec_time_original);
            std::free(saved_exif.gps_latitude_ref);
            std::free(saved_exif.gps_longitude_ref);
            std::free(saved_exif.gps_timestamp);
            std::free(saved_exif.gps_date_stamp);
        }
        return status;
    } catch (const std::exception &e) {
        hdr_libraw_free_image(out_image);
        set_image_error(out_image, HDR_LIBRAW_ERR_INTERNAL, 0, e.what());
        return HDR_LIBRAW_ERR_INTERNAL;
    } catch (...) {
        hdr_libraw_free_image(out_image);
        set_image_error(out_image, HDR_LIBRAW_ERR_INTERNAL, 0, "Unknown C++ exception in LibRaw decode");
        return HDR_LIBRAW_ERR_INTERNAL;
    }
}

HDRLibRawStatus hdr_libraw_decode_buffer(const void *buffer,
                                         size_t length,
                                         const HDRLibRawDecodeOptions *options,
                                         HDRLibRawImage *out_image) {
    if (!out_image) {
        return HDR_LIBRAW_ERR_INVALID_ARG;
    }
    std::memset(out_image, 0, sizeof(*out_image));
    if (!buffer || length == 0) {
        set_image_error(out_image, HDR_LIBRAW_ERR_INVALID_ARG, 0, "Null or empty buffer");
        return HDR_LIBRAW_ERR_INVALID_ARG;
    }

    HDRLibRawDecodeOptions opts = options ? *options : hdr_libraw_default_options();
    HDRLibRawStatus opt_status = validate_decode_options(opts, out_image);
    if (opt_status != HDR_LIBRAW_OK) {
        return opt_status;
    }

    try {
        std::unique_ptr<ChiaroLibRaw> lr(new ChiaroLibRaw(LIBRAW_OPTIONS_NO_DATAERR_CALLBACK));
        ExifCallbackContext cb_ctx;
        lr->set_exifparser_handler(hdr_exif_parser_cb, &cb_ctx);

        int open_err = lr->open_buffer(buffer, length);
        if (open_err != LIBRAW_SUCCESS) {
            set_image_error(out_image, HDR_LIBRAW_ERR_OPEN, open_err, LibRaw::strerror(open_err));
            return HDR_LIBRAW_ERR_OPEN;
        }

        HDRLibRawStatus status = run_decode(lr.get(), cb_ctx, opts, out_image);
        if (status != HDR_LIBRAW_OK) {
            uint16_t *tmp_data = out_image->rgb16_data;
            out_image->rgb16_data = nullptr;
            std::free(tmp_data);
            HDRLibRawExifMetadata saved_exif = out_image->exif;
            std::memset(&out_image->exif, 0, sizeof(out_image->exif));
            std::free(saved_exif.make);
            std::free(saved_exif.model);
            std::free(saved_exif.lens_make);
            std::free(saved_exif.lens_model);
            std::free(saved_exif.date_time_original);
            std::free(saved_exif.offset_time_original);
            std::free(saved_exif.subsec_time_original);
            std::free(saved_exif.gps_latitude_ref);
            std::free(saved_exif.gps_longitude_ref);
            std::free(saved_exif.gps_timestamp);
            std::free(saved_exif.gps_date_stamp);
        }
        return status;
    } catch (const std::exception &e) {
        hdr_libraw_free_image(out_image);
        set_image_error(out_image, HDR_LIBRAW_ERR_INTERNAL, 0, e.what());
        return HDR_LIBRAW_ERR_INTERNAL;
    } catch (...) {
        hdr_libraw_free_image(out_image);
        set_image_error(out_image, HDR_LIBRAW_ERR_INTERNAL, 0, "Unknown C++ exception in LibRaw decode buffer");
        return HDR_LIBRAW_ERR_INTERNAL;
    }
}

void hdr_libraw_free_image(HDRLibRawImage *image) {
    if (!image) {
        return;
    }
    std::free(image->rgb16_data);
    std::free(image->exif.make);
    std::free(image->exif.model);
    std::free(image->exif.lens_make);
    std::free(image->exif.lens_model);
    std::free(image->exif.date_time_original);
    std::free(image->exif.offset_time_original);
    std::free(image->exif.subsec_time_original);
    std::free(image->exif.gps_latitude_ref);
    std::free(image->exif.gps_longitude_ref);
    std::free(image->exif.gps_timestamp);
    std::free(image->exif.gps_date_stamp);
    std::memset(image, 0, sizeof(HDRLibRawImage));
}

void clraw_free_image(HDRLibRawImage *image) {
    hdr_libraw_free_image(image);
}

} /* extern "C" */
