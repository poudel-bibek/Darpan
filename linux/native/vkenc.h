// H.264 encoding through Vulkan Video on NVIDIA's encoder (vkenc.c).
#pragma once
#include <stddef.h>
#include <stdint.h>

typedef struct VkEnc VkEnc;

typedef struct {
    int gpu;                        // which NVIDIA GPU (0 = the first)
    uint32_t w, h;                  // visible size, even
    uint32_t fps, kbps, vbv_frames;
    int preset;                     // NVENC-style 1..7, mapped to a quality level
    int matrix601;                  // BT.601 instead of BT.709
    void *src;                      // the frame buffer (BGRx), page-aligned, read by the GPU in place
    size_t src_size;                // a multiple of the page size
    uint32_t src_pitch;             // bytes per row
} VkEncParams;

// NULL if Vulkan Video can't be used here (the reason is logged); then use NVENC through CUDA.
// *params gets the SPS and PPS, Annex B, which every key frame starts with.
VkEnc *vkenc_open(const VkEncParams *p, char gpu_name[128], const uint8_t **params, uint32_t *params_len);
// Converts the frame buffer's current pixels into the next picture to encode.
int vkenc_convert(VkEnc *e);
// Encodes the last converted picture: a key frame (IDR), a reference P frame, or a non-reference
// P frame (reference 0) that leaves the decoder's state as it was. *out stays valid until the
// next call.
int vkenc_encode(VkEnc *e, int idr, int reference, const uint8_t **out, uint32_t *len);
int vkenc_set_bitrate(VkEnc *e, uint32_t kbps);
void vkenc_close(VkEnc *e);
