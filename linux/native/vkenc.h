// H.264 encoding through Vulkan Video on NVIDIA's encoder (vkenc.c).
#pragma once
#include <stddef.h>
#include <stdint.h>

typedef struct VkEnc VkEnc;

typedef struct {
    const uint8_t *uuid;            // the GPU (16 bytes, as CUDA and Vulkan report it); NULL: the first NVIDIA one
    uint32_t w, h;                  // visible size, even
    uint32_t fps, kbps, vbv_frames;
    uint32_t max_kbps;              // the highest bitrate it may be asked for (it sets the H.264 level)
    int preset;                     // NVENC-style 1..7, mapped to a quality level
    int matrix601;                  // BT.601 instead of BT.709
    int chroma444;                  // 4:4:4 (High 4:4:4 Predictive): full-resolution colour
    void *src;                      // the frame buffer (BGRx), page-aligned, read by the GPU in place
    size_t src_size;                // a multiple of the page size
    uint32_t src_pitch;             // bytes per row
} VkEncParams;

// NULL if Vulkan Video can't be used here (the reason is logged); then use NVENC through CUDA.
// *params gets the SPS and PPS, Annex B, which every key frame starts with.
VkEnc *vkenc_open(const VkEncParams *p, char gpu_name[128], const uint8_t **params, uint32_t *params_len);
// Converts the frame buffer's current pixels into the next picture to encode: 1 if it differs
// from the last one, 0 if it's the same, -1 on failure. Then vkenc_encode, or vkenc_skip.
int vkenc_convert(VkEnc *e);
int vkenc_skip(VkEnc *e);
// Encodes the last converted picture as a key frame (IDR) or a P frame; the next one refers to
// it. *out stays valid until the next call.
int vkenc_encode(VkEnc *e, int idr, const uint8_t **out, uint32_t *len);
int vkenc_set_bitrate(VkEnc *e, uint32_t kbps);
void vkenc_close(VkEnc *e);
