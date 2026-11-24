#include "CUltraHDRBridge.h"
#include "ultrahdr_api.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory>
#include <string>
#include <vector>

namespace {

struct EncoderDeleter {
    void operator()(uhdr_codec_private_t *p) const {
        if (p) {
            uhdr_release_encoder(p);
        }
    }
};

struct DecoderDeleter {
    void operator()(uhdr_codec_private_t *p) const {
        if (p) {
            uhdr_release_decoder(p);
        }
    }
};

static void set_error(char **out_error, const char *msg) {
    if (!out_error) {
        return;
    }
    if (*out_error) {
        std::free(*out_error);
        *out_error = nullptr;
    }
    if (!msg) {
        msg = "Unknown UltraHDR error";
    }
    size_t len = std::strlen(msg);
    char *copy = static_cast<char *>(std::malloc(len + 1));
    if (copy) {
        std::memcpy(copy, msg, len + 1);
        *out_error = copy;
    }
}

static void set_uhdr_error(char **out_error, const uhdr_error_info_t &err) {
    if (err.has_detail && err.detail[0] != '\0') {
        set_error(out_error, err.detail);
    } else {
        char buf[64];
        std::snprintf(buf, sizeof(buf), "libultrahdr error code %d", static_cast<int>(err.error_code));
        set_error(out_error, buf);
    }
}

static uhdr_color_gamut_t map_gamut_to_uhdr(HDRUltraHDRColorGamut cg) {
    switch (cg) {
        case HDR_UHDR_CG_BT_709: return UHDR_CG_BT_709;
        case HDR_UHDR_CG_DISPLAY_P3: return UHDR_CG_DISPLAY_P3;
        case HDR_UHDR_CG_BT_2100: return UHDR_CG_BT_2100;
        case HDR_UHDR_CG_UNSPECIFIED:
        default:
            return UHDR_CG_UNSPECIFIED;
    }
}

static HDRUltraHDRColorGamut map_gamut_from_uhdr(uhdr_color_gamut_t cg) {
    switch (cg) {
        case UHDR_CG_BT_709: return HDR_UHDR_CG_BT_709;
        case UHDR_CG_DISPLAY_P3: return HDR_UHDR_CG_DISPLAY_P3;
        case UHDR_CG_BT_2100: return HDR_UHDR_CG_BT_2100;
        case UHDR_CG_UNSPECIFIED:
        default:
            return HDR_UHDR_CG_UNSPECIFIED;
    }
}

static void copy_metadata_from_uhdr(const uhdr_gainmap_metadata_t *src,
                                    HDRUltraHDRGainMapMetadata *dst) {
    if (!src || !dst) {
        return;
    }
    for (int i = 0; i < 3; ++i) {
        dst->max_content_boost[i] = src->max_content_boost[i];
        dst->min_content_boost[i] = src->min_content_boost[i];
        dst->gamma[i] = src->gamma[i];
        dst->offset_sdr[i] = src->offset_sdr[i];
        dst->offset_hdr[i] = src->offset_hdr[i];
    }
    dst->hdr_capacity_min = src->hdr_capacity_min;
    dst->hdr_capacity_max = src->hdr_capacity_max;
    dst->use_base_cg = src->use_base_cg;
}

static bool is_tiff_header(const uint8_t *p) {
    return (p[0] == 'I' && p[1] == 'I' && p[2] == 0x2A && p[3] == 0x00) ||
           (p[0] == 'M' && p[1] == 'M' && p[2] == 0x00 && p[3] == 0x2A);
}

static bool normalize_exif_payload(const uint8_t *exif_data,
                                   size_t exif_size,
                                   std::vector<uint8_t> &out_exif,
                                   char **out_error) {
    static constexpr uint8_t kExifPrefix[6] = {'E', 'x', 'i', 'f', 0, 0};
    out_exif.clear();

    if (exif_size >= 14 &&
        std::memcmp(exif_data, kExifPrefix, 6) == 0 &&
        is_tiff_header(exif_data + 6)) {
        out_exif.assign(exif_data, exif_data + exif_size);
    } else if (exif_size >= 8 && is_tiff_header(exif_data)) {
        out_exif.reserve(6 + exif_size);
        out_exif.insert(out_exif.end(), kExifPrefix, kExifPrefix + 6);
        out_exif.insert(out_exif.end(), exif_data, exif_data + exif_size);
    } else {
        set_error(out_error, "Invalid EXIF payload: expected TIFF header (II*/MM*) or Exif\\0\\0 prefix");
        return false;
    }

    if (out_exif.size() + 2 > 65535) {
        set_error(out_error, "EXIF payload exceeds JPEG APP1 65533-byte limit");
        return false;
    }
    return true;
}

static bool prepare_base_jpeg_with_exif(const uint8_t *base_data,
                                        size_t base_size,
                                        const uint8_t *exif_data,
                                        size_t exif_size,
                                        std::vector<uint8_t> &out_jpeg,
                                        char **out_error) {
    if (!base_data || base_size < 4 || base_data[0] != 0xFF || base_data[1] != 0xD8) {
        set_error(out_error, "Base JPEG does not start with valid SOI (FF D8)");
        return false;
    }

    std::vector<uint8_t> normalized_exif;
    if (!normalize_exif_payload(exif_data, exif_size, normalized_exif, out_error)) {
        return false;
    }

    out_jpeg.clear();
    out_jpeg.reserve(base_size + normalized_exif.size() + 4);
    out_jpeg.push_back(0xFF);
    out_jpeg.push_back(0xD8);

    size_t pos = 2;
    bool inserted_exif = false;

    auto emit_app1_exif = [&]() {
        if (inserted_exif) {
            return;
        }
        uint16_t seg_len = static_cast<uint16_t>(2 + normalized_exif.size());
        out_jpeg.push_back(0xFF);
        out_jpeg.push_back(0xE1);
        out_jpeg.push_back(static_cast<uint8_t>((seg_len >> 8) & 0xFF));
        out_jpeg.push_back(static_cast<uint8_t>(seg_len & 0xFF));
        out_jpeg.insert(out_jpeg.end(), normalized_exif.begin(), normalized_exif.end());
        inserted_exif = true;
    };

    while (pos < base_size) {
        if (base_data[pos] != 0xFF) {
            emit_app1_exif();
            out_jpeg.insert(out_jpeg.end(), base_data + pos, base_data + base_size);
            break;
        }
        size_t marker_start = pos;
        while (pos < base_size && base_data[pos] == 0xFF) {
            ++pos;
        }
        if (pos >= base_size) {
            emit_app1_exif();
            out_jpeg.insert(out_jpeg.end(), base_data + marker_start, base_data + base_size);
            break;
        }
        uint8_t marker = base_data[pos++];

        if (marker == 0x00) {
            emit_app1_exif();
            out_jpeg.insert(out_jpeg.end(), base_data + marker_start, base_data + base_size);
            break;
        }
        if (marker == 0xDA || marker == 0xD9) { /* SOS or EOI */
            emit_app1_exif();
            out_jpeg.insert(out_jpeg.end(), base_data + marker_start, base_data + base_size);
            break;
        }
        if ((marker >= 0xD0 && marker <= 0xD7) || marker == 0x01) { /* Standalone markers */
            out_jpeg.insert(out_jpeg.end(), base_data + marker_start, base_data + pos);
            continue;
        }

        if (pos + 2 > base_size) {
            set_error(out_error, "Truncated JPEG marker segment in base JPEG");
            return false;
        }
        uint16_t seg_len = static_cast<uint16_t>((static_cast<uint16_t>(base_data[pos]) << 8) |
                                                 static_cast<uint16_t>(base_data[pos + 1]));
        if (seg_len < 2 || pos + seg_len > base_size) {
            set_error(out_error, "Invalid JPEG segment length in base JPEG");
            return false;
        }
        size_t seg_end = pos + seg_len;

        if (marker == 0xE0) { /* Preserve APP0 before spliced APP1 Exif */
            out_jpeg.insert(out_jpeg.end(), base_data + marker_start, base_data + seg_end);
            emit_app1_exif();
        } else if (marker == 0xE1 && seg_len >= 8 &&
                   std::memcmp(base_data + pos + 2, "Exif\0\0", 6) == 0) {
            /* Strip existing APP1 Exif\0\0 */
            emit_app1_exif();
        } else {
            emit_app1_exif();
            out_jpeg.insert(out_jpeg.end(), base_data + marker_start, base_data + seg_end);
        }
        pos = seg_end;
    }

    emit_app1_exif();
    return true;
}

static int parse_jpeg_sof_channels(const uint8_t *data, size_t size) {
    if (!data || size < 4 || data[0] != 0xFF || data[1] != 0xD8) {
        return 0;
    }
    size_t pos = 2;
    while (pos < size) {
        if (data[pos] != 0xFF) {
            break;
        }
        while (pos < size && data[pos] == 0xFF) {
            ++pos;
        }
        if (pos >= size) {
            break;
        }
        uint8_t marker = data[pos++];
        if (marker == 0xDA || marker == 0xD9 || marker == 0x00) {
            break;
        }
        if ((marker >= 0xD0 && marker <= 0xD7) || marker == 0x01) {
            continue;
        }
        if (pos + 2 > size) {
            break;
        }
        uint16_t seg_len = static_cast<uint16_t>((static_cast<uint16_t>(data[pos]) << 8) |
                                                 static_cast<uint16_t>(data[pos + 1]));
        if (seg_len < 2 || pos + seg_len > size) {
            break;
        }
        bool is_sof = (marker >= 0xC0 && marker <= 0xCF &&
                       marker != 0xC4 && marker != 0xC8 && marker != 0xCC);
        if (is_sof && seg_len >= 8) {
            return static_cast<int>(data[pos + 7]);
        }
        pos += seg_len;
    }
    return 0;
}

static bool copy_to_buffer(const void *src, size_t size, HDRUltraHDRBuffer *dst) {
    if (!dst) {
        return false;
    }
    dst->data = nullptr;
    dst->size = 0;
    if (!src || size == 0) {
        return true;
    }
    uint8_t *buf = static_cast<uint8_t *>(std::malloc(size));
    if (!buf) {
        return false;
    }
    std::memcpy(buf, src, size);
    dst->data = buf;
    dst->size = size;
    return true;
}

static uhdr_codec_err_t validate_and_convert_metadata(const HDRUltraHDRGainMapMetadata &src,
                                                        uhdr_gainmap_metadata_t *dst,
                                                        char **out_error) {
    if (src.use_base_cg == 0) {
        set_error(out_error, "UHDR_WRITE_XMP=ON requires use_base_cg != 0");
        return UHDR_CODEC_UNSUPPORTED_FEATURE;
    }

    auto all_finite = [](const float a[3]) {
        return std::isfinite(a[0]) && std::isfinite(a[1]) && std::isfinite(a[2]);
    };

    if (!all_finite(src.max_content_boost) ||
        !all_finite(src.min_content_boost) ||
        !all_finite(src.gamma) ||
        !all_finite(src.offset_sdr) ||
        !all_finite(src.offset_hdr)) {
        set_error(out_error, "Gainmap metadata contains non-finite values");
        return UHDR_CODEC_INVALID_PARAM;
    }

    auto all_equal = [](const float a[3]) {
        return a[0] == a[1] && a[1] == a[2];
    };

    if (!all_equal(src.max_content_boost) ||
        !all_equal(src.min_content_boost) ||
        !all_equal(src.gamma) ||
        !all_equal(src.offset_sdr) ||
        !all_equal(src.offset_hdr)) {
        set_error(out_error, "UHDR_WRITE_XMP=ON requires identical 3-channel gainmap metadata arrays");
        return UHDR_CODEC_UNSUPPORTED_FEATURE;
    }

    if (!std::isfinite(src.hdr_capacity_min) || !std::isfinite(src.hdr_capacity_max) ||
        src.hdr_capacity_min < 1.0f || src.hdr_capacity_max <= src.hdr_capacity_min) {
        set_error(out_error, "Gainmap metadata must satisfy hdr_capacity_max > hdr_capacity_min >= 1.0");
        return UHDR_CODEC_INVALID_PARAM;
    }

    if (src.gamma[0] <= 0.0f || src.max_content_boost[0] <= 0.0f || src.min_content_boost[0] <= 0.0f) {
        set_error(out_error, "Gainmap linear boost and gamma values must be > 0");
        return UHDR_CODEC_INVALID_PARAM;
    }

    for (int i = 0; i < 3; ++i) {
        dst->max_content_boost[i] = src.max_content_boost[i];
        dst->min_content_boost[i] = src.min_content_boost[i];
        dst->gamma[i] = src.gamma[i];
        dst->offset_sdr[i] = src.offset_sdr[i];
        dst->offset_hdr[i] = src.offset_hdr[i];
    }
    dst->hdr_capacity_min = src.hdr_capacity_min;
    dst->hdr_capacity_max = src.hdr_capacity_max;
    dst->use_base_cg = src.use_base_cg;
    return UHDR_CODEC_OK;
}

} /* namespace */

extern "C" {

const char *hdr_ultrahdr_version(void) {
    uhdr_codec_private_t *enc = uhdr_create_encoder();
    if (enc) {
        uhdr_release_encoder(enc);
    }
    return UHDR_LIB_VERSION_STR;
}

void hdr_ultrahdr_free_buffer(HDRUltraHDRBuffer *buffer) {
    if (!buffer) {
        return;
    }
    if (buffer->data) {
        std::free(buffer->data);
        buffer->data = nullptr;
    }
    buffer->size = 0;
}

void cuhdr_free_error(char *error_message) {
    if (error_message) {
        std::free(error_message);
    }
}

int cuhdr_encode_api4(const HDRUltraHDREncodeInput *input,
                      HDRUltraHDRBuffer *out_jpeg,
                      char **out_error) {
    if (out_error) {
        *out_error = nullptr;
    }
    if (!out_jpeg) {
        set_error(out_error, "out_jpeg is NULL");
        return -1;
    }
    out_jpeg->data = nullptr;
    out_jpeg->size = 0;

    if (!input || !input->base_jpeg_data || input->base_jpeg_size == 0 ||
        !input->gainmap_jpeg_data || input->gainmap_jpeg_size == 0) {
        set_error(out_error, "Invalid input buffers for cuhdr_encode_api4");
        return -1;
    }

    try {
        uhdr_gainmap_metadata_t uhdr_meta{};
        uhdr_codec_err_t meta_err = validate_and_convert_metadata(input->metadata, &uhdr_meta, out_error);
        if (meta_err != UHDR_CODEC_OK) {
            return static_cast<int>(meta_err);
        }

        std::vector<uint8_t> spliced_base;
        const uint8_t *base_ptr = input->base_jpeg_data;
        size_t base_sz = input->base_jpeg_size;

        if (input->exif_data && input->exif_size > 0) {
            if (!prepare_base_jpeg_with_exif(input->base_jpeg_data,
                                             input->base_jpeg_size,
                                             input->exif_data,
                                             input->exif_size,
                                             spliced_base,
                                             out_error)) {
                return static_cast<int>(UHDR_CODEC_INVALID_PARAM);
            }
            base_ptr = spliced_base.data();
            base_sz = spliced_base.size();
        }

        std::unique_ptr<uhdr_codec_private_t, EncoderDeleter> enc(uhdr_create_encoder());
        if (!enc) {
            set_error(out_error, "uhdr_create_encoder() returned NULL");
            return static_cast<int>(UHDR_CODEC_MEM_ERROR);
        }

        uhdr_compressed_image_t base_img{};
        base_img.data = const_cast<uint8_t *>(base_ptr);
        base_img.data_sz = base_sz;
        base_img.capacity = base_sz;
        base_img.cg = map_gamut_to_uhdr(input->base_color_gamut);
        base_img.ct = UHDR_CT_SRGB;
        base_img.range = UHDR_CR_FULL_RANGE;

        uhdr_error_info_t err = uhdr_enc_set_compressed_image(enc.get(), &base_img, UHDR_BASE_IMG);
        if (err.error_code != UHDR_CODEC_OK) {
            set_uhdr_error(out_error, err);
            return static_cast<int>(err.error_code);
        }

        uhdr_compressed_image_t gm_img{};
        gm_img.data = const_cast<uint8_t *>(input->gainmap_jpeg_data);
        gm_img.data_sz = input->gainmap_jpeg_size;
        gm_img.capacity = input->gainmap_jpeg_size;
        gm_img.cg = UHDR_CG_UNSPECIFIED;
        gm_img.ct = UHDR_CT_UNSPECIFIED;
        gm_img.range = UHDR_CR_FULL_RANGE;

        err = uhdr_enc_set_gainmap_image(enc.get(), &gm_img, &uhdr_meta);
        if (err.error_code != UHDR_CODEC_OK) {
            set_uhdr_error(out_error, err);
            return static_cast<int>(err.error_code);
        }

        err = uhdr_enc_set_output_format(enc.get(), UHDR_CODEC_JPG);
        if (err.error_code != UHDR_CODEC_OK) {
            set_uhdr_error(out_error, err);
            return static_cast<int>(err.error_code);
        }

        err = uhdr_encode(enc.get());
        if (err.error_code != UHDR_CODEC_OK) {
            set_uhdr_error(out_error, err);
            return static_cast<int>(err.error_code);
        }

        uhdr_compressed_image_t *stream = uhdr_get_encoded_stream(enc.get());
        if (!stream || !stream->data || stream->data_sz == 0) {
            set_error(out_error, "uhdr_get_encoded_stream returned empty buffer");
            return static_cast<int>(UHDR_CODEC_ERROR);
        }

        if (!copy_to_buffer(stream->data, stream->data_sz, out_jpeg)) {
            set_error(out_error, "Out of memory copying encoded UltraHDR JPEG");
            return static_cast<int>(UHDR_CODEC_MEM_ERROR);
        }
        return 0;
    } catch (const std::exception &e) {
        set_error(out_error, e.what());
        return static_cast<int>(UHDR_CODEC_UNKNOWN_ERROR);
    } catch (...) {
        set_error(out_error, "Unknown C++ exception in cuhdr_encode_api4");
        return static_cast<int>(UHDR_CODEC_UNKNOWN_ERROR);
    }
}

int cuhdr_probe(const uint8_t *jpeg_data,
                size_t jpeg_size,
                int extract_payloads,
                HDRUltraHDRProbeResult *out_probe,
                char **out_error) {
    if (out_error) {
        *out_error = nullptr;
    }
    if (!out_probe) {
        set_error(out_error, "out_probe is NULL");
        return -1;
    }
    std::memset(out_probe, 0, sizeof(*out_probe));

    if (!jpeg_data || jpeg_size == 0 ||
        jpeg_size > static_cast<size_t>(std::numeric_limits<int>::max())) {
        set_error(out_error, "Invalid JPEG buffer for cuhdr_probe");
        return -1;
    }

    try {
        if (!is_uhdr_image(const_cast<uint8_t *>(jpeg_data), static_cast<int>(jpeg_size))) {
            set_error(out_error, "Input is not a valid Ultra HDR JPEG");
            return static_cast<int>(UHDR_CODEC_ERROR);
        }

        std::unique_ptr<uhdr_codec_private_t, DecoderDeleter> dec(uhdr_create_decoder());
        if (!dec) {
            set_error(out_error, "uhdr_create_decoder() returned NULL");
            return static_cast<int>(UHDR_CODEC_MEM_ERROR);
        }

        uhdr_compressed_image_t img{};
        img.data = const_cast<uint8_t *>(jpeg_data);
        img.data_sz = jpeg_size;
        img.capacity = jpeg_size;

        uhdr_error_info_t err = uhdr_dec_set_image(dec.get(), &img);
        if (err.error_code != UHDR_CODEC_OK) {
            set_uhdr_error(out_error, err);
            return static_cast<int>(err.error_code);
        }

        err = uhdr_dec_probe(dec.get());
        if (err.error_code != UHDR_CODEC_OK) {
            set_uhdr_error(out_error, err);
            return static_cast<int>(err.error_code);
        }

        out_probe->is_valid = 1;
        out_probe->base_width = uhdr_dec_get_image_width(dec.get());
        out_probe->base_height = uhdr_dec_get_image_height(dec.get());
        out_probe->gainmap_width = uhdr_dec_get_gainmap_width(dec.get());
        out_probe->gainmap_height = uhdr_dec_get_gainmap_height(dec.get());

        uhdr_gainmap_metadata_t *meta = uhdr_dec_get_gainmap_metadata(dec.get());
        if (meta) {
            copy_metadata_from_uhdr(meta, &out_probe->metadata);
        }

        uhdr_mem_block_t *exif_blk = uhdr_dec_get_exif(dec.get());
        uhdr_mem_block_t *icc_blk = uhdr_dec_get_icc(dec.get());
        uhdr_mem_block_t *base_blk = uhdr_dec_get_base_image(dec.get());
        uhdr_mem_block_t *gm_blk = uhdr_dec_get_gainmap_image(dec.get());

        out_probe->exif_size = exif_blk ? exif_blk->data_sz : 0;
        out_probe->icc_size = icc_blk ? icc_blk->data_sz : 0;
        out_probe->base_jpeg_size = base_blk ? base_blk->data_sz : 0;
        out_probe->gainmap_jpeg_size = gm_blk ? gm_blk->data_sz : 0;

        if (gm_blk && gm_blk->data && gm_blk->data_sz > 0) {
            out_probe->gainmap_channels = parse_jpeg_sof_channels(
                static_cast<const uint8_t *>(gm_blk->data), gm_blk->data_sz);
        }

        if (extract_payloads != 0) {
            bool ok = true;
            if (base_blk && base_blk->data && base_blk->data_sz > 0) {
                ok = ok && copy_to_buffer(base_blk->data, base_blk->data_sz, &out_probe->base_jpeg);
            }
            if (gm_blk && gm_blk->data && gm_blk->data_sz > 0) {
                ok = ok && copy_to_buffer(gm_blk->data, gm_blk->data_sz, &out_probe->gainmap_jpeg);
            }
            if (exif_blk && exif_blk->data && exif_blk->data_sz > 0) {
                ok = ok && copy_to_buffer(exif_blk->data, exif_blk->data_sz, &out_probe->exif_data);
            }
            if (icc_blk && icc_blk->data && icc_blk->data_sz > 0) {
                ok = ok && copy_to_buffer(icc_blk->data, icc_blk->data_sz, &out_probe->icc_data);
            }
            if (!ok) {
                cuhdr_free_probe_result(out_probe);
                set_error(out_error, "Out of memory copying probed UltraHDR payloads");
                return static_cast<int>(UHDR_CODEC_MEM_ERROR);
            }
        }

        return 0;
    } catch (const std::exception &e) {
        cuhdr_free_probe_result(out_probe);
        set_error(out_error, e.what());
        return static_cast<int>(UHDR_CODEC_UNKNOWN_ERROR);
    } catch (...) {
        cuhdr_free_probe_result(out_probe);
        set_error(out_error, "Unknown C++ exception in cuhdr_probe");
        return static_cast<int>(UHDR_CODEC_UNKNOWN_ERROR);
    }
}

void cuhdr_free_probe_result(HDRUltraHDRProbeResult *probe) {
    if (!probe) {
        return;
    }
    hdr_ultrahdr_free_buffer(&probe->base_jpeg);
    hdr_ultrahdr_free_buffer(&probe->gainmap_jpeg);
    hdr_ultrahdr_free_buffer(&probe->exif_data);
    hdr_ultrahdr_free_buffer(&probe->icc_data);
    std::memset(probe, 0, sizeof(*probe));
}

int cuhdr_decode(const uint8_t *jpeg_data,
                 size_t jpeg_size,
                 HDRUltraHDRDecodeOutputFormat output_format,
                 float max_display_boost,
                 HDRUltraHDRDecodedImage *out_image,
                 char **out_error) {
    if (out_error) {
        *out_error = nullptr;
    }
    if (!out_image) {
        set_error(out_error, "out_image is NULL");
        return -1;
    }
    std::memset(out_image, 0, sizeof(*out_image));

    if (!jpeg_data || jpeg_size == 0 ||
        jpeg_size > static_cast<size_t>(std::numeric_limits<int>::max())) {
        set_error(out_error, "Invalid JPEG buffer for cuhdr_decode");
        return -1;
    }

    try {
        std::unique_ptr<uhdr_codec_private_t, DecoderDeleter> dec(uhdr_create_decoder());
        if (!dec) {
            set_error(out_error, "uhdr_create_decoder() returned NULL");
            return static_cast<int>(UHDR_CODEC_MEM_ERROR);
        }

        uhdr_compressed_image_t img{};
        img.data = const_cast<uint8_t *>(jpeg_data);
        img.data_sz = jpeg_size;
        img.capacity = jpeg_size;

        uhdr_error_info_t err = uhdr_dec_set_image(dec.get(), &img);
        if (err.error_code != UHDR_CODEC_OK) {
            set_uhdr_error(out_error, err);
            return static_cast<int>(err.error_code);
        }

        const bool is_half = (output_format == HDR_UHDR_DECODE_RGBA_HALF_FLOAT_LINEAR);
        err = uhdr_dec_set_out_img_format(
            dec.get(), is_half ? UHDR_IMG_FMT_64bppRGBAHalfFloat : UHDR_IMG_FMT_32bppRGBA8888);
        if (err.error_code != UHDR_CODEC_OK) {
            set_uhdr_error(out_error, err);
            return static_cast<int>(err.error_code);
        }

        err = uhdr_dec_set_out_color_transfer(
            dec.get(), is_half ? UHDR_CT_LINEAR : UHDR_CT_SRGB);
        if (err.error_code != UHDR_CODEC_OK) {
            set_uhdr_error(out_error, err);
            return static_cast<int>(err.error_code);
        }

        if (max_display_boost >= 1.0f) {
            err = uhdr_dec_set_out_max_display_boost(dec.get(), max_display_boost);
            if (err.error_code != UHDR_CODEC_OK) {
                set_uhdr_error(out_error, err);
                return static_cast<int>(err.error_code);
            }
        }

        err = uhdr_dec_probe(dec.get());
        if (err.error_code != UHDR_CODEC_OK) {
            set_uhdr_error(out_error, err);
            return static_cast<int>(err.error_code);
        }

        err = uhdr_decode(dec.get());
        if (err.error_code != UHDR_CODEC_OK) {
            set_uhdr_error(out_error, err);
            return static_cast<int>(err.error_code);
        }

        uhdr_raw_image_t *decoded = uhdr_get_decoded_image(dec.get());
        if (!decoded || !decoded->planes[0] || decoded->w == 0 || decoded->h == 0) {
            set_error(out_error, "uhdr_get_decoded_image returned empty image");
            return static_cast<int>(UHDR_CODEC_ERROR);
        }

        size_t px_bpp = is_half ? 8 : 4;
        size_t px_row_bytes = static_cast<size_t>(decoded->w) * px_bpp;
        size_t px_total_bytes = px_row_bytes * static_cast<size_t>(decoded->h);
        uint8_t *px_dst = static_cast<uint8_t *>(std::malloc(px_total_bytes));
        if (!px_dst) {
            set_error(out_error, "Out of memory allocating decoded pixels");
            return static_cast<int>(UHDR_CODEC_MEM_ERROR);
        }

        size_t src_stride_px = decoded->stride[0] > 0 ? static_cast<size_t>(decoded->stride[0]) : static_cast<size_t>(decoded->w);
        const uint8_t *px_src = static_cast<const uint8_t *>(decoded->planes[0]);
        for (unsigned int y = 0; y < decoded->h; ++y) {
            std::memcpy(px_dst + static_cast<size_t>(y) * px_row_bytes,
                        px_src + static_cast<size_t>(y) * src_stride_px * px_bpp,
                        px_row_bytes);
        }

        out_image->width = static_cast<int>(decoded->w);
        out_image->height = static_cast<int>(decoded->h);
        out_image->output_format = output_format;
        out_image->color_gamut = map_gamut_from_uhdr(decoded->cg);
        out_image->pixels.data = px_dst;
        out_image->pixels.size = px_total_bytes;

        uhdr_raw_image_t *gm = uhdr_get_decoded_gainmap_image(dec.get());
        if (gm && gm->planes[0] && gm->w > 0 && gm->h > 0) {
            int gm_ch = (gm->fmt == UHDR_IMG_FMT_8bppYCbCr400) ? 1 : 4;
            size_t gm_bpp = static_cast<size_t>(gm_ch);
            size_t gm_row_bytes = static_cast<size_t>(gm->w) * gm_bpp;
            size_t gm_total = gm_row_bytes * static_cast<size_t>(gm->h);
            uint8_t *gm_dst = static_cast<uint8_t *>(std::malloc(gm_total));
            if (!gm_dst) {
                cuhdr_free_decoded_image(out_image);
                set_error(out_error, "Out of memory allocating decoded gainmap pixels");
                return static_cast<int>(UHDR_CODEC_MEM_ERROR);
            }
            size_t gm_stride_px = gm->stride[0] > 0 ? static_cast<size_t>(gm->stride[0]) : static_cast<size_t>(gm->w);
            const uint8_t *gm_src = static_cast<const uint8_t *>(gm->planes[0]);
            for (unsigned int y = 0; y < gm->h; ++y) {
                std::memcpy(gm_dst + static_cast<size_t>(y) * gm_row_bytes,
                            gm_src + static_cast<size_t>(y) * gm_stride_px * gm_bpp,
                            gm_row_bytes);
            }
            out_image->gainmap_width = static_cast<int>(gm->w);
            out_image->gainmap_height = static_cast<int>(gm->h);
            out_image->gainmap_channels = gm_ch;
            out_image->gainmap_pixels.data = gm_dst;
            out_image->gainmap_pixels.size = gm_total;
        }

        uhdr_gainmap_metadata_t *meta = uhdr_dec_get_gainmap_metadata(dec.get());
        if (meta) {
            copy_metadata_from_uhdr(meta, &out_image->metadata);
        }

        return 0;
    } catch (const std::exception &e) {
        cuhdr_free_decoded_image(out_image);
        set_error(out_error, e.what());
        return static_cast<int>(UHDR_CODEC_UNKNOWN_ERROR);
    } catch (...) {
        cuhdr_free_decoded_image(out_image);
        set_error(out_error, "Unknown C++ exception in cuhdr_decode");
        return static_cast<int>(UHDR_CODEC_UNKNOWN_ERROR);
    }
}

void cuhdr_free_decoded_image(HDRUltraHDRDecodedImage *image) {
    if (!image) {
        return;
    }
    hdr_ultrahdr_free_buffer(&image->pixels);
    hdr_ultrahdr_free_buffer(&image->gainmap_pixels);
    std::memset(image, 0, sizeof(*image));
}

} /* extern "C" */
