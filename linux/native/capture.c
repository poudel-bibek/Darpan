// SPDX-License-Identifier: MIT
// darpan-capture — damage-driven X11 screen capture + NVIDIA NVENC H.264 encoder for Darpan.
//
// Why this exists: the host must cost next to nothing on a machine busy with other GPU/CPU work.
//   * Nothing runs unless the X server reports damage (the screen changed) — an idle
//     screen costs 0 CPU and 0 bandwidth. Damage alone isn't enough to send a frame: one that is
//     identical to the last isn't even encoded (see "Unchanged frames").
//   * Frames are only produced while the daemon has granted credits (one credit per frame,
//     returned when the client acks it), so a slow network makes us encode fewer frames
//     instead of queueing stale ones.
//   * Pixels go X server -> XShm segment -> GPU, with no CPU pixel copies and no CPU colour
//     conversion. Through Vulkan Video (vkenc.c), the GPU imports the segment and a compute shader
//     makes NV12 for NVENC: about 30 MB of VRAM. Without it, through CUDA: the segment is pinned for
//     DMA and NVENC converts BGRx itself, but the CUDA context alone takes about 200 MB.
//
// I/O protocol with the daemon (darpan/capture.py):
//   stdout: records  [u32 len][u32 flags][u64 capture_ts_us][u32 cap_us][u32 enc_us] + len bytes
//           (native little-endian). flags: bit0 key frame, bit1 refresh, bit31 JSON info record.
//           The timestamp is CLOCK_MONOTONIC in µs (same clock as Python's time.monotonic()).
//   stdin : one command per line:  "c N" add N credits · "k" next frame is a key frame ·
//           "b KBPS" bitrate · "f FPS" max frame rate · "r" encode now · "q" quit
//
// Exit codes: 0 normal, 2 error (also: the X server went away), 3 screen size changed (restart me),
// 4 NVENC unavailable, 5 Vulkan Video failed after it started (NVENC through CUDA may still work).
// DARPAN_NVENC_CUDA=1 skips Vulkan Video and encodes through CUDA.

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

#include "vkenc.h"
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
typedef CUresult CUDAAPI tcuMemsetD32_v2(CUdeviceptr d, unsigned int v, size_t n);

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
    tcuDeviceGetUuid *DeviceGetUuid;
    tcuMemAlloc_v2 *MemAlloc;
    tcuMemsetD32_v2 *MemsetD32;
    tcuMemcpyDtoH_v2 *MemcpyDtoH;
    tcuModuleLoadData *ModuleLoadData;
    tcuModuleGetFunction *ModuleGetFunction;
    tcuModuleUnload *ModuleUnload;
    tcuLaunchKernel *LaunchKernel;
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
    LOAD(DeviceGetUuid, "cuDeviceGetUuid");
    LOAD(MemAlloc, "cuMemAlloc_v2");
    LOAD(MemsetD32, "cuMemsetD32_v2");
    LOAD(MemcpyDtoH, "cuMemcpyDtoH_v2");
    LOAD(ModuleLoadData, "cuModuleLoadData");
    LOAD(ModuleGetFunction, "cuModuleGetFunction");
    LOAD(ModuleUnload, "cuModuleUnload");
    LOAD(LaunchKernel, "cuLaunchKernel");
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
// of those frames are pixel-identical to the one before. So the GPU compares each new frame with
// the last before it's encoded, and an identical one isn't encoded at all: through Vulkan in the
// conversion shader, which reads every pixel anyway, and through CUDA with the kernel below. On the
// CPU a compare would cost more than the encode. Asking the encoder instead (a probe frame, dropped
// if it's all P_Skip) fails with NVENC's two-pass rate control, which never encodes an unchanged
// picture as all P_Skip.

// 16 bytes per thread: the new frame (cur) against a copy of the last (prev). A difference is
// copied over and sets *flag. No stack, so the context's stays at zero (see encoder_open).
static const char cmp_ptx[] =
    ".version 6.0\n.target sm_52\n.address_size 64\n"
    ".visible .entry cmp(.param .u64 cur, .param .u64 prev, .param .u64 flag, .param .u32 n) {\n"
    "  .reg .pred %p<3>;\n  .reg .b32 %r<16>;\n  .reg .b64 %rd<8>;\n"
    "  ld.param.u64 %rd1, [cur];\n  ld.param.u64 %rd2, [prev];\n  ld.param.u64 %rd3, [flag];\n"
    "  ld.param.u32 %r1, [n];\n"
    "  cvta.to.global.u64 %rd1, %rd1;\n  cvta.to.global.u64 %rd2, %rd2;\n  cvta.to.global.u64 %rd3, %rd3;\n"
    "  mov.u32 %r2, %ctaid.x;\n  mov.u32 %r3, %ntid.x;\n  mov.u32 %r4, %tid.x;\n"
    "  mad.lo.s32 %r5, %r2, %r3, %r4;\n  setp.ge.u32 %p1, %r5, %r1;\n  @%p1 bra DONE;\n"
    "  mul.wide.u32 %rd4, %r5, 16;\n  add.s64 %rd5, %rd1, %rd4;\n  add.s64 %rd6, %rd2, %rd4;\n"
    "  ld.global.v4.u32 {%r6, %r7, %r8, %r9}, [%rd5];\n  ld.global.v4.u32 {%r10, %r11, %r12, %r13}, [%rd6];\n"
    "  setp.ne.u32 %p2, %r6, %r10;\n  setp.ne.or.u32 %p2, %r7, %r11, %p2;\n"
    "  setp.ne.or.u32 %p2, %r8, %r12, %p2;\n  setp.ne.or.u32 %p2, %r9, %r13, %p2;\n  @!%p2 bra DONE;\n"
    "  st.global.v4.u32 [%rd6], {%r6, %r7, %r8, %r9};\n  mov.u32 %r14, 1;\n  st.global.u32 [%rd3], %r14;\n"
    "DONE:\n  ret;\n}\n";

typedef struct {
    VkEnc *vk;                 // Vulkan Video; otherwise NVENC through CUDA (the fields below)
    int c444;                  // 4:4:4 (High 4:4:4 Predictive): asked for, then what the encoder does
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
    uint32_t poc;              // display POC of the last picture
    CUdeviceptr prev, flag;    // the unchanged-frame compare: the last frame, and its result
    CUmodule mod;
    CUfunction cmp;            // NULL if the driver can't load it: then every frame counts as changed
    char gpu[128];
} Encoder;

#define NVCHECK(call) do { NVENCSTATUS s_ = (call); if (s_ != NV_ENC_SUCCESS) { \
    logf_("%s failed: %s (%s)", #call, nv_status_name(s_), e->enc && nv.nvEncGetLastErrorString ? nv.nvEncGetLastErrorString(e->enc) : ""); \
    return -1; } } while (0)
#define CUCHECK(call) do { CUresult r_ = (call); if (r_ != CUDA_SUCCESS) { \
    logf_("%s failed: %s", #call, cu_err(r_)); return -1; } } while (0)

// 1 if the frame just copied to e->dptr differs from the last one, 0 if not, -1 on failure.
static int cuda_changed(Encoder *e) {
    if (!e->cmp) return 1;
    unsigned n = (unsigned)(e->pitch * e->h / 16);
    uint32_t f = 0;
    CUCHECK(cu.MemsetD32(e->flag, 0, 1));
    void *args[] = {&e->dptr, &e->prev, &e->flag, &n};
    CUCHECK(cu.LaunchKernel(e->cmp, (n + 255) / 256, 1, 1, 256, 1, 1, 0, NULL, args, NULL));
    CUCHECK(cu.MemcpyDtoH(&f, e->flag, sizeof f));
    return f != 0;
}

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

#define MAX_KBPS 200000

static int vk_failed;          // Vulkan Video broke after it started: exit 5, so the daemon tries CUDA

// src: the frame buffer (page-aligned, src_size a multiple of the page size), read by the GPU.
static int encoder_open(Encoder *e, int gpu, int preset, int matrix601, void *src, size_t src_size,
                        uint32_t src_pitch) {
    // --gpu and CUDA_VISIBLE_DEVICES speak CUDA's numbering, and Vulkan counts devices its own way:
    // any GPU but the first is looked up by its UUID. That loads CUDA but creates no context.
    uint8_t uuid[16];
    const uint8_t *which = NULL;
    int known = gpu == 0 && !getenv("CUDA_VISIBLE_DEVICES");
    if (!known) {
        CUdevice d;
        CUuuid u;
        if (!cuda_load() && cu.Init(0) == CUDA_SUCCESS && cu.DeviceGet(&d, gpu) == CUDA_SUCCESS &&
            cu.DeviceGetUuid(&u, d) == CUDA_SUCCESS) {
            memcpy(uuid, u.bytes, sizeof uuid);
            which = uuid;
            known = 1;
        }
    }
    if (known && !getenv("DARPAN_NVENC_CUDA")) {
        memset(src, 0, src_size);      // the GPU can only import pages that exist
        VkEncParams vp = {which, e->w, e->h, e->fps, e->kbps, e->vbv_frames, MAX_KBPS, preset, matrix601,
                          e->c444, src, src_size, src_pitch};
        const uint8_t *ps;
        uint32_t ps_len;
        if (!(e->vk = vkenc_open(&vp, e->gpu, &ps, &ps_len)) && vp.chroma444) {
            logf_("no 4:4:4 through Vulkan Video: 4:2:0");
            vp.chroma444 = e->c444 = 0;
            e->vk = vkenc_open(&vp, e->gpu, &ps, &ps_len);
        }
        if (e->vk) return 0;
        logf_("no Vulkan Video: NVENC through CUDA");
    }
    if (cuda_load() || nvenc_load()) return -1;
    CUdevice dev;
    CUCHECK(cu.Init(0));
    CUCHECK(cu.DeviceGet(&dev, gpu));
    cu.DeviceGetName(e->gpu, sizeof e->gpu, dev);
    // BLOCKING_SYNC: when the driver waits (for DMA / encode completion) the thread sleeps
    // instead of spinning a CPU core.
    CUCHECK(cu.CtxCreate(&e->ctx, CU_CTX_SCHED_BLOCKING_SYNC, dev));
    // Our one kernel (the unchanged-frame compare) needs none of CUDA's default per-thread stack
    // reservation (sized for every resident thread on every SM), device malloc heap or printf
    // buffer: pure waste of VRAM that a training job could use. Shrink them to the minimum.
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
    if (e->c444) {                   // only if this NVENC can
        NV_ENC_CAPS_PARAM cp = {NV_ENC_CAPS_PARAM_VER, NV_ENC_CAPS_SUPPORT_YUV444_ENCODE, {0}};
        int yes = 0;
        if (nv.nvEncGetEncodeCaps(e->enc, NV_ENC_CODEC_H264_GUID, &cp, &yes) != NV_ENC_SUCCESS || !yes) {
            logf_("no 4:4:4 on this NVENC: 4:2:0");
            e->c444 = 0;
        }
    }
    // (4:4:4 comes out CAVLC whatever is asked: NVENC has CABAC only for 4:2:0)
    e->cfg.profileGUID = e->c444 ? NV_ENC_H264_PROFILE_HIGH_444_GUID : NV_ENC_H264_PROFILE_HIGH_GUID;
    e->cfg.gopLength = NVENC_INFINITE_GOPLENGTH;   // key frames only on demand
    e->cfg.frameIntervalP = 1;                      // no B-frames
    set_rc(e);

    NV_ENC_CONFIG_H264 *h = &e->cfg.encodeCodecConfig.h264Config;
    h->idrPeriod = NVENC_INFINITE_GOPLENGTH;
    h->repeatSPSPPS = 1;          // SPS/PPS in front of every IDR (decoders can join anytime)
    h->outputAUD = 0;
    h->sliceMode = 0;
    h->sliceModeData = 0;
    h->chromaFormatIDC = e->c444 ? 3 : 1;
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
    ip->enablePTD = 0;          // we choose each picture's type: IDR only on request
    ip->encodeConfig = &e->cfg;
    ip->tuningInfo = NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY;
    ip->maxEncodeWidth = e->w;
    ip->maxEncodeHeight = e->h;
    NVCHECK(nv.nvEncInitializeEncoder(e->enc, ip));

    CUCHECK(cu.MemAllocPitch(&e->dptr, &e->pitch, (size_t)e->w * 4, e->h, 16));
    CUCHECK(cu.MemAlloc(&e->prev, e->pitch * e->h));
    CUCHECK(cu.MemAlloc(&e->flag, 4));
    if (cu.ModuleLoadData(&e->mod, cmp_ptx) != CUDA_SUCCESS || cu.ModuleGetFunction(&e->cmp, e->mod, "cmp") != CUDA_SUCCESS) {
        logf_("no frame compare on this GPU: unchanged frames will be sent too");
        e->cmp = NULL;
    }
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
    return 0;
}

static int encoder_set_bitrate(Encoder *e, uint32_t kbps) {
    if (kbps < 100) kbps = 100;
    if (kbps > MAX_KBPS) kbps = MAX_KBPS;
    if (kbps == e->kbps) return 0;
    e->kbps = kbps;
    if (e->vk) return vkenc_set_bitrate(e->vk, kbps);
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

// Encodes the frame currently on the GPU and writes it to stdout.
static int encoder_encode(Encoder *e, int force_idr, uint32_t extra_flags, uint64_t ts,
                          uint32_t cap_us, int *out_is_key, uint32_t *out_bytes) {
    uint64_t t0 = now_us();
    if (e->vk) {
        const uint8_t *bs;
        uint32_t n;
        if (vkenc_encode(e->vk, force_idr, &bs, &n)) { vk_failed = 1; return -1; }
        uint32_t enc_us = (uint32_t)(now_us() - t0);
        *out_bytes = n;
        *out_is_key = force_idr;
        return emit_record((force_idr ? FLAG_KEY : 0) | extra_flags, ts, cap_us, enc_us, bs, n);
    }
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
    e->poc = force_idr ? 0 : e->poc + 2;           // a frame's two fields
    pp.codecPicParams.h264PicParams.displayPOCSyntax = e->poc;
    pp.codecPicParams.h264PicParams.refPicFlag = 1;
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
    int wr = emit_record(flags, ts, cap_us, enc_us, lb.bitstreamBufferPtr, lb.bitstreamSizeInBytes);
    *out_bytes = lb.bitstreamSizeInBytes;
    nv.nvEncUnlockBitstream(e->enc, e->bs);
    nv.nvEncUnmapInputResource(e->enc, mr.mappedResource);
    *out_is_key = is_key;
    return wr;
}

static void encoder_close(Encoder *e) {
    vkenc_close(e->vk);
    e->vk = NULL;
    if (e->enc) {
        if (e->bs) nv.nvEncDestroyBitstreamBuffer(e->enc, e->bs);
        if (e->reg) nv.nvEncUnregisterResource(e->enc, e->reg);
        nv.nvEncDestroyEncoder(e->enc);
        e->enc = NULL;
    }
    if (e->dptr) { cu.MemFree(e->dptr); e->dptr = 0; }
    if (e->prev) { cu.MemFree(e->prev); e->prev = 0; }
    if (e->flag) { cu.MemFree(e->flag); e->flag = 0; }
    if (e->mod) { cu.ModuleUnload(e->mod); e->mod = NULL; }
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
    x_error_code = 0;
    if (XShmQueryExtension(c->dpy) && XShmAttach(c->dpy, &c->shm)) XSync(c->dpy, False);
    else x_error_code = -1;
    shmctl(c->shm.shmid, IPC_RMID, NULL);   // freed automatically once both sides detach
    // An X server running as another user (the login screen's) can't map our segment. Then frames
    // come over the X connection into it instead: slower, but a login screen hardly changes.
    if (x_error_code) logf_("no shared memory with the X server (%d); copying frames", x_error_code);
    else c->shm_attached = 1;

    // StructureNotify tells us when the root window (screen) changes size.
    XSelectInput(c->dpy, c->root, StructureNotifyMask);
    c->damage = XDamageCreate(c->dpy, c->root, XDamageReportNonEmpty);
    XSync(c->dpy, False);
    return 0;
}

// Grabs the whole screen into the shm segment. Returns 0 on success.
static int capture_grab(Capture *c) {
    x_error_code = 0;
    if (c->shm_attached)
        return !XShmGetImage(c->dpy, c->root, c->img, 0, 0, AllPlanes) || x_error_code ? -1 : 0;
    XImage *t = XGetImage(c->dpy, c->root, 0, 0, (unsigned)c->w, (unsigned)c->h, AllPlanes, ZPixmap);
    if (!t || x_error_code) { if (t) XDestroyImage(t); return -1; }
    for (int y = 0; y < c->h; y++)
        memcpy(c->img->data + (size_t)y * (size_t)c->img->bytes_per_line,
               t->data + (size_t)y * (size_t)t->bytes_per_line, (size_t)c->w * 4);
    XDestroyImage(t);
    return 0;
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
            "                  [--chroma 420|444] [--probe] [--bench N]\n");
}

int main(int argc, char **argv) {
    const char *display = NULL;
    int fps = 60, kbps = 12000, credits = 4, preset = 3, gpu = 0, vbv_frames = 4, matrix601 = 0;
    int probe = 0, bench = 0, chroma444 = 0;
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
        else if (!strcmp(a, "--chroma")) chroma444 = !strcmp(v, "444");
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
    int rc = 2;

    if (probe) {
        enc.w = 1280; enc.h = 720; enc.fps = 60; enc.kbps = 4000; enc.vbv_frames = 4;
        size_t size = (size_t)enc.w * enc.h * 4;       // a page multiple
        void *frame = aligned_alloc((size_t)sysconf(_SC_PAGESIZE), size);
        if (frame && encoder_open(&enc, gpu, preset, 0, frame, size, enc.w * 4) == 0) {
            printf("{\"nvenc\":true,\"gpu\":\"%s\",\"api\":\"%s\"}\n", enc.gpu, enc.vk ? "vulkan" : "cuda");
            rc = 0;
        } else {
            printf("{\"nvenc\":false}\n");
            rc = 4;
        }
        encoder_close(&enc);
        if (enc.ctx) cu.CtxDestroy(enc.ctx);
        free(frame);
        return rc;
    }

    if (capture_open(&cap, display)) { emit_info("{\"ev\":\"error\",\"msg\":\"x11 capture init failed\"}"); goto out; }
    enc.w = (uint32_t)cap.w;
    enc.h = (uint32_t)cap.h;
    enc.fps = (uint32_t)fps;
    enc.kbps = (uint32_t)kbps;
    enc.vbv_frames = (uint32_t)vbv_frames;
    enc.c444 = chroma444;
    if (encoder_open(&enc, gpu, preset, matrix601, cap.shm.shmaddr, cap.shm_size, (uint32_t)cap.img->bytes_per_line)) {
        emit_info("{\"ev\":\"error\",\"msg\":\"nvenc init failed\"}");
        rc = 4;
        goto out;
    }
    // CUDA: pin the shm segment so it's copied by DMA straight from the X server's buffer.
    // (Through Vulkan, the GPU already reads it where it is.)
    if (!enc.vk) {
        if (cu.MemHostRegister(cap.shm.shmaddr, cap.shm_size, 0x01 /* PORTABLE */) == CUDA_SUCCESS)
            cap.pinned = 1;
        else
            logf_("cuMemHostRegister failed; using pageable copies");
    }

    emit_info("{\"ev\":\"start\",\"w\":%d,\"h\":%d,\"enc\":\"nvenc\",\"api\":\"%s\",\"chroma\":%d,\"gpu\":\"%s\",\"preset\":%d,\"fps\":%d,\"kbps\":%d}",
              cap.w, cap.h, enc.vk ? "vulkan" : "cuda", enc.c444 ? 444 : 420, enc.gpu, preset, fps, kbps);

    CUDA_MEMCPY2D cp = {0};
    cp.srcMemoryType = CU_MEMORYTYPE_HOST;
    cp.srcHost = cap.shm.shmaddr;
    cp.srcPitch = (size_t)cap.img->bytes_per_line;
    cp.dstMemoryType = CU_MEMORYTYPE_DEVICE;
    cp.dstDevice = enc.dptr;
    cp.dstPitch = enc.pitch;
    cp.WidthInBytes = (size_t)cap.w * 4;
    cp.Height = (size_t)cap.h;

    const int xfd = ConnectionNumber(cap.dpy);
    int dirty = 1, force = 1, want_idr = 1;
    uint64_t min_interval = 1000000u / (unsigned)fps, next_allowed = 0;
    // Quality refresh: after the screen settles, re-encode the same pixels six times over about 2 s,
    // so the encoder can refine detail the first (rate-limited) encode had to approximate. Two left
    // text visibly soft; six sharpen it (measured at 12 Mbit/s, 2560×1440: 32.3 → 34.0 dB PSNR through
    // Vulkan, 32.5 → 33.7 dB through CUDA). Nothing is sent once they're done.
    static const uint32_t refresh_delay_ms[] = {90, 200, 300, 400, 500, 600};
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
                logf_("screen grab failed (X error %d)", x_error_code);
                XSync(cap.dpy, False);
                next_allowed = now + 50000;
                continue;
            }
            int changed;
            if (enc.vk) {
                if ((changed = vkenc_convert(enc.vk)) < 0) { vk_failed = 1; goto out; }
            } else {
                CUresult cr = cu.Memcpy2D(&cp);
                if (cr != CUDA_SUCCESS) { logf_("cuMemcpy2D: %s", cu_err(cr)); rc = 2; goto out; }
                if ((changed = cuda_changed(&enc)) < 0) { rc = 2; goto out; }
            }
            uint64_t t1 = now_us();
            // Damage isn't news by itself: with a compositor, most damaged frames are identical.
            if (!changed && !force && !want_idr && !bench) {   // the viewer has this picture: send nothing
                if (enc.vk && vkenc_skip(enc.vk)) { vk_failed = 1; goto out; }
                dirty = 0;
                next_allowed = t0 + min_interval;
                continue;
            }
            uint64_t ts = t0 > last_ts ? t0 : last_ts + 1;
            last_ts = ts;
            int is_key = 0;
            uint32_t bytes = 0;
            if (encoder_encode(&enc, want_idr, 0, ts, (uint32_t)(t1 - t0), &is_key, &bytes)) {
                if (errno != EPIPE) rc = 2;   // EPIPE = daemon closed our pipe: normal exit
                goto out;
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
            if (encoder_encode(&enc, 0, FLAG_REFRESH, ts, 0, &is_key, &bytes)) {
                if (errno != EPIPE) rc = 2;
                goto out;
            }
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
    if (vk_failed) rc = 5;
    if (cap.pinned) cu.MemHostUnregister(cap.shm.shmaddr);
    encoder_close(&enc);
    if (enc.ctx) cu.CtxDestroy(enc.ctx);
    capture_close(&cap);
    return rc;
}
