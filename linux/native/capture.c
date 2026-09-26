// SPDX-License-Identifier: MIT
// darpan-capture — damage-driven X11 screen capture + NVIDIA NVENC H.264 encoder for Darpan.
//
// Why this exists: the host must cost next to nothing on a machine busy with other GPU/CPU work.
//   * Nothing runs unless the X server reports damage (the screen changed) — an idle
//     screen costs 0 CPU and 0 bandwidth. Damage alone isn't enough to send a frame: one that
//     would decode to the picture the viewer already has isn't sent (see "Unchanged frames").
//   * Frames are only produced while the daemon has granted credits (one credit per frame,
//     returned when the client acks it), so a slow network makes us encode fewer frames
//     instead of queueing stale ones.
//   * Pixels go X server -> XShm segment (pinned for DMA) -> CUDA buffer -> NVENC. There
//     are no CPU pixel copies and no CPU colour conversion; NVENC converts BGRx itself.
//
// I/O protocol with the daemon (darpan/capture.py):
//   stdout: records  [u32 len][u32 flags][u64 capture_ts_us][u32 cap_us][u32 enc_us] + len bytes
//           (native little-endian). flags: bit0 key frame, bit1 refresh, bit31 JSON info record.
//           The timestamp is CLOCK_MONOTONIC in µs (same clock as Python's time.monotonic()).
//   stdin : one command per line:  "c N" add N credits · "k" next frame is a key frame ·
//           "b KBPS" bitrate · "f FPS" max frame rate · "r" encode now · "q" quit
//
// Exit codes: 0 normal, 2 error (also: the X server went away), 3 screen size changed (restart me),
// 4 NVENC unavailable.

#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>

#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/XShm.h>
#include <X11/extensions/Xdamage.h>

#include "ffnvcodec/dynlink_cuda.h"
#include "ffnvcodec/nvEncodeAPI.h"

#define FLAG_KEY     0x1u
#define FLAG_REFRESH 0x2u
#define FLAG_INFO    0x80000000u

// ---------------------------------------------------------------------------------------
// small utilities

static void logf_(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fputs("darpan-capture: ", stderr);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
}

static uint64_t now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000u + (uint64_t)ts.tv_nsec / 1000u;
}

static int write_all(int fd, struct iovec *iov, int n) {
    while (n > 0) {
        ssize_t w = writev(fd, iov, n);
        if (w < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        while (n > 0 && (size_t)w >= iov->iov_len) { w -= (ssize_t)iov->iov_len; iov++; n--; }
        if (n > 0) { iov->iov_base = (char *)iov->iov_base + w; iov->iov_len -= (size_t)w; }
    }
    return 0;
}

static int emit_record(uint32_t flags, uint64_t ts, uint32_t cap_us, uint32_t enc_us,
                       const void *data, uint32_t len) {
    uint8_t hdr[24];
    memcpy(hdr + 0, &len, 4);
    memcpy(hdr + 4, &flags, 4);
    memcpy(hdr + 8, &ts, 8);
    memcpy(hdr + 16, &cap_us, 4);
    memcpy(hdr + 20, &enc_us, 4);
    struct iovec iov[2] = {{hdr, sizeof hdr}, {(void *)data, len}};
    return write_all(STDOUT_FILENO, iov, len ? 2 : 1);
}

static void emit_info(const char *fmt, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if (n >= (int)sizeof buf) n = sizeof buf - 1;
    emit_record(FLAG_INFO, now_us(), 0, 0, buf, (uint32_t)n);
}

// ---------------------------------------------------------------------------------------
// CUDA driver API (loaded at runtime so the binary runs — and reports cleanly — without it)

typedef CUresult CUDAAPI tcuMemHostRegister_v2(void *p, size_t bytesize, unsigned int flags);
typedef CUresult CUDAAPI tcuMemHostUnregister(void *p);
typedef CUresult CUDAAPI tcuCtxSetLimit_(int limit, size_t value);
typedef CUresult CUDAAPI tcuMemGetInfo_v2(size_t *free_b, size_t *total_b);

static struct {
    void *lib;
    tcuInit *Init;
    tcuDeviceGet *DeviceGet;
    tcuDeviceGetName *DeviceGetName;
    tcuCtxCreate_v2 *CtxCreate;
    tcuCtxDestroy_v2 *CtxDestroy;
    tcuCtxPushCurrent_v2 *CtxPush;
    tcuCtxPopCurrent_v2 *CtxPop;
    tcuMemAllocPitch_v2 *MemAllocPitch;
    tcuMemFree_v2 *MemFree;
    tcuMemcpy2D_v2 *Memcpy2D;
    tcuMemHostRegister_v2 *MemHostRegister;
    tcuMemHostUnregister *MemHostUnregister;
    tcuGetErrorName *GetErrorName;
    tcuCtxSetLimit_ *CtxSetLimit;
    tcuMemGetInfo_v2 *MemGetInfo;
} cu;

static const char *cu_err(CUresult r) {
    const char *s = NULL;
    if (cu.GetErrorName && cu.GetErrorName(r, &s) == CUDA_SUCCESS && s) return s;
    return "CUDA_ERROR";
}

static int cuda_load(void) {
    cu.lib = dlopen("libcuda.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!cu.lib) { logf_("libcuda.so.1 not found (NVIDIA driver missing?)"); return -1; }
#define LOAD(field, sym) do { cu.field = dlsym(cu.lib, sym); if (!cu.field) { logf_("missing %s", sym); return -1; } } while (0)
    LOAD(Init, "cuInit");
    LOAD(DeviceGet, "cuDeviceGet");
    LOAD(DeviceGetName, "cuDeviceGetName");
    LOAD(CtxCreate, "cuCtxCreate_v2");
    LOAD(CtxDestroy, "cuCtxDestroy_v2");
    LOAD(CtxPush, "cuCtxPushCurrent_v2");
    LOAD(CtxPop, "cuCtxPopCurrent_v2");
    LOAD(MemAllocPitch, "cuMemAllocPitch_v2");
    LOAD(MemFree, "cuMemFree_v2");
    LOAD(Memcpy2D, "cuMemcpy2D_v2");
    LOAD(MemHostRegister, "cuMemHostRegister_v2");
    LOAD(MemHostUnregister, "cuMemHostUnregister");
    LOAD(GetErrorName, "cuGetErrorName");
    LOAD(CtxSetLimit, "cuCtxSetLimit");
    LOAD(MemGetInfo, "cuMemGetInfo_v2");
#undef LOAD
    return 0;
}

// ---------------------------------------------------------------------------------------
// NVENC

typedef NVENCSTATUS NVENCAPI tNvEncodeAPICreateInstance(NV_ENCODE_API_FUNCTION_LIST *);
typedef NVENCSTATUS NVENCAPI tNvEncodeAPIGetMaxSupportedVersion(uint32_t *);

static NV_ENCODE_API_FUNCTION_LIST nv;

static const char *nv_status_name(NVENCSTATUS s) {
    switch (s) {
    case NV_ENC_SUCCESS: return "SUCCESS";
    case NV_ENC_ERR_NO_ENCODE_DEVICE: return "NO_ENCODE_DEVICE";
    case NV_ENC_ERR_UNSUPPORTED_DEVICE: return "UNSUPPORTED_DEVICE";
    case NV_ENC_ERR_INVALID_ENCODERDEVICE: return "INVALID_ENCODERDEVICE";
    case NV_ENC_ERR_INVALID_DEVICE: return "INVALID_DEVICE";
    case NV_ENC_ERR_DEVICE_NOT_EXIST: return "DEVICE_NOT_EXIST";
    case NV_ENC_ERR_INVALID_PTR: return "INVALID_PTR";
    case NV_ENC_ERR_INVALID_EVENT: return "INVALID_EVENT";
    case NV_ENC_ERR_INVALID_PARAM: return "INVALID_PARAM";
    case NV_ENC_ERR_INVALID_CALL: return "INVALID_CALL";
    case NV_ENC_ERR_OUT_OF_MEMORY: return "OUT_OF_MEMORY";
    case NV_ENC_ERR_ENCODER_NOT_INITIALIZED: return "ENCODER_NOT_INITIALIZED";
    case NV_ENC_ERR_UNSUPPORTED_PARAM: return "UNSUPPORTED_PARAM";
    case NV_ENC_ERR_LOCK_BUSY: return "LOCK_BUSY";
    case NV_ENC_ERR_NOT_ENOUGH_BUFFER: return "NOT_ENOUGH_BUFFER";
    case NV_ENC_ERR_INVALID_VERSION: return "INVALID_VERSION";
    case NV_ENC_ERR_MAP_FAILED: return "MAP_FAILED";
    case NV_ENC_ERR_NEED_MORE_INPUT: return "NEED_MORE_INPUT";
    case NV_ENC_ERR_ENCODER_BUSY: return "ENCODER_BUSY";
    case NV_ENC_ERR_EVENT_NOT_REGISTERD: return "EVENT_NOT_REGISTERED";
    case NV_ENC_ERR_GENERIC: return "GENERIC";
    case NV_ENC_ERR_INCOMPATIBLE_CLIENT_KEY: return "INCOMPATIBLE_CLIENT_KEY";
    case NV_ENC_ERR_UNIMPLEMENTED: return "UNIMPLEMENTED";
    case NV_ENC_ERR_RESOURCE_REGISTER_FAILED: return "RESOURCE_REGISTER_FAILED";
    case NV_ENC_ERR_RESOURCE_NOT_REGISTERED: return "RESOURCE_NOT_REGISTERED";
    case NV_ENC_ERR_RESOURCE_NOT_MAPPED: return "RESOURCE_NOT_MAPPED";
    default: return "UNKNOWN";
    }
}

// ---------------------------------------------------------------------------------------
// Unchanged frames
//
// With a compositor, X reports the whole screen as damaged whenever anything animates, and most
// of those frames are pixel-identical to the one before. Comparing whole frames on the CPU costs
// more than the encode, and a CUDA kernel would share the SMs with the user's GPU jobs. So a frame
// that looks unchanged (sparse row check in the main loop) is first encoded as a non-reference P
// frame: a probe. If every macroblock of the probe is P_Skip, it decodes to exactly its reference
// picture, so it's dropped. A non-reference picture can be dropped without a trace (frame_num only
// counts reference pictures), so the viewer's stream stays valid. Otherwise the probe is sent as it
// is, with no extra delay, and the next picture is a reference again.
//
// "Every macroblock is P_Skip" needs only the slice header and the CABAC-coded mb_skip_flag and
// end_of_slice_flag of each macroblock (H.264 7.3.3, 7.3.4, 9.3). The decode must also end
// exactly at the slice's stop bit. Anything unexpected counts as changed, so a mistake here can
// only cost a frame, never hide one.

typedef struct {
    int ok;                              // probing is on: a stream this parser understands
    uint32_t mbs;                        // macroblocks per picture
    int log2_max_frame_num, poc_type, log2_max_poc_lsb;
    int bottom_poc, redundant_pic_cnt, deblocking_ctl, pic_init_qp;
} H264Info;

typedef struct { const uint8_t *p, *end; uint32_t cur; int left, zeros, err; } Rbsp;

static int rb_byte(Rbsp *r) {            // next RBSP byte: emulation prevention bytes removed
    if (r->p >= r->end) { r->err = 1; return 0; }
    int b = *r->p++;
    if (r->zeros >= 2 && b == 3) {
        if (r->p >= r->end) { r->err = 1; return 0; }
        b = *r->p++;
        r->zeros = 0;
    }
    r->zeros = b ? 0 : r->zeros + 1;
    return b;
}
static int rb_bit(Rbsp *r) {
    if (!r->left) { r->cur = (uint32_t)rb_byte(r); r->left = 8; }
    return (int)(r->cur >> --r->left) & 1;
}
static uint32_t rb_bits(Rbsp *r, int n) {
    uint32_t v = 0;
    while (n-- > 0) v = v << 1 | (uint32_t)rb_bit(r);
    return v;
}
static uint32_t rb_ue(Rbsp *r) {
    int z = 0;
    while (!rb_bit(r)) if (++z > 31) { r->err = 1; return 0; }
    return ((1u << z) - 1) + rb_bits(r, z);
}
static int32_t rb_se(Rbsp *r) {
    uint32_t k = rb_ue(r);
    return k & 1 ? (int32_t)((k + 1) / 2) : -(int32_t)(k / 2);
}

// Next NAL unit of an Annex B buffer: returns its first byte (the header) and sets *nal_end.
static const uint8_t *next_nal(const uint8_t **pos, const uint8_t *end, const uint8_t **nal_end) {
    const uint8_t *p = *pos;
    while (p + 3 <= end && !(p[0] == 0 && p[1] == 0 && p[2] == 1)) p++;
    if (p + 3 >= end) return NULL;
    const uint8_t *nal = p + 3, *q = nal;
    while (q + 3 <= end && !(q[0] == 0 && q[1] == 0 && q[2] == 1)) q++;
    if (q + 3 > end) q = end;
    *pos = *nal_end = q;
    return nal;
}

static int parse_sps(Rbsp *r, H264Info *h) {
    int profile = (int)rb_bits(r, 8);
    rb_bits(r, 16);                                     // constraint flags, level_idc
    rb_ue(r);                                           // seq_parameter_set_id
    if (profile == 100 || profile == 110 || profile == 122 || profile == 244 || profile == 44 ||
        profile == 83 || profile == 86 || profile == 118 || profile == 128 || profile == 138 ||
        profile == 139 || profile == 134 || profile == 135) {
        if (rb_ue(r) == 3) return -1;                   // 4:4:4 (separate colour planes)
        rb_ue(r); rb_ue(r); rb_bit(r);                  // bit depths, transform bypass
        if (rb_bit(r)) return -1;                       // scaling matrices
    }
    h->log2_max_frame_num = (int)rb_ue(r) + 4;
    h->poc_type = (int)rb_ue(r);
    if (h->poc_type == 0) h->log2_max_poc_lsb = (int)rb_ue(r) + 4;
    else if (h->poc_type != 2) return -1;
    rb_ue(r); rb_bit(r);                                // max_num_ref_frames, gaps allowed
    uint32_t w = rb_ue(r) + 1, hm = rb_ue(r) + 1;
    if (!rb_bit(r)) return -1;                          // frame_mbs_only_flag: progressive only
    h->mbs = w * hm;
    return r->err ? -1 : 0;
}

static int parse_pps(Rbsp *r, H264Info *h) {
    rb_ue(r); rb_ue(r);                                 // picture and sequence parameter set ids
    if (!rb_bit(r)) return -1;                          // entropy_coding_mode_flag: CABAC only
    h->bottom_poc = rb_bit(r);
    if (rb_ue(r)) return -1;                            // slice groups
    rb_ue(r); rb_ue(r);                                 // default active reference counts
    if (rb_bit(r)) return -1;                           // weighted prediction
    rb_bits(r, 2);                                      // weighted_bipred_idc
    h->pic_init_qp = 26 + rb_se(r);
    rb_se(r); rb_se(r);                                 // pic_init_qs, chroma_qp_index_offset
    h->deblocking_ctl = rb_bit(r);
    rb_bit(r);                                          // constrained_intra_pred_flag
    h->redundant_pic_cnt = rb_bit(r);
    return r->err ? -1 : 0;
}

static const uint8_t range_lps[64][4] = {
    {128, 176, 208, 240}, {128, 167, 197, 227}, {128, 158, 187, 216}, {123, 150, 178, 205},
    {116, 142, 169, 195}, {111, 135, 160, 185}, {105, 128, 152, 175}, {100, 122, 144, 166},
    {95, 116, 137, 158}, {90, 110, 130, 150}, {85, 104, 123, 142}, {81, 99, 117, 135},
    {77, 94, 111, 128}, {73, 89, 105, 122}, {69, 85, 100, 116}, {66, 80, 95, 110},
    {62, 76, 90, 104}, {59, 72, 86, 99}, {56, 69, 81, 94}, {53, 65, 77, 89},
    {51, 62, 73, 85}, {48, 59, 69, 80}, {46, 56, 66, 76}, {43, 53, 63, 72},
    {41, 50, 59, 69}, {39, 48, 56, 65}, {37, 45, 54, 62}, {35, 43, 51, 59},
    {33, 41, 48, 56}, {32, 39, 46, 53}, {30, 37, 43, 50}, {29, 35, 41, 48},
    {27, 33, 39, 45}, {26, 31, 37, 43}, {24, 30, 35, 41}, {23, 28, 33, 39},
    {22, 27, 32, 37}, {21, 26, 30, 35}, {20, 24, 29, 33}, {19, 23, 27, 31},
    {18, 22, 26, 30}, {17, 21, 25, 28}, {16, 20, 23, 27}, {15, 19, 22, 25},
    {14, 18, 21, 24}, {14, 17, 20, 23}, {13, 16, 19, 22}, {12, 15, 18, 21},
    {12, 14, 17, 20}, {11, 14, 16, 19}, {11, 13, 15, 18}, {10, 12, 15, 17},
    {10, 12, 14, 16}, {9, 11, 13, 15}, {9, 11, 12, 14}, {8, 10, 12, 14},
    {8, 9, 11, 13}, {7, 9, 11, 12}, {7, 9, 10, 12}, {7, 8, 10, 11},
    {6, 8, 9, 11}, {6, 7, 9, 10}, {6, 7, 8, 9}, {2, 2, 2, 2},
};
static const uint8_t trans_lps[64] = {
    0, 0, 1, 2, 2, 4, 4, 5, 6, 7, 8, 9, 9, 11, 11, 12, 13, 13, 15, 15, 16, 16, 18, 18, 19, 19,
    21, 21, 22, 22, 23, 24, 24, 25, 26, 26, 27, 27, 28, 29, 29, 30, 30, 30, 31, 32, 32, 33, 33,
    33, 34, 34, 35, 35, 35, 36, 36, 36, 37, 37, 37, 38, 38, 63,
};

// 1 if the slice (RBSP after the NAL header) is a whole P picture whose macroblocks are all P_Skip.
static int slice_all_skip(const H264Info *h, const uint8_t *p, const uint8_t *end) {
    Rbsp r = {p, end, 0, 0, 0, 0};
    if (rb_ue(&r) != 0) return 0;                       // first_mb_in_slice: the whole picture
    uint32_t type = rb_ue(&r);
    if (type != 0 && type != 5) return 0;               // P
    rb_ue(&r);                                          // pic_parameter_set_id
    rb_bits(&r, h->log2_max_frame_num);                 // frame_num
    if (h->poc_type == 0) {
        rb_bits(&r, h->log2_max_poc_lsb);
        if (h->bottom_poc) rb_se(&r);
    }
    if (h->redundant_pic_cnt) rb_ue(&r);
    if (rb_bit(&r)) rb_ue(&r);                          // num_ref_idx_active_override
    if (rb_bit(&r)) return 0;                           // ref_pic_list_modification_flag_l0
    uint32_t init_idc = rb_ue(&r);                      // (no dec_ref_pic_marking: not a reference)
    int qp = h->pic_init_qp + rb_se(&r);
    if (h->deblocking_ctl && rb_ue(&r) != 1) { rb_se(&r); rb_se(&r); }
    if (r.err || init_idc > 2 || qp < 0 || qp > 51) return 0;
    while (r.left) if (!rb_bit(&r)) return 0;           // cabac_alignment_one_bit

    // mb_skip_flag of a macroblock whose neighbours are skipped or missing is ctxIdx 11 (9.3.3.1.1.1).
    static const int m_n[3][2] = {{23, 33}, {22, 25}, {29, 16}};
    int pre = ((m_n[init_idc][0] * qp) >> 4) + m_n[init_idc][1];
    pre = pre < 1 ? 1 : pre > 126 ? 126 : pre;
    int state = pre <= 63 ? 63 - pre : pre - 64, mps = pre > 63;
    uint32_t range = 510, offset = rb_bits(&r, 9);
    for (uint32_t mb = 0; mb < h->mbs && !r.err; mb++) {
        uint32_t lps = range_lps[state][(range >> 6) & 3];
        int bin;
        range -= lps;
        if (offset >= range) {
            bin = !mps;
            offset -= range;
            range = lps;
            if (!state) mps = !mps;
            state = trans_lps[state];
        } else {
            bin = mps;
            if (state < 62) state++;
        }
        while (range < 256) { range <<= 1; offset = offset << 1 | (uint32_t)rb_bit(&r); }
        if (!bin) return 0;                             // a coded macroblock
        range -= 2;                                     // end_of_slice_flag (terminate bin)
        if (offset >= range) {
            // The last bit read is the rbsp_stop_one_bit (9.3.3.2.2.3); only zeros may follow
            // (alignment bits, cabac_zero_words and their emulation prevention bytes).
            if (mb != h->mbs - 1 || !(offset & 1) || r.err) return 0;
            if (r.cur & ((1u << r.left) - 1)) return 0;
            for (int zeros = r.zeros; r.p < r.end; r.p++) {
                if (*r.p == 0) zeros++;
                else if (*r.p == 3 && zeros >= 2) zeros = 0;
                else return 0;
            }
            return 1;
        }
        while (range < 256) { range <<= 1; offset = offset << 1 | (uint32_t)rb_bit(&r); }
    }
    return 0;
}

// 1 if an encoded probe is a single all-P_Skip slice (a non-reference picture).
static int probe_all_skip(const H264Info *h, const uint8_t *buf, uint32_t len) {
    const uint8_t *pos = buf, *end = buf + len, *nal, *nal_end;
    int slices = 0, skip = 0;
    while ((nal = next_nal(&pos, end, &nal_end))) {
        int type = nal[0] & 0x1f;
        if (type == 6 || type == 9 || type == 12) continue;         // SEI, delimiter, filler
        if (type != 1 || (nal[0] & 0x60) || ++slices > 1) return 0;
        skip = slice_all_skip(h, nal + 1, nal_end);
    }
    return slices == 1 && skip;
}

typedef struct {
    void *enc;
    CUcontext ctx;
    CUdeviceptr dptr;
    size_t pitch;
    NV_ENC_REGISTERED_PTR reg;
    NV_ENC_OUTPUT_PTR bs;
    NV_ENC_INITIALIZE_PARAMS init;
    NV_ENC_CONFIG cfg;
    uint32_t w, h, fps, kbps, vbv_frames;
    uint32_t frame_idx;
    uint32_t poc;              // display POC of the last reference picture
    H264Info h264;
    char gpu[128];
} Encoder;

#define NVCHECK(call) do { NVENCSTATUS s_ = (call); if (s_ != NV_ENC_SUCCESS) { \
    logf_("%s failed: %s (%s)", #call, nv_status_name(s_), e->enc && nv.nvEncGetLastErrorString ? nv.nvEncGetLastErrorString(e->enc) : ""); \
    return -1; } } while (0)
#define CUCHECK(call) do { CUresult r_ = (call); if (r_ != CUDA_SUCCESS) { \
    logf_("%s failed: %s", #call, cu_err(r_)); return -1; } } while (0)

static int nvenc_load(void) {
    void *lib = dlopen("libnvidia-encode.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!lib) { logf_("libnvidia-encode.so.1 not found"); return -1; }
    tNvEncodeAPIGetMaxSupportedVersion *getmax = dlsym(lib, "NvEncodeAPIGetMaxSupportedVersion");
    tNvEncodeAPICreateInstance *create = dlsym(lib, "NvEncodeAPICreateInstance");
    if (!getmax || !create) { logf_("NVENC entry points missing"); return -1; }
    uint32_t maxver = 0;
    if (getmax(&maxver) != NV_ENC_SUCCESS) { logf_("NvEncodeAPIGetMaxSupportedVersion failed"); return -1; }
    uint32_t need = (NVENCAPI_MAJOR_VERSION << 4) | NVENCAPI_MINOR_VERSION;
    if (maxver < need) {
        logf_("driver supports NVENC API %u.%u, need %u.%u — update the NVIDIA driver",
              maxver >> 4, maxver & 0xf, NVENCAPI_MAJOR_VERSION, NVENCAPI_MINOR_VERSION);
        return -1;
    }
    memset(&nv, 0, sizeof nv);
    nv.version = NV_ENCODE_API_FUNCTION_LIST_VER;
    if (create(&nv) != NV_ENC_SUCCESS) { logf_("NvEncodeAPICreateInstance failed"); return -1; }
    return 0;
}

static GUID preset_guid(int p) {
    switch (p) {
    case 1: return NV_ENC_PRESET_P1_GUID;
    case 2: return NV_ENC_PRESET_P2_GUID;
    case 3: return NV_ENC_PRESET_P3_GUID;
    case 5: return NV_ENC_PRESET_P5_GUID;
    case 6: return NV_ENC_PRESET_P6_GUID;
    case 7: return NV_ENC_PRESET_P7_GUID;
    default: return NV_ENC_PRESET_P4_GUID;
    }
}

static void set_rc(Encoder *e) {
    NV_ENC_RC_PARAMS *rc = &e->cfg.rcParams;
    uint32_t bps = e->kbps * 1000u;
    rc->rateControlMode = NV_ENC_PARAMS_RC_CBR;
    rc->averageBitRate = bps;
    rc->maxBitRate = bps;
    // A few frames of VBV: small edits (typing) are tiny anyway; a full-screen change may
    // borrow a little so it arrives sharp instead of smeared, without a long burst.
    uint64_t vbv = (uint64_t)bps * e->vbv_frames / (e->fps ? e->fps : 60);
    rc->vbvBufferSize = (uint32_t)vbv;
    rc->vbvInitialDelay = (uint32_t)vbv;
    rc->zeroReorderDelay = 1;
    rc->enableLookahead = 0;
}

static int encoder_open(Encoder *e, int gpu, int preset, int matrix601) {
    if (cuda_load() || nvenc_load()) return -1;
    CUdevice dev;
    CUCHECK(cu.Init(0));
    CUCHECK(cu.DeviceGet(&dev, gpu));
    cu.DeviceGetName(e->gpu, sizeof e->gpu, dev);
    // BLOCKING_SYNC: when the driver waits (for DMA / encode completion) the thread sleeps
    // instead of spinning a CPU core.
    CUCHECK(cu.CtxCreate(&e->ctx, CU_CTX_SCHED_BLOCKING_SYNC, dev));
    // We never launch a kernel, so CUDA's default per-thread stack reservation (sized for every
    // resident thread on every SM), device malloc heap and printf buffer are pure waste of VRAM
    // that a training job could use. Shrink them to the minimum.
    if (!getenv("DARPAN_CUDA_DEFAULT_LIMITS")) {
        cu.CtxSetLimit(0x00 /* STACK_SIZE */, 0);
        cu.CtxSetLimit(0x01 /* PRINTF_FIFO_SIZE */, 4096);
        cu.CtxSetLimit(0x02 /* MALLOC_HEAP_SIZE */, 0);
    }

    NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS op = {0};
    op.version = NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS_VER;
    op.deviceType = NV_ENC_DEVICE_TYPE_CUDA;
    op.device = e->ctx;
    op.apiVersion = NVENCAPI_VERSION;
    NVCHECK(nv.nvEncOpenEncodeSessionEx(&op, &e->enc));

    GUID pg = preset_guid(preset);
    NV_ENC_PRESET_CONFIG pc = {0};
    pc.version = NV_ENC_PRESET_CONFIG_VER;
    pc.presetCfg.version = NV_ENC_CONFIG_VER;
    NVCHECK(nv.nvEncGetEncodePresetConfigEx(e->enc, NV_ENC_CODEC_H264_GUID, pg,
                                            NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY, &pc));
    e->cfg = pc.presetCfg;
    e->cfg.version = NV_ENC_CONFIG_VER;
    e->cfg.profileGUID = NV_ENC_H264_PROFILE_HIGH_GUID;
    e->cfg.gopLength = NVENC_INFINITE_GOPLENGTH;   // key frames only on demand
    e->cfg.frameIntervalP = 1;                      // no B-frames
    set_rc(e);

    NV_ENC_CONFIG_H264 *h = &e->cfg.encodeCodecConfig.h264Config;
    h->idrPeriod = NVENC_INFINITE_GOPLENGTH;
    h->repeatSPSPPS = 1;          // SPS/PPS in front of every IDR (decoders can join anytime)
    h->outputAUD = 0;
    h->sliceMode = 0;
    h->sliceModeData = 0;
    h->chromaFormatIDC = 1;
    h->level = NV_ENC_LEVEL_AUTOSELECT;
    if (!getenv("DARPAN_NVENC_DEFAULT_REFS")) {
        // Screen content is predicted from the previous frame; a single reference keeps the
        // decoded-picture buffer (and NVENC's VRAM) minimal and suits zero-latency decoders.
        h->maxNumRefFrames = 1;
        h->numRefL0 = NV_ENC_NUM_REF_FRAMES_1;
    }
    NV_ENC_CONFIG_H264_VUI_PARAMETERS *v = &h->h264VUIParameters;
    v->videoSignalTypePresentFlag = 1;
    v->videoFormat = NV_ENC_VUI_VIDEO_FORMAT_UNSPECIFIED;
    v->videoFullRangeFlag = 0;
    v->colourDescriptionPresentFlag = 1;
    v->colourPrimaries = NV_ENC_VUI_COLOR_PRIMARIES_BT709;
    v->transferCharacteristics = NV_ENC_VUI_TRANSFER_CHARACTERISTIC_SRGB;
    v->colourMatrix = matrix601 ? NV_ENC_VUI_MATRIX_COEFFS_SMPTE170M : NV_ENC_VUI_MATRIX_COEFFS_BT709;
    v->bitstreamRestrictionFlag = 1;   // lets decoders output each frame immediately

    NV_ENC_INITIALIZE_PARAMS *ip = &e->init;
    memset(ip, 0, sizeof *ip);
    ip->version = NV_ENC_INITIALIZE_PARAMS_VER;
    ip->encodeGUID = NV_ENC_CODEC_H264_GUID;
    ip->presetGUID = pg;
    ip->encodeWidth = e->w;
    ip->encodeHeight = e->h;
    ip->darWidth = e->w;
    ip->darHeight = e->h;
    ip->frameRateNum = e->fps;
    ip->frameRateDen = 1;
    ip->enableEncodeAsync = 0;
    ip->enablePTD = 0;          // we choose each picture's type: probes are non-reference P frames
    ip->encodeConfig = &e->cfg;
    ip->tuningInfo = NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY;
    ip->maxEncodeWidth = e->w;
    ip->maxEncodeHeight = e->h;
    NVCHECK(nv.nvEncInitializeEncoder(e->enc, ip));

    CUCHECK(cu.MemAllocPitch(&e->dptr, &e->pitch, (size_t)e->w * 4, e->h, 16));
    NV_ENC_REGISTER_RESOURCE rr = {0};
    rr.version = NV_ENC_REGISTER_RESOURCE_VER;
    rr.resourceType = NV_ENC_INPUT_RESOURCE_TYPE_CUDADEVICEPTR;
    rr.width = e->w;
    rr.height = e->h;
    rr.pitch = (uint32_t)e->pitch;
    rr.resourceToRegister = (void *)(uintptr_t)e->dptr;
    rr.bufferFormat = NV_ENC_BUFFER_FORMAT_ARGB;   // word-ordered ARGB == X11 32bpp BGRx bytes
    rr.bufferUsage = NV_ENC_INPUT_IMAGE;
    NVCHECK(nv.nvEncRegisterResource(e->enc, &rr));
    e->reg = rr.registeredResource;

    NV_ENC_CREATE_BITSTREAM_BUFFER cb = {0};
    cb.version = NV_ENC_CREATE_BITSTREAM_BUFFER_VER;
    NVCHECK(nv.nvEncCreateBitstreamBuffer(e->enc, &cb));
    e->bs = cb.bitstreamBuffer;

    // Probing needs the parameter sets; a stream this parser doesn't understand is sent in full.
    uint8_t ps[1024];
    uint32_t ps_len = 0;
    NV_ENC_SEQUENCE_PARAM_PAYLOAD sp = {0};
    sp.version = NV_ENC_SEQUENCE_PARAM_PAYLOAD_VER;
    sp.inBufferSize = sizeof ps;
    sp.spsppsBuffer = ps;
    sp.outSPSPPSPayloadSize = &ps_len;
    if (nv.nvEncGetSequenceParams(e->enc, &sp) == NV_ENC_SUCCESS && ps_len <= sizeof ps) {
        const uint8_t *pos = ps, *nal, *nal_end;
        int got = 0;
        while ((nal = next_nal(&pos, ps + ps_len, &nal_end))) {
            Rbsp r = {nal + 1, nal_end, 0, 0, 0, 0};
            if ((nal[0] & 0x1f) == 7) got |= parse_sps(&r, &e->h264) ? 4 : 1;
            else if ((nal[0] & 0x1f) == 8) got |= parse_pps(&r, &e->h264) ? 4 : 2;
        }
        e->h264.ok = got == 3;
    }
    if (!e->h264.ok) logf_("stream not understood; unchanged frames will be sent too");
    return 0;
}

static int encoder_set_bitrate(Encoder *e, uint32_t kbps) {
    if (kbps < 100) kbps = 100;
    if (kbps > 200000) kbps = 200000;
    if (kbps == e->kbps) return 0;
    e->kbps = kbps;
    set_rc(e);
    NV_ENC_RECONFIGURE_PARAMS rp = {0};
    rp.version = NV_ENC_RECONFIGURE_PARAMS_VER;
    rp.reInitEncodeParams = e->init;
    rp.reInitEncodeParams.encodeConfig = &e->cfg;
    rp.resetEncoder = 0;
    rp.forceIDR = 0;
    NVCHECK(nv.nvEncReconfigureEncoder(e->enc, &rp));
    return 0;
}

// Encodes the frame currently in e->dptr and writes it to stdout. A probe (a non-reference P
// frame) that is all P_Skip isn't written: then it returns 1.
static int encoder_encode(Encoder *e, int force_idr, int probe, uint32_t extra_flags, uint64_t ts,
                          uint32_t cap_us, int *out_is_key, uint32_t *out_bytes) {
    uint64_t t0 = now_us();
    NV_ENC_MAP_INPUT_RESOURCE mr = {0};
    mr.version = NV_ENC_MAP_INPUT_RESOURCE_VER;
    mr.registeredResource = e->reg;
    NVCHECK(nv.nvEncMapInputResource(e->enc, &mr));

    NV_ENC_PIC_PARAMS pp = {0};
    pp.version = NV_ENC_PIC_PARAMS_VER;
    pp.inputWidth = e->w;
    pp.inputHeight = e->h;
    pp.inputPitch = (uint32_t)e->pitch;
    pp.encodePicFlags = force_idr ? NV_ENC_PIC_FLAG_OUTPUT_SPSPPS : 0;
    pp.pictureType = force_idr ? NV_ENC_PIC_TYPE_IDR : NV_ENC_PIC_TYPE_P;
    // Reference pictures count up by 2 (a frame's two fields), so the viewer's stream has no gaps
    // however many probes were dropped; a probe sits between them.
    e->poc = force_idr ? 0 : probe ? e->poc : e->poc + 2;
    pp.codecPicParams.h264PicParams.displayPOCSyntax = probe ? e->poc + 1 : e->poc;
    pp.codecPicParams.h264PicParams.refPicFlag = !probe;
    pp.frameIdx = e->frame_idx++;
    pp.inputTimeStamp = ts;
    pp.inputBuffer = mr.mappedResource;
    pp.outputBitstream = e->bs;
    pp.bufferFmt = mr.mappedBufferFmt;
    pp.pictureStruct = NV_ENC_PIC_STRUCT_FRAME;
    NVENCSTATUS st = nv.nvEncEncodePicture(e->enc, &pp);
    if (st != NV_ENC_SUCCESS) {
        logf_("nvEncEncodePicture failed: %s (%s)", nv_status_name(st), nv.nvEncGetLastErrorString(e->enc));
        nv.nvEncUnmapInputResource(e->enc, mr.mappedResource);
        return -1;
    }
    NV_ENC_LOCK_BITSTREAM lb = {0};
    lb.version = NV_ENC_LOCK_BITSTREAM_VER;
    lb.outputBitstream = e->bs;
    lb.doNotWait = 0;
    st = nv.nvEncLockBitstream(e->enc, &lb);
    if (st != NV_ENC_SUCCESS) {
        logf_("nvEncLockBitstream failed: %s", nv_status_name(st));
        nv.nvEncUnmapInputResource(e->enc, mr.mappedResource);
        return -1;
    }
    int is_key = lb.pictureType == NV_ENC_PIC_TYPE_IDR;
    uint32_t enc_us = (uint32_t)(now_us() - t0);
    uint32_t flags = (is_key ? FLAG_KEY : 0) | extra_flags;
    int skip = probe && probe_all_skip(&e->h264, lb.bitstreamBufferPtr, lb.bitstreamSizeInBytes);
    int wr = skip ? 1 : emit_record(flags, ts, cap_us, enc_us, lb.bitstreamBufferPtr, lb.bitstreamSizeInBytes);
    *out_bytes = lb.bitstreamSizeInBytes;
    nv.nvEncUnlockBitstream(e->enc, e->bs);
    nv.nvEncUnmapInputResource(e->enc, mr.mappedResource);
    *out_is_key = is_key;
    return wr;
}

static void encoder_close(Encoder *e) {
    if (e->enc) {
        if (e->bs) nv.nvEncDestroyBitstreamBuffer(e->enc, e->bs);
        if (e->reg) nv.nvEncUnregisterResource(e->enc, e->reg);
        nv.nvEncDestroyEncoder(e->enc);
        e->enc = NULL;
    }
    if (e->dptr) { cu.MemFree(e->dptr); e->dptr = 0; }
}

// ---------------------------------------------------------------------------------------
// X11 capture

static int x_error_code;
static int on_x_error(Display *d, XErrorEvent *ev) {
    (void)d;
    x_error_code = ev->error_code;
    return 0;
}

// The X server is gone: nothing more can be captured, and the host restarts us. Leave at once.
// exit() would run the CUDA/NVENC exit handlers, which can deadlock on locks their threads hold;
// the kernel frees the GPU context, and the shm segment is already marked for removal.
static int on_x_gone(Display *d) {
    (void)d;
    static const char msg[] = "darpan-capture: X connection lost\n";
    ssize_t w = write(STDERR_FILENO, msg, sizeof msg - 1);
    (void)w;
    _exit(2);
}

typedef struct {
    Display *dpy;
    Window root;
    int w, h;
    XImage *img;
    XShmSegmentInfo shm;
    size_t shm_size;
    int shm_attached;
    int damage_event;
    Damage damage;
    int pinned;
} Capture;

static int capture_open(Capture *c, const char *display) {
    XSetErrorHandler(on_x_error);
    XSetIOErrorHandler(on_x_gone);
    c->dpy = XOpenDisplay(display);
    if (!c->dpy) { logf_("cannot open X display %s", display ? display : "(DISPLAY)"); return -1; }
    int scr = DefaultScreen(c->dpy);
    c->root = RootWindow(c->dpy, scr);
    XWindowAttributes wa;
    XGetWindowAttributes(c->dpy, c->root, &wa);
    c->w = wa.width & ~1;    // 4:2:0 needs even dimensions
    c->h = wa.height & ~1;
    if (!XShmQueryExtension(c->dpy)) { logf_("X server lacks MIT-SHM"); return -1; }
    int derr;
    if (!XDamageQueryExtension(c->dpy, &c->damage_event, &derr)) { logf_("X server lacks DAMAGE"); return -1; }

    Visual *vis = DefaultVisual(c->dpy, scr);
    c->img = XShmCreateImage(c->dpy, vis, (unsigned)DefaultDepth(c->dpy, scr), ZPixmap, NULL, &c->shm,
                             (unsigned)c->w, (unsigned)c->h);
    if (!c->img) { logf_("XShmCreateImage failed"); return -1; }
    if (c->img->bits_per_pixel != 32 || vis->red_mask != 0xff0000 || vis->green_mask != 0xff00 ||
        vis->blue_mask != 0xff) {
        logf_("unsupported visual (bpp %d, masks %lx/%lx/%lx)", c->img->bits_per_pixel,
              vis->red_mask, vis->green_mask, vis->blue_mask);
        return -1;
    }
    long page = sysconf(_SC_PAGESIZE);
    c->shm_size = ((size_t)c->img->bytes_per_line * (size_t)c->h + (size_t)page - 1) & ~((size_t)page - 1);
    c->shm.shmid = shmget(IPC_PRIVATE, c->shm_size, IPC_CREAT | 0600);
    if (c->shm.shmid < 0) { logf_("shmget: %s", strerror(errno)); return -1; }
    c->shm.shmaddr = c->img->data = shmat(c->shm.shmid, NULL, 0);
    if (c->shm.shmaddr == (void *)-1) { logf_("shmat: %s", strerror(errno)); return -1; }
    c->shm.readOnly = False;
    if (!XShmAttach(c->dpy, &c->shm)) { logf_("XShmAttach failed"); return -1; }
    XSync(c->dpy, False);
    shmctl(c->shm.shmid, IPC_RMID, NULL);   // freed automatically once both sides detach
    if (x_error_code) { logf_("XShmAttach X error %d", x_error_code); return -1; }
    c->shm_attached = 1;

    // StructureNotify tells us when the root window (screen) changes size.
    XSelectInput(c->dpy, c->root, StructureNotifyMask);
    c->damage = XDamageCreate(c->dpy, c->root, XDamageReportNonEmpty);
    XSync(c->dpy, False);
    return 0;
}

// Grabs the whole screen into the shm segment. Returns 0 on success.
static int capture_grab(Capture *c) {
    x_error_code = 0;
    if (!XShmGetImage(c->dpy, c->root, c->img, 0, 0, AllPlanes) || x_error_code) return -1;
    return 0;
}

// A first look for changes: every ROW_STEP-th row of the new grab against the same rows of the last
// one, which it keeps. A change that crosses one of them (scrolling, video, a window) is encoded as
// a reference frame straight away; smaller ones are caught by the probe, which then goes out itself.
// Costs about 30 µs a grab at 2560×1440.
#define ROW_STEP 32
static int rows_changed(const Capture *c, uint8_t *rows) {
    size_t bpl = (size_t)c->img->bytes_per_line, n = (size_t)c->w * 4;
    int changed = 0;
    for (int y = 0; y < c->h; y += ROW_STEP, rows += n) {
        const uint8_t *src = (const uint8_t *)c->img->data + (size_t)y * bpl;
        if (memcmp(src, rows, n)) { memcpy(rows, src, n); changed = 1; }
    }
    return changed;
}

static void capture_close(Capture *c) {
    if (!c->dpy) return;
    if (c->damage) XDamageDestroy(c->dpy, c->damage);
    if (c->shm_attached) XShmDetach(c->dpy, &c->shm);
    if (c->img) XDestroyImage(c->img);   // data pointer is the shm segment; XDestroyImage frees the struct
    if (c->shm.shmaddr && c->shm.shmaddr != (void *)-1) shmdt(c->shm.shmaddr);
    XCloseDisplay(c->dpy);
    c->dpy = NULL;
}

// ---------------------------------------------------------------------------------------
// main loop

static volatile sig_atomic_t g_quit;
static void on_signal(int s) { (void)s; g_quit = 1; }

static void usage(void) {
    fprintf(stderr,
            "usage: darpan-capture [--display :1] [--fps 60] [--bitrate KBPS] [--credits N]\n"
            "                  [--preset 1-7] [--vbv-frames N] [--gpu N] [--matrix 709|601]\n"
            "                  [--probe] [--bench N]\n");
}

int main(int argc, char **argv) {
    const char *display = NULL;
    int fps = 60, kbps = 12000, credits = 4, preset = 3, gpu = 0, vbv_frames = 4, matrix601 = 0;
    int probe = 0, bench = 0;
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        const char *v = i + 1 < argc ? argv[i + 1] : NULL;
        if (!strcmp(a, "--probe")) { probe = 1; continue; }
        if (!v) { usage(); return 2; }
        if (!strcmp(a, "--display")) display = v;
        else if (!strcmp(a, "--fps")) fps = atoi(v);
        else if (!strcmp(a, "--bitrate")) kbps = atoi(v);
        else if (!strcmp(a, "--credits")) credits = atoi(v);
        else if (!strcmp(a, "--preset")) preset = atoi(v);
        else if (!strcmp(a, "--gpu")) gpu = atoi(v);
        else if (!strcmp(a, "--vbv-frames")) vbv_frames = atoi(v);
        else if (!strcmp(a, "--matrix")) matrix601 = !strcmp(v, "601");
        else if (!strcmp(a, "--bench")) bench = atoi(v);
        else { usage(); return 2; }
        i++;
    }
    if (fps < 1) fps = 1;
    if (fps > 240) fps = 240;
    if (vbv_frames < 1) vbv_frames = 1;

    signal(SIGPIPE, SIG_IGN);
    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);
    signal(SIGHUP, on_signal);
    // Big pipe so a key frame never blocks us on the daemon's read loop.
    fcntl(STDOUT_FILENO, F_SETPIPE_SZ, 1 << 20);

    Capture cap = {0};
    Encoder enc = {0};
    uint8_t *rows = NULL;
    int rc = 2;

    if (probe) {
        enc.w = 1280; enc.h = 720; enc.fps = 60; enc.kbps = 4000; enc.vbv_frames = 4;
        if (encoder_open(&enc, gpu, preset, 0) == 0) {
            printf("{\"nvenc\":true,\"gpu\":\"%s\"}\n", enc.gpu);
            rc = 0;
        } else {
            printf("{\"nvenc\":false}\n");
            rc = 4;
        }
        encoder_close(&enc);
        if (enc.ctx) cu.CtxDestroy(enc.ctx);
        return rc;
    }

    if (capture_open(&cap, display)) { emit_info("{\"ev\":\"error\",\"msg\":\"x11 capture init failed\"}"); goto out; }
    enc.w = (uint32_t)cap.w;
    enc.h = (uint32_t)cap.h;
    enc.fps = (uint32_t)fps;
    enc.kbps = (uint32_t)kbps;
    enc.vbv_frames = (uint32_t)vbv_frames;
    if (encoder_open(&enc, gpu, preset, matrix601)) {
        emit_info("{\"ev\":\"error\",\"msg\":\"nvenc init failed\"}");
        rc = 4;
        goto out;
    }
    // Pin the shm segment so CUDA copies it by DMA straight from the X server's buffer.
    if (cu.MemHostRegister(cap.shm.shmaddr, cap.shm_size, 0x01 /* PORTABLE */) == CUDA_SUCCESS)
        cap.pinned = 1;
    else
        logf_("cuMemHostRegister failed; using pageable copies");

    emit_info("{\"ev\":\"start\",\"w\":%d,\"h\":%d,\"enc\":\"nvenc\",\"gpu\":\"%s\",\"preset\":%d,\"fps\":%d,\"kbps\":%d}",
              cap.w, cap.h, enc.gpu, preset, fps, kbps);

    CUDA_MEMCPY2D cp = {0};
    cp.srcMemoryType = CU_MEMORYTYPE_HOST;
    cp.srcHost = cap.shm.shmaddr;
    cp.srcPitch = (size_t)cap.img->bytes_per_line;
    cp.dstMemoryType = CU_MEMORYTYPE_DEVICE;
    cp.dstDevice = enc.dptr;
    cp.dstPitch = enc.pitch;
    cp.WidthInBytes = (size_t)cap.w * 4;
    cp.Height = (size_t)cap.h;
    // The last grab's sampled rows, for the change check. Without them every frame is sent.
    if (enc.h264.ok && !bench) rows = calloc((size_t)(cap.h + ROW_STEP - 1) / ROW_STEP, (size_t)cap.w * 4);

    const int xfd = ConnectionNumber(cap.dpy);
    int dirty = 1, force = 1, want_idr = 1;
    int ref_next = 0;               // a probe was sent: the next picture must be a reference
    uint64_t min_interval = 1000000u / (unsigned)fps, next_allowed = 0;
    // Quality refresh: after the screen settles, re-encode the same pixels a couple of times so
    // the encoder can refine detail that the first (rate-limited) encode had to approximate.
    static const uint32_t refresh_delay_ms[] = {90, 400};
    int refresh_step = -1;          // -1 = nothing scheduled
    uint64_t refresh_at = 0;
    uint64_t last_ts = 0;
    char cmdbuf[4096];
    size_t cmdlen = 0;
    uint64_t bench_start = now_us(), bench_bytes = 0, bench_cap = 0, bench_enc = 0;
    int bench_done = 0;
    if (bench) { credits = 1 << 30; min_interval = 0; }

    rc = 0;
    while (!g_quit) {
        uint64_t now = now_us();
        int can_send = credits > 0;
        int want_frame = bench || dirty || force;
        int timeout = -1;
        if (want_frame && can_send) {
            timeout = next_allowed > now ? (int)((next_allowed - now + 999) / 1000) : 0;
        } else if (refresh_step >= 0 && can_send) {
            timeout = refresh_at > now ? (int)((refresh_at - now + 999) / 1000) : 0;
        }

        struct pollfd pfd[2] = {{xfd, POLLIN, 0}, {STDIN_FILENO, POLLIN, 0}};
        if (timeout != 0 && !XPending(cap.dpy)) {
            int pr = poll(pfd, bench ? 1 : 2, timeout);
            if (pr < 0 && errno != EINTR) { logf_("poll: %s", strerror(errno)); rc = 2; break; }
        } else {
            poll(pfd, bench ? 1 : 2, 0);
        }

        // ---- commands from the daemon
        if (!bench && (pfd[1].revents & (POLLIN | POLLHUP | POLLERR))) {
            ssize_t r = read(STDIN_FILENO, cmdbuf + cmdlen, sizeof cmdbuf - 1 - cmdlen);
            if (r <= 0) { if (r == 0 || errno != EINTR) break; }   // daemon went away
            else {
                cmdlen += (size_t)r;
                cmdbuf[cmdlen] = 0;
                char *line = cmdbuf, *nl;
                while ((nl = memchr(line, '\n', cmdlen - (size_t)(line - cmdbuf)))) {
                    *nl = 0;
                    switch (line[0]) {
                    case 'c': credits += atoi(line + 1); if (credits > 64) credits = 64; break;
                    case 'k': want_idr = 1; force = 1; break;
                    case 'r': force = 1; break;
                    case 'p': credits = 0; refresh_step = -1; break;
                    case 'b': if (encoder_set_bitrate(&enc, (uint32_t)atoi(line + 1))) { rc = 2; goto out; } break;
                    case 'f': {
                        int f = atoi(line + 1);
                        if (f >= 1 && f <= 240) min_interval = 1000000u / (unsigned)f;
                        break;
                    }
                    case 'q': goto out;
                    default: break;
                    }
                    line = nl + 1;
                }
                cmdlen -= (size_t)(line - cmdbuf);
                memmove(cmdbuf, line, cmdlen);
                if (cmdlen == sizeof cmdbuf - 1) cmdlen = 0;   // garbage line; drop it
            }
        }

        // ---- X events: damage (content changed) and root resize
        while (XPending(cap.dpy)) {
            XEvent ev;
            XNextEvent(cap.dpy, &ev);
            if (ev.type == cap.damage_event + XDamageNotify) {
                dirty = 1;
            } else if (ev.type == ConfigureNotify && ev.xconfigure.window == cap.root) {
                int nw = ev.xconfigure.width & ~1, nh = ev.xconfigure.height & ~1;
                if (nw != cap.w || nh != cap.h) {
                    emit_info("{\"ev\":\"resize\",\"w\":%d,\"h\":%d}", nw, nh);
                    rc = 3;
                    goto out;
                }
            }
        }

        now = now_us();
        if ((bench || dirty || force) && credits > 0 && now >= next_allowed) {
            // Reset damage *before* grabbing, so changes made during the grab re-arm it.
            XDamageSubtract(cap.dpy, cap.damage, None, None);
            uint64_t t0 = now_us();
            if (capture_grab(&cap)) {
                // Usually a transient BadMatch while the screen is being reconfigured.
                logf_("XShmGetImage failed (X error %d)", x_error_code);
                XSync(cap.dpy, False);
                next_allowed = now + 50000;
                continue;
            }
            CUresult cr = cu.Memcpy2D(&cp);
            if (cr != CUDA_SUCCESS) { logf_("cuMemcpy2D: %s", cu_err(cr)); rc = 2; goto out; }
            uint64_t t1 = now_us();
            uint64_t ts = t0 > last_ts ? t0 : last_ts + 1;
            last_ts = ts;
            int is_key = 0;
            uint32_t bytes = 0;
            // Damage isn't news by itself: with a compositor, most damaged frames are identical.
            if (rows && !rows_changed(&cap, rows) && !force && !want_idr && !ref_next) {
                int same = encoder_encode(&enc, 0, 1, 0, ts, (uint32_t)(t1 - t0), &is_key, &bytes);
                if (same < 0) {
                    if (errno != EPIPE) rc = 2;
                    goto out;
                }
                if (same) {                   // the viewer would see no difference: send nothing
                    dirty = 0;
                    next_allowed = t0 + min_interval;
                    continue;
                }
                ref_next = 1;                 // the probe went out as it is; catch the reference up next
            } else {
                if (encoder_encode(&enc, want_idr, 0, 0, ts, (uint32_t)(t1 - t0), &is_key, &bytes)) {
                    if (errno != EPIPE) rc = 2;   // EPIPE = daemon closed our pipe: normal exit
                    goto out;
                }
                ref_next = 0;
            }
            if (!bench) credits--;
            dirty = force = want_idr = 0;
            next_allowed = t0 + min_interval;
            refresh_step = 0;
            refresh_at = now_us() + refresh_delay_ms[0] * 1000u;
            if (bench) {
                bench_bytes += bytes;
                bench_cap += t1 - t0;
                bench_enc += now_us() - t1;
                if (++bench_done >= bench) break;
            }
        } else if (!dirty && !force && refresh_step >= 0 && credits > 0 && now >= refresh_at) {
            // Pixels on the GPU are still the latest screen content: re-encode, no capture.
            int is_key = 0;
            uint32_t bytes = 0;
            uint64_t ts = last_ts + 1;
            last_ts = ts;
            if (encoder_encode(&enc, 0, 0, FLAG_REFRESH, ts, 0, &is_key, &bytes)) {
                if (errno != EPIPE) rc = 2;
                goto out;
            }
            ref_next = 0;
            credits--;
            refresh_step++;
            if (refresh_step < (int)(sizeof refresh_delay_ms / sizeof refresh_delay_ms[0]))
                refresh_at = now + refresh_delay_ms[refresh_step] * 1000u;
            else
                refresh_step = -1;
        }
    }
    if (bench && bench_done) {
        double secs = (double)(now_us() - bench_start) / 1e6;
        logf_("bench: %d frames in %.2fs = %.1f fps, avg capture+upload %.2f ms, avg encode %.2f ms, avg %.1f KB/frame",
              bench_done, secs, bench_done / secs, bench_cap / 1000.0 / bench_done,
              bench_enc / 1000.0 / bench_done, bench_bytes / 1024.0 / bench_done);
    }
out:
    free(rows);
    if (cap.pinned) cu.MemHostUnregister(cap.shm.shmaddr);
    encoder_close(&enc);
    if (enc.ctx) cu.CtxDestroy(enc.ctx);
    capture_close(&cap);
    return rc;
}
