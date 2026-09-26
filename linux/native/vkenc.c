// H.264 through Vulkan Video (VK_KHR_video_encode_h264): the same NVENC hardware as the CUDA
// path, without CUDA. A CUDA context costs about 200 MB of VRAM however little it does; this whole
// encoder needs about 30 MB at 2560×1440. Vulkan Video takes only YUV pictures, so a compute shader
// (rgb2nv12.comp) converts the X server's BGRx frame into NV12. It reads the frame straight from
// the shared-memory segment, which the GPU imports (VK_EXT_external_memory_host): no CPU copy.
//
// The stream matches the CUDA path's: High profile, CABAC, one reference frame, IDR only on
// request with SPS/PPS in front, CBR with a few frames of VBV, and non-reference P frames
// ("probes") that the caller may drop.
#define _GNU_SOURCE
#define VK_NO_PROTOTYPES
#include "vkenc.h"

#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <vulkan/vulkan_core.h>

#include "rgb2nv12.h"

static void vlog(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fputs("darpan-capture: vulkan: ", stderr);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
}

// ---------------------------------------------------------------------------------------
// entry points (dlopen'ed: no link-time dependency on the Vulkan loader)

#define VK_INSTANCE_FNS(X) X(vkDestroyInstance) X(vkEnumeratePhysicalDevices) X(vkGetPhysicalDeviceProperties2) \
    X(vkGetPhysicalDeviceQueueFamilyProperties) X(vkGetPhysicalDeviceMemoryProperties) X(vkCreateDevice) \
    X(vkGetDeviceProcAddr) X(vkEnumerateDeviceExtensionProperties) X(vkGetPhysicalDeviceVideoCapabilitiesKHR)
#define VK_DEVICE_FNS(X) X(vkDestroyDevice) X(vkGetDeviceQueue) X(vkDeviceWaitIdle) X(vkCreateBuffer) \
    X(vkDestroyBuffer) X(vkGetBufferMemoryRequirements) X(vkAllocateMemory) X(vkFreeMemory) X(vkBindBufferMemory) \
    X(vkMapMemory) X(vkCreateImage) X(vkDestroyImage) X(vkGetImageMemoryRequirements) X(vkBindImageMemory) \
    X(vkCreateImageView) X(vkDestroyImageView) X(vkCreateCommandPool) X(vkDestroyCommandPool) \
    X(vkAllocateCommandBuffers) X(vkBeginCommandBuffer) X(vkEndCommandBuffer) X(vkQueueSubmit2) X(vkCreateFence) \
    X(vkDestroyFence) X(vkWaitForFences) X(vkResetFences) X(vkCreateSemaphore) X(vkDestroySemaphore) \
    X(vkCreateQueryPool) X(vkDestroyQueryPool) X(vkGetQueryPoolResults) X(vkCmdResetQueryPool) X(vkCmdBeginQuery) \
    X(vkCmdEndQuery) X(vkCmdPipelineBarrier2) X(vkCmdCopyBufferToImage) X(vkCmdBindPipeline) \
    X(vkCmdBindDescriptorSets) X(vkCmdPushConstants) X(vkCmdDispatch) X(vkCreateShaderModule) \
    X(vkDestroyShaderModule) X(vkCreateDescriptorSetLayout) X(vkDestroyDescriptorSetLayout) \
    X(vkCreatePipelineLayout) X(vkDestroyPipelineLayout) X(vkCreateComputePipelines) X(vkDestroyPipeline) \
    X(vkCreateDescriptorPool) X(vkDestroyDescriptorPool) X(vkAllocateDescriptorSets) X(vkUpdateDescriptorSets) \
    X(vkGetMemoryHostPointerPropertiesEXT) X(vkCreateVideoSessionKHR) X(vkDestroyVideoSessionKHR) \
    X(vkGetVideoSessionMemoryRequirementsKHR) X(vkBindVideoSessionMemoryKHR) X(vkCreateVideoSessionParametersKHR) \
    X(vkDestroyVideoSessionParametersKHR) X(vkGetEncodedVideoSessionParametersKHR) X(vkCmdBeginVideoCodingKHR) \
    X(vkCmdEndVideoCodingKHR) X(vkCmdControlVideoCodingKHR) X(vkCmdEncodeVideoKHR)
#define DECLARE(n) static PFN_##n n;
static PFN_vkGetInstanceProcAddr vkGetInstanceProcAddr;
static PFN_vkCreateInstance vkCreateInstance;
VK_INSTANCE_FNS(DECLARE)
VK_DEVICE_FNS(DECLARE)

// ---------------------------------------------------------------------------------------

// Rate control, as a unit: the session's current state must be restated when coding begins,
// so a change is prepared in a second copy and swapped in once applied.
typedef struct {
    VkVideoEncodeRateControlInfoKHR rc;
    VkVideoEncodeH264RateControlInfoKHR h264;
    VkVideoEncodeRateControlLayerInfoKHR layer;
    VkVideoEncodeH264RateControlLayerInfoKHR h264_layer;
} RateControl;

struct VkEnc {
    void *lib;
    VkInstance inst;
    VkPhysicalDevice pd;
    VkDevice dev;
    VkPhysicalDeviceMemoryProperties mem;
    uint32_t cfam, efam;                 // compute (conversion) and encode queue families
    VkQueue cq, eq;
    uint32_t w, h, cw, ch;               // visible and coded (16-aligned) size
    uint32_t src_pitch_px, matrix601;

    VkVideoEncodeH264ProfileInfoKHR h264_profile;
    VkVideoEncodeUsageInfoKHR usage;
    VkVideoProfileInfoKHR profile;
    VkVideoProfileListInfoKHR profiles;

    VkBuffer src, nv12, bs;
    VkDeviceMemory src_mem, nv12_mem, bs_mem, pic_mem, dpb_mem;
    VkDeviceMemory session_mem[16];
    uint32_t session_mem_n;
    uint8_t *bs_ptr;
    VkDeviceSize bs_size;
    VkImage pic, dpb;
    VkImageView pic_view, dpb_view[2];
    VkVideoSessionKHR session;
    VkVideoSessionParametersKHR params;
    VkQueryPool query;
    VkCommandPool cpool, epool;
    VkCommandBuffer ccb, ecb;
    VkSemaphore converted;
    VkFence done;
    VkShaderModule shader;
    VkDescriptorSetLayout dsl;
    VkPipelineLayout layout;
    VkPipeline pipe;
    VkDescriptorPool dpool;
    VkDescriptorSet ds;

    RateControl cur, next;
    VkVideoEncodeQualityLevelInfoKHR quality;
    int started, rc_pending, converting;

    uint32_t ref_frame_num;              // frame_num of the last reference picture
    int32_t ref_poc;                     // its picture order count
    uint16_t idr_id;
    int ref_slot;                        // DPB slot holding the reference picture, -1 before the first
    StdVideoEncodeH264ReferenceInfo slot_info[2];

    uint8_t *ps;                         // SPS + PPS, Annex B
    size_t ps_len;
    uint8_t *out;                        // key frames: SPS/PPS + picture
    size_t out_cap;
};

#define VK(call) do { VkResult r_ = (call); if (r_ != VK_SUCCESS) { vlog("%s failed (%d)", #call, r_); goto fail; } } while (0)

static int mem_type(VkEnc *e, uint32_t bits, VkMemoryPropertyFlags want, VkMemoryPropertyFlags avoid) {
    for (uint32_t i = 0; i < e->mem.memoryTypeCount; i++) {
        VkMemoryPropertyFlags f = e->mem.memoryTypes[i].propertyFlags;
        if ((bits & (1u << i)) && (f & want) == want && !(f & avoid)) return (int)i;
    }
    return -1;
}

// Memory with the `need` properties, preferably also `prefer` and not `avoid`.
static int alloc(VkEnc *e, VkMemoryRequirements r, VkMemoryPropertyFlags need, VkMemoryPropertyFlags prefer,
                 VkMemoryPropertyFlags avoid, VkDeviceMemory *out) {
    int t = mem_type(e, r.memoryTypeBits, need | prefer, avoid);
    if (t < 0) t = mem_type(e, r.memoryTypeBits, need, avoid);
    if (t < 0) t = mem_type(e, r.memoryTypeBits, need, 0);
    if (t < 0) { vlog("no memory type 0x%x", need); return -1; }
    VkMemoryAllocateInfo ai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, NULL, r.size, (uint32_t)t};
    VkResult res = vkAllocateMemory(e->dev, &ai, NULL, out);
    if (res != VK_SUCCESS) { vlog("vkAllocateMemory(%llu) failed (%d)", (unsigned long long)r.size, res); return -1; }
    return 0;
}

static void rc_wire(RateControl *r) {
    r->rc.pNext = &r->h264;
    r->rc.pLayers = &r->layer;
    r->layer.pNext = &r->h264_layer;
}

static void rc_set(RateControl *r, uint32_t kbps, uint32_t fps, uint32_t vbv_frames) {
    memset(r, 0, sizeof *r);
    r->h264_layer.sType = VK_STRUCTURE_TYPE_VIDEO_ENCODE_H264_RATE_CONTROL_LAYER_INFO_KHR;
    r->layer.sType = VK_STRUCTURE_TYPE_VIDEO_ENCODE_RATE_CONTROL_LAYER_INFO_KHR;
    r->layer.averageBitrate = r->layer.maxBitrate = (uint64_t)kbps * 1000u;
    r->layer.frameRateNumerator = fps;
    r->layer.frameRateDenominator = 1;
    r->h264.sType = VK_STRUCTURE_TYPE_VIDEO_ENCODE_H264_RATE_CONTROL_INFO_KHR;
    r->h264.flags = VK_VIDEO_ENCODE_H264_RATE_CONTROL_REFERENCE_PATTERN_FLAT_BIT_KHR;
    r->h264.gopFrameCount = 0;          // open-ended: key frames only on request
    r->h264.idrPeriod = 0;
    r->h264.temporalLayerCount = 1;
    r->rc.sType = VK_STRUCTURE_TYPE_VIDEO_ENCODE_RATE_CONTROL_INFO_KHR;
    r->rc.rateControlMode = VK_VIDEO_ENCODE_RATE_CONTROL_MODE_CBR_BIT_KHR;
    r->rc.layerCount = 1;
    // A few frames of VBV: small edits are tiny anyway; a full-screen change may borrow a little
    // so it arrives sharp instead of smeared, without a long burst.
    uint32_t ms = vbv_frames * 1000u / (fps ? fps : 60);
    r->rc.virtualBufferSizeInMs = r->rc.initialVirtualBufferSizeInMs = ms ? ms : 1;
    rc_wire(r);
}

// The smallest level that fits the picture size, the macroblock rate and the highest bitrate the
// stream may reach (H.264 table A-1; High profile allows 1.25 × MaxBR).
static StdVideoH264LevelIdc pick_level(uint32_t mbs, uint32_t fps, uint32_t kbps, StdVideoH264LevelIdc max) {
    static const struct { StdVideoH264LevelIdc level; uint32_t fs, mbps, br; } t[] = {
        {STD_VIDEO_H264_LEVEL_IDC_3_1, 3600, 108000, 14000}, {STD_VIDEO_H264_LEVEL_IDC_3_2, 5120, 216000, 20000},
        {STD_VIDEO_H264_LEVEL_IDC_4_0, 8192, 245760, 20000}, {STD_VIDEO_H264_LEVEL_IDC_4_1, 8192, 245760, 50000},
        {STD_VIDEO_H264_LEVEL_IDC_4_2, 8704, 522240, 50000}, {STD_VIDEO_H264_LEVEL_IDC_5_0, 22080, 589824, 135000},
        {STD_VIDEO_H264_LEVEL_IDC_5_1, 36864, 983040, 240000}, {STD_VIDEO_H264_LEVEL_IDC_5_2, 36864, 2073600, 240000},
        {STD_VIDEO_H264_LEVEL_IDC_6_0, 139264, 4177920, 240000}, {STD_VIDEO_H264_LEVEL_IDC_6_1, 139264, 8355840, 480000},
        {STD_VIDEO_H264_LEVEL_IDC_6_2, 139264, 16711680, 800000},
    };
    for (size_t i = 0; i < sizeof t / sizeof t[0]; i++)
        if (mbs <= t[i].fs && (uint64_t)mbs * fps <= t[i].mbps && (uint64_t)kbps * 4 <= (uint64_t)t[i].br * 5)
            return t[i].level < max ? t[i].level : max;
    return max;
}

static int has_ext(VkEnc *e, const char *name) {
    uint32_t n = 0;
    vkEnumerateDeviceExtensionProperties(e->pd, NULL, &n, NULL);
    VkExtensionProperties *p = calloc(n ? n : 1, sizeof *p);
    if (!p) return 0;
    vkEnumerateDeviceExtensionProperties(e->pd, NULL, &n, p);
    int found = 0;
    for (uint32_t i = 0; i < n && !found; i++) found = !strcmp(p[i].extensionName, name);
    free(p);
    return found;
}

static int make_buffer(VkEnc *e, VkDeviceSize size, VkBufferUsageFlags usage, const void *pnext, VkBuffer *out) {
    uint32_t fams[2] = {e->cfam, e->efam};
    VkBufferCreateInfo bi = {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, pnext, 0, size, usage,
                             e->cfam == e->efam ? VK_SHARING_MODE_EXCLUSIVE : VK_SHARING_MODE_CONCURRENT,
                             e->cfam == e->efam ? 1 : 2, fams};
    VkResult r = vkCreateBuffer(e->dev, &bi, NULL, out);
    if (r != VK_SUCCESS) { vlog("vkCreateBuffer failed (%d)", r); return -1; }
    return 0;
}

static int make_image(VkEnc *e, uint32_t layers, VkImageUsageFlags usage, int shared, VkImage *out) {
    uint32_t fams[2] = {e->cfam, e->efam};
    int concurrent = shared && e->cfam != e->efam;
    VkImageCreateInfo ii = {VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, &e->profiles, 0, VK_IMAGE_TYPE_2D,
                            VK_FORMAT_G8_B8R8_2PLANE_420_UNORM, {e->cw, e->ch, 1}, 1, layers, VK_SAMPLE_COUNT_1_BIT,
                            VK_IMAGE_TILING_OPTIMAL, usage,
                            concurrent ? VK_SHARING_MODE_CONCURRENT : VK_SHARING_MODE_EXCLUSIVE,
                            concurrent ? 2 : 1, concurrent ? fams : &e->efam, VK_IMAGE_LAYOUT_UNDEFINED};
    VkResult r = vkCreateImage(e->dev, &ii, NULL, out);
    if (r != VK_SUCCESS) { vlog("vkCreateImage failed (%d)", r); return -1; }
    return 0;
}

static int make_view(VkEnc *e, VkImage img, uint32_t layer, VkImageView *out) {
    VkImageViewCreateInfo vi = {VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, NULL, 0, img, VK_IMAGE_VIEW_TYPE_2D,
                                VK_FORMAT_G8_B8R8_2PLANE_420_UNORM, {0},
                                {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, layer, 1}};
    VkResult r = vkCreateImageView(e->dev, &vi, NULL, out);
    if (r != VK_SUCCESS) { vlog("vkCreateImageView failed (%d)", r); return -1; }
    return 0;
}

static void use_only_nvidia(void) {
    // Only NVIDIA's driver, and no implicit layers (overlays, capture tools): other ICDs would be
    // loaded for nothing (llvmpipe alone brings in LLVM). The user's own settings win.
    static const char *icds[] = {"/usr/share/vulkan/icd.d/nvidia_icd.json", "/etc/vulkan/icd.d/nvidia_icd.json"};
    for (size_t i = 0; i < sizeof icds / sizeof icds[0]; i++)
        if (access(icds[i], R_OK) == 0) { setenv("VK_DRIVER_FILES", icds[i], 0); break; }
    setenv("VK_LOADER_LAYERS_DISABLE", "~implicit~", 0);
}

VkEnc *vkenc_open(const VkEncParams *p, char gpu_name[128], const uint8_t **ps_out, uint32_t *ps_len) {
    VkEnc *e = calloc(1, sizeof *e);
    if (!e) return NULL;
    e->w = p->w;
    e->h = p->h;
    e->cw = (p->w + 15) & ~15u;
    e->ch = (p->h + 15) & ~15u;
    e->src_pitch_px = p->src_pitch / 4;
    e->matrix601 = p->matrix601 ? 1 : 0;
    e->ref_slot = -1;

    use_only_nvidia();
    e->lib = dlopen("libvulkan.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!e->lib) { vlog("libvulkan.so.1 not found"); goto fail; }
    vkGetInstanceProcAddr = (PFN_vkGetInstanceProcAddr)dlsym(e->lib, "vkGetInstanceProcAddr");
    if (!vkGetInstanceProcAddr) goto fail;
    vkCreateInstance = (PFN_vkCreateInstance)vkGetInstanceProcAddr(NULL, "vkCreateInstance");
    if (!vkCreateInstance) goto fail;
    VkApplicationInfo ai = {VK_STRUCTURE_TYPE_APPLICATION_INFO, NULL, "darpan-capture", 1, "darpan", 1,
                            VK_API_VERSION_1_3};
    VkInstanceCreateInfo ici = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, NULL, 0, &ai};
    VK(vkCreateInstance(&ici, NULL, &e->inst));
#define LOAD_I(n) if (!(n = (PFN_##n)vkGetInstanceProcAddr(e->inst, #n))) { vlog("missing %s", #n); goto fail; }
    VK_INSTANCE_FNS(LOAD_I)

    // the NVIDIA device with that UUID (else the first), with Vulkan 1.3
    VkPhysicalDevice pds[16];
    uint32_t n = 16;
    vkEnumeratePhysicalDevices(e->inst, &n, pds);
    for (uint32_t i = 0; i < n && !e->pd; i++) {
        VkPhysicalDeviceIDProperties id = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ID_PROPERTIES};
        VkPhysicalDeviceProperties2 pp = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, &id};
        vkGetPhysicalDeviceProperties2(pds[i], &pp);
        if (pp.properties.vendorID != 0x10DE || VK_API_VERSION_MINOR(pp.properties.apiVersion) < 3) continue;
        if (!p->uuid || !memcmp(id.deviceUUID, p->uuid, VK_UUID_SIZE)) {
            e->pd = pds[i];
            snprintf(gpu_name, 128, "%.127s", pp.properties.deviceName);
        }
    }
    if (!e->pd) { vlog("no such NVIDIA GPU with Vulkan 1.3"); goto fail; }
    static const char *exts[] = {"VK_KHR_video_queue", "VK_KHR_video_encode_queue", "VK_KHR_video_encode_h264",
                                 "VK_EXT_external_memory_host"};
    for (size_t i = 0; i < sizeof exts / sizeof exts[0]; i++)
        if (!has_ext(e, exts[i])) { vlog("no %s", exts[i]); goto fail; }
    vkGetPhysicalDeviceMemoryProperties(e->pd, &e->mem);

    VkQueueFamilyProperties qf[16];
    uint32_t nq = 16;
    vkGetPhysicalDeviceQueueFamilyProperties(e->pd, &nq, qf);
    int cfam = -1, efam = -1;
    for (uint32_t i = 0; i < nq; i++) {
        if ((qf[i].queueFlags & VK_QUEUE_VIDEO_ENCODE_BIT_KHR) && efam < 0) efam = (int)i;
        // prefer a compute queue that isn't the graphics one: the desktop keeps that to itself
        if ((qf[i].queueFlags & VK_QUEUE_COMPUTE_BIT) &&
            (cfam < 0 || ((qf[cfam].queueFlags & VK_QUEUE_GRAPHICS_BIT) && !(qf[i].queueFlags & VK_QUEUE_GRAPHICS_BIT))))
            cfam = (int)i;
    }
    if (cfam < 0 || efam < 0) { vlog("no compute or video encode queue"); goto fail; }
    e->cfam = (uint32_t)cfam;
    e->efam = (uint32_t)efam;

    // the video profile and what the encoder can do with it
    e->h264_profile = (VkVideoEncodeH264ProfileInfoKHR){VK_STRUCTURE_TYPE_VIDEO_ENCODE_H264_PROFILE_INFO_KHR, NULL,
                                                         STD_VIDEO_H264_PROFILE_IDC_HIGH};
    // LOW_LATENCY: single-pass rate control. ULTRA_LOW_LATENCY is NVENC's two-pass, about 1.6 dB
    // sharper on text (quality_test.py) for 1.6 ms more per 2560×1440 frame, but it never encodes an
    // unchanged picture as all P_Skip, so the probe can't tell a repaint of the same pixels from a change
    // and every one of them would be sent. Higher quality levels add only a tenth of a dB for 1.3 ms.
    e->usage = (VkVideoEncodeUsageInfoKHR){VK_STRUCTURE_TYPE_VIDEO_ENCODE_USAGE_INFO_KHR, &e->h264_profile,
                                           VK_VIDEO_ENCODE_USAGE_STREAMING_BIT_KHR,
                                           VK_VIDEO_ENCODE_CONTENT_DESKTOP_BIT_KHR,
                                           VK_VIDEO_ENCODE_TUNING_MODE_LOW_LATENCY_KHR};
    e->profile = (VkVideoProfileInfoKHR){VK_STRUCTURE_TYPE_VIDEO_PROFILE_INFO_KHR, &e->usage,
                                         VK_VIDEO_CODEC_OPERATION_ENCODE_H264_BIT_KHR,
                                         VK_VIDEO_CHROMA_SUBSAMPLING_420_BIT_KHR,
                                         VK_VIDEO_COMPONENT_BIT_DEPTH_8_BIT_KHR, VK_VIDEO_COMPONENT_BIT_DEPTH_8_BIT_KHR};
    e->profiles = (VkVideoProfileListInfoKHR){VK_STRUCTURE_TYPE_VIDEO_PROFILE_LIST_INFO_KHR, NULL, 1, &e->profile};
    VkVideoEncodeH264CapabilitiesKHR hcap = {VK_STRUCTURE_TYPE_VIDEO_ENCODE_H264_CAPABILITIES_KHR};
    VkVideoEncodeCapabilitiesKHR ecap = {VK_STRUCTURE_TYPE_VIDEO_ENCODE_CAPABILITIES_KHR, &hcap};
    VkVideoCapabilitiesKHR cap = {VK_STRUCTURE_TYPE_VIDEO_CAPABILITIES_KHR, &ecap};
    VK(vkGetPhysicalDeviceVideoCapabilitiesKHR(e->pd, &e->profile, &cap));
    if (e->cw > cap.maxCodedExtent.width || e->ch > cap.maxCodedExtent.height || cap.maxDpbSlots < 2 ||
        cap.maxActiveReferencePictures < 1 || !(ecap.rateControlModes & VK_VIDEO_ENCODE_RATE_CONTROL_MODE_CBR_BIT_KHR) ||
        (ecap.supportedEncodeFeedbackFlags & 3) != 3) {
        vlog("encoder can't do %ux%u CBR with one reference", e->cw, e->ch);
        goto fail;
    }

    // device: one compute queue for the conversion, one encode queue
    float prio = 1;
    VkDeviceQueueCreateInfo qci[2] = {
        {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, NULL, 0, e->cfam, 1, &prio},
        {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, NULL, 0, e->efam, 1, &prio},
    };
    VkPhysicalDeviceVulkan13Features f13 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES};
    f13.synchronization2 = VK_TRUE;
    VkDeviceCreateInfo dci = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, &f13, 0, e->cfam == e->efam ? 1 : 2, qci, 0, NULL,
                              sizeof exts / sizeof exts[0], exts, NULL};
    VK(vkCreateDevice(e->pd, &dci, NULL, &e->dev));
#define LOAD_D(n) if (!(n = (PFN_##n)vkGetDeviceProcAddr(e->dev, #n))) { vlog("missing %s", #n); goto fail; }
    VK_DEVICE_FNS(LOAD_D)
    vkGetDeviceQueue(e->dev, e->cfam, 0, &e->cq);
    vkGetDeviceQueue(e->dev, e->efam, 0, &e->eq);

    // the frame buffer, read by the GPU where it is
    VkMemoryHostPointerPropertiesEXT hp = {VK_STRUCTURE_TYPE_MEMORY_HOST_POINTER_PROPERTIES_EXT};
    VK(vkGetMemoryHostPointerPropertiesEXT(e->dev, VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT, p->src, &hp));
    VkExternalMemoryBufferCreateInfo ext_buf = {VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO, NULL,
                                                VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT};
    if (make_buffer(e, p->src_size, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, &ext_buf, &e->src)) goto fail;
    VkMemoryRequirements mr;
    vkGetBufferMemoryRequirements(e->dev, e->src, &mr);
    int t = mem_type(e, mr.memoryTypeBits & hp.memoryTypeBits, 0, 0);
    if (t < 0 || mr.size > p->src_size) { vlog("the frame buffer can't be imported"); goto fail; }
    VkImportMemoryHostPointerInfoEXT imp = {VK_STRUCTURE_TYPE_IMPORT_MEMORY_HOST_POINTER_INFO_EXT, NULL,
                                            VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT, p->src};
    VkMemoryAllocateInfo mai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, &imp, p->src_size, (uint32_t)t};
    VK(vkAllocateMemory(e->dev, &mai, NULL, &e->src_mem));
    VK(vkBindBufferMemory(e->dev, e->src, e->src_mem, 0));

    // NV12 staging (written by the shader), the picture to encode, the reference pictures
    VkDeviceSize nv12_size = (VkDeviceSize)e->cw * e->ch * 3 / 2;
    if (make_buffer(e, nv12_size, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_SRC_BIT, NULL, &e->nv12))
        goto fail;
    vkGetBufferMemoryRequirements(e->dev, e->nv12, &mr);
    if (alloc(e, mr, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, 0, 0, &e->nv12_mem)) goto fail;
    VK(vkBindBufferMemory(e->dev, e->nv12, e->nv12_mem, 0));
    if (make_image(e, 1, VK_IMAGE_USAGE_VIDEO_ENCODE_SRC_BIT_KHR | VK_IMAGE_USAGE_TRANSFER_DST_BIT, 1, &e->pic)) goto fail;
    vkGetImageMemoryRequirements(e->dev, e->pic, &mr);
    if (alloc(e, mr, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, 0, 0, &e->pic_mem)) goto fail;
    VK(vkBindImageMemory(e->dev, e->pic, e->pic_mem, 0));
    if (make_view(e, e->pic, 0, &e->pic_view)) goto fail;
    if (make_image(e, 2, VK_IMAGE_USAGE_VIDEO_ENCODE_DPB_BIT_KHR, 0, &e->dpb)) goto fail;
    vkGetImageMemoryRequirements(e->dev, e->dpb, &mr);
    if (alloc(e, mr, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, 0, 0, &e->dpb_mem)) goto fail;
    VK(vkBindImageMemory(e->dev, e->dpb, e->dpb_mem, 0));
    for (uint32_t i = 0; i < 2; i++) if (make_view(e, e->dpb, i, &e->dpb_view[i])) goto fail;

    // the bitstream lands in cached system memory, where the CPU reads it
    e->bs_size = ((VkDeviceSize)e->cw * e->ch > (4u << 20) ? (VkDeviceSize)e->cw * e->ch : (4u << 20));
    e->bs_size = (e->bs_size + cap.minBitstreamBufferSizeAlignment - 1) & ~(cap.minBitstreamBufferSizeAlignment - 1);
    if (make_buffer(e, e->bs_size, VK_BUFFER_USAGE_VIDEO_ENCODE_DST_BIT_KHR, &e->profiles, &e->bs)) goto fail;
    vkGetBufferMemoryRequirements(e->dev, e->bs, &mr);
    if (alloc(e, mr, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
              VK_MEMORY_PROPERTY_HOST_CACHED_BIT, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, &e->bs_mem))
        goto fail;
    VK(vkBindBufferMemory(e->dev, e->bs, e->bs_mem, 0));
    VK(vkMapMemory(e->dev, e->bs_mem, 0, VK_WHOLE_SIZE, 0, (void **)&e->bs_ptr));

    // the video session
    VkExtensionProperties std_hdr = {VK_STD_VULKAN_VIDEO_CODEC_H264_ENCODE_EXTENSION_NAME,
                                     VK_STD_VULKAN_VIDEO_CODEC_H264_ENCODE_SPEC_VERSION};
    VkVideoSessionCreateInfoKHR sci = {VK_STRUCTURE_TYPE_VIDEO_SESSION_CREATE_INFO_KHR, NULL, e->efam, 0, &e->profile,
                                       VK_FORMAT_G8_B8R8_2PLANE_420_UNORM, {e->cw, e->ch},
                                       VK_FORMAT_G8_B8R8_2PLANE_420_UNORM, 2, 1, &std_hdr};
    VK(vkCreateVideoSessionKHR(e->dev, &sci, NULL, &e->session));
    VkVideoSessionMemoryRequirementsKHR smr[16];
    uint32_t nm = 0;
    vkGetVideoSessionMemoryRequirementsKHR(e->dev, e->session, &nm, NULL);
    if (nm > 16) goto fail;
    for (uint32_t i = 0; i < nm; i++) smr[i] = (VkVideoSessionMemoryRequirementsKHR){VK_STRUCTURE_TYPE_VIDEO_SESSION_MEMORY_REQUIREMENTS_KHR};
    vkGetVideoSessionMemoryRequirementsKHR(e->dev, e->session, &nm, smr);
    VkBindVideoSessionMemoryInfoKHR bind[16];
    for (uint32_t i = 0; i < nm; i++) {
        if (alloc(e, smr[i].memoryRequirements, 0, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, 0, &e->session_mem[i]))
            goto fail;
        e->session_mem_n = i + 1;
        bind[i] = (VkBindVideoSessionMemoryInfoKHR){VK_STRUCTURE_TYPE_BIND_VIDEO_SESSION_MEMORY_INFO_KHR, NULL,
                                                    smr[i].memoryBindIndex, e->session_mem[i], 0,
                                                    smr[i].memoryRequirements.size};
    }
    VK(vkBindVideoSessionMemoryKHR(e->dev, e->session, nm, bind));

    // SPS and PPS
    uint32_t level_max = hcap.maxLevelIdc;
    StdVideoH264SequenceParameterSetVui vui = {0};
    vui.flags.video_signal_type_present_flag = 1;
    vui.flags.color_description_present_flag = 1;
    vui.flags.bitstream_restriction_flag = 1;          // lets decoders output each frame at once
    vui.aspect_ratio_idc = STD_VIDEO_H264_ASPECT_RATIO_IDC_UNSPECIFIED;
    vui.video_format = 5;                              // unspecified
    vui.colour_primaries = 1;                          // BT.709
    vui.transfer_characteristics = 13;                 // sRGB
    vui.matrix_coefficients = e->matrix601 ? 6 : 1;
    vui.max_num_reorder_frames = 0;
    vui.max_dec_frame_buffering = 1;
    StdVideoH264SequenceParameterSet sps = {0};
    sps.flags.direct_8x8_inference_flag = 1;
    sps.flags.frame_mbs_only_flag = 1;
    sps.flags.vui_parameters_present_flag = 1;
    sps.flags.frame_cropping_flag = e->cw != e->w || e->ch != e->h;
    sps.profile_idc = STD_VIDEO_H264_PROFILE_IDC_HIGH;
    sps.level_idc = pick_level((e->cw / 16) * (e->ch / 16), p->fps, p->max_kbps, (StdVideoH264LevelIdc)level_max);
    sps.chroma_format_idc = STD_VIDEO_H264_CHROMA_FORMAT_IDC_420;
    sps.log2_max_frame_num_minus4 = 4;                 // frame_num 0..255
    sps.pic_order_cnt_type = STD_VIDEO_H264_POC_TYPE_0;
    sps.log2_max_pic_order_cnt_lsb_minus4 = 4;
    sps.max_num_ref_frames = 1;
    sps.pic_width_in_mbs_minus1 = e->cw / 16 - 1;
    sps.pic_height_in_map_units_minus1 = e->ch / 16 - 1;
    sps.frame_crop_right_offset = (e->cw - e->w) / 2;  // in chroma samples (4:2:0)
    sps.frame_crop_bottom_offset = (e->ch - e->h) / 2;
    sps.pSequenceParameterSetVui = &vui;
    StdVideoH264PictureParameterSet pps = {0};
    pps.flags.transform_8x8_mode_flag = 1;
    pps.flags.deblocking_filter_control_present_flag = 1;
    pps.flags.entropy_coding_mode_flag = 1;            // CABAC: the probe check reads it
    pps.weighted_bipred_idc = STD_VIDEO_H264_WEIGHTED_BIPRED_IDC_DEFAULT;
    VkVideoEncodeH264SessionParametersAddInfoKHR add = {VK_STRUCTURE_TYPE_VIDEO_ENCODE_H264_SESSION_PARAMETERS_ADD_INFO_KHR,
                                                        NULL, 1, &sps, 1, &pps};
    VkVideoEncodeH264SessionParametersCreateInfoKHR hpci = {
        VK_STRUCTURE_TYPE_VIDEO_ENCODE_H264_SESSION_PARAMETERS_CREATE_INFO_KHR, NULL, 1, 1, &add};
    int level = p->preset - 1;
    if (level < 0) level = 0;
    if (level >= (int)ecap.maxQualityLevels) level = (int)ecap.maxQualityLevels - 1;
    e->quality = (VkVideoEncodeQualityLevelInfoKHR){VK_STRUCTURE_TYPE_VIDEO_ENCODE_QUALITY_LEVEL_INFO_KHR, &hpci,
                                                    (uint32_t)level};
    VkVideoSessionParametersCreateInfoKHR spci = {VK_STRUCTURE_TYPE_VIDEO_SESSION_PARAMETERS_CREATE_INFO_KHR,
                                                  &e->quality, 0, VK_NULL_HANDLE, e->session};
    VK(vkCreateVideoSessionParametersKHR(e->dev, &spci, NULL, &e->params));
    e->quality.pNext = NULL;
    VkVideoEncodeH264SessionParametersGetInfoKHR hgi = {VK_STRUCTURE_TYPE_VIDEO_ENCODE_H264_SESSION_PARAMETERS_GET_INFO_KHR,
                                                        NULL, VK_TRUE, VK_TRUE, 0, 0};
    VkVideoEncodeSessionParametersGetInfoKHR gi = {VK_STRUCTURE_TYPE_VIDEO_ENCODE_SESSION_PARAMETERS_GET_INFO_KHR, &hgi,
                                                   e->params};
    VK(vkGetEncodedVideoSessionParametersKHR(e->dev, &gi, NULL, &e->ps_len, NULL));
    if (!(e->ps = malloc(e->ps_len))) goto fail;
    VK(vkGetEncodedVideoSessionParametersKHR(e->dev, &gi, NULL, &e->ps_len, e->ps));

    // encode feedback: where the picture is in the bitstream buffer, and how long
    VkQueryPoolVideoEncodeFeedbackCreateInfoKHR fb = {VK_STRUCTURE_TYPE_QUERY_POOL_VIDEO_ENCODE_FEEDBACK_CREATE_INFO_KHR,
                                                      &e->profile,
                                                      VK_VIDEO_ENCODE_FEEDBACK_BITSTREAM_BUFFER_OFFSET_BIT_KHR |
                                                          VK_VIDEO_ENCODE_FEEDBACK_BITSTREAM_BYTES_WRITTEN_BIT_KHR};
    VkQueryPoolCreateInfo qpci = {VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO, &fb, 0, VK_QUERY_TYPE_VIDEO_ENCODE_FEEDBACK_KHR, 1};
    VK(vkCreateQueryPool(e->dev, &qpci, NULL, &e->query));

    // the conversion pipeline
    VkShaderModuleCreateInfo smci = {VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, NULL, 0, sizeof rgb2nv12_spv, rgb2nv12_spv};
    VK(vkCreateShaderModule(e->dev, &smci, NULL, &e->shader));
    VkDescriptorSetLayoutBinding b[2] = {
        {0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL},
        {1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL},
    };
    VkDescriptorSetLayoutCreateInfo dslci = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, NULL, 0, 2, b};
    VK(vkCreateDescriptorSetLayout(e->dev, &dslci, NULL, &e->dsl));
    VkPushConstantRange pcr = {VK_SHADER_STAGE_COMPUTE_BIT, 0, 6 * sizeof(uint32_t)};
    VkPipelineLayoutCreateInfo plci = {VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, NULL, 0, 1, &e->dsl, 1, &pcr};
    VK(vkCreatePipelineLayout(e->dev, &plci, NULL, &e->layout));
    VkComputePipelineCreateInfo cpci = {VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO, NULL, 0,
                                        {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0,
                                         VK_SHADER_STAGE_COMPUTE_BIT, e->shader, "main", NULL},
                                        e->layout, VK_NULL_HANDLE, -1};
    VK(vkCreateComputePipelines(e->dev, VK_NULL_HANDLE, 1, &cpci, NULL, &e->pipe));
    VkDescriptorPoolSize dps = {VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 2};
    VkDescriptorPoolCreateInfo dpci = {VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, NULL, 0, 1, 1, &dps};
    VK(vkCreateDescriptorPool(e->dev, &dpci, NULL, &e->dpool));
    VkDescriptorSetAllocateInfo dsai = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, NULL, e->dpool, 1, &e->dsl};
    VK(vkAllocateDescriptorSets(e->dev, &dsai, &e->ds));
    VkDescriptorBufferInfo dbi[2] = {{e->src, 0, VK_WHOLE_SIZE}, {e->nv12, 0, VK_WHOLE_SIZE}};
    VkWriteDescriptorSet w[2] = {
        {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, e->ds, 0, 0, 1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, NULL, &dbi[0], NULL},
        {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, e->ds, 1, 0, 1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, NULL, &dbi[1], NULL},
    };
    vkUpdateDescriptorSets(e->dev, 2, w, 0, NULL);

    // command buffers and synchronisation
    VkCommandPoolCreateInfo cpi = {VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, NULL,
                                   VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, e->cfam};
    VK(vkCreateCommandPool(e->dev, &cpi, NULL, &e->cpool));
    cpi.queueFamilyIndex = e->efam;
    VK(vkCreateCommandPool(e->dev, &cpi, NULL, &e->epool));
    VkCommandBufferAllocateInfo cbai = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, NULL, e->cpool,
                                        VK_COMMAND_BUFFER_LEVEL_PRIMARY, 1};
    VK(vkAllocateCommandBuffers(e->dev, &cbai, &e->ccb));
    cbai.commandPool = e->epool;
    VK(vkAllocateCommandBuffers(e->dev, &cbai, &e->ecb));
    VkSemaphoreCreateInfo sei = {VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
    VK(vkCreateSemaphore(e->dev, &sei, NULL, &e->converted));
    VkFenceCreateInfo fci = {VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    VK(vkCreateFence(e->dev, &fci, NULL, &e->done));

    rc_set(&e->cur, p->kbps, p->fps, p->vbv_frames);
    e->next = e->cur;
    rc_wire(&e->next);
    *ps_out = e->ps;
    *ps_len = (uint32_t)e->ps_len;
    return e;
fail:
    vkenc_close(e);
    return NULL;
}

static const VkCommandBufferBeginInfo once = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, NULL,
                                              VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};

int vkenc_convert(VkEnc *e) {
    if (e->converting) { vlog("converted twice without an encode"); return -1; }
    VK(vkBeginCommandBuffer(e->ccb, &once));
    VkImageMemoryBarrier2 to_copy = {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2, NULL, VK_PIPELINE_STAGE_2_NONE, 0,
                                     VK_PIPELINE_STAGE_2_COPY_BIT, VK_ACCESS_2_TRANSFER_WRITE_BIT,
                                     VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                                     VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, e->pic,
                                     {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
    VkDependencyInfo dep = {VK_STRUCTURE_TYPE_DEPENDENCY_INFO, NULL, 0, 0, NULL, 0, NULL, 1, &to_copy};
    vkCmdPipelineBarrier2(e->ccb, &dep);
    vkCmdBindPipeline(e->ccb, VK_PIPELINE_BIND_POINT_COMPUTE, e->pipe);
    vkCmdBindDescriptorSets(e->ccb, VK_PIPELINE_BIND_POINT_COMPUTE, e->layout, 0, 1, &e->ds, 0, NULL);
    uint32_t pc[6] = {e->w, e->h, e->src_pitch_px, e->cw, e->ch, e->matrix601};
    vkCmdPushConstants(e->ccb, e->layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof pc, pc);
    vkCmdDispatch(e->ccb, (e->cw / 4 + 15) / 16, (e->ch / 2 + 7) / 8, 1);
    VkBufferMemoryBarrier2 written = {VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER_2, NULL,
                                      VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT, VK_ACCESS_2_SHADER_STORAGE_WRITE_BIT,
                                      VK_PIPELINE_STAGE_2_COPY_BIT, VK_ACCESS_2_TRANSFER_READ_BIT,
                                      VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, e->nv12, 0, VK_WHOLE_SIZE};
    dep = (VkDependencyInfo){VK_STRUCTURE_TYPE_DEPENDENCY_INFO, NULL, 0, 0, NULL, 1, &written, 0, NULL};
    vkCmdPipelineBarrier2(e->ccb, &dep);
    VkBufferImageCopy planes[2] = {
        {0, 0, 0, {VK_IMAGE_ASPECT_PLANE_0_BIT, 0, 0, 1}, {0, 0, 0}, {e->cw, e->ch, 1}},
        {(VkDeviceSize)e->cw * e->ch, 0, 0, {VK_IMAGE_ASPECT_PLANE_1_BIT, 0, 0, 1}, {0, 0, 0}, {e->cw / 2, e->ch / 2, 1}},
    };
    vkCmdCopyBufferToImage(e->ccb, e->nv12, e->pic, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 2, planes);
    // Hand the picture to the encode queue: the semaphore it waits on carries the dependency.
    VkImageMemoryBarrier2 to_encode = {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2, NULL, VK_PIPELINE_STAGE_2_COPY_BIT,
                                       VK_ACCESS_2_TRANSFER_WRITE_BIT, VK_PIPELINE_STAGE_2_NONE, 0,
                                       VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_VIDEO_ENCODE_SRC_KHR,
                                       VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, e->pic,
                                       {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
    dep = (VkDependencyInfo){VK_STRUCTURE_TYPE_DEPENDENCY_INFO, NULL, 0, 0, NULL, 0, NULL, 1, &to_encode};
    vkCmdPipelineBarrier2(e->ccb, &dep);
    VK(vkEndCommandBuffer(e->ccb));
    VkCommandBufferSubmitInfo cbs = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO, NULL, e->ccb, 0};
    VkSemaphoreSubmitInfo sig = {VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO, NULL, e->converted, 0,
                                 VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, 0};
    VkSubmitInfo2 si = {VK_STRUCTURE_TYPE_SUBMIT_INFO_2, NULL, 0, 0, NULL, 1, &cbs, 1, &sig};
    VK(vkQueueSubmit2(e->cq, 1, &si, VK_NULL_HANDLE));
    e->converting = 1;
    return 0;
fail:
    return -1;
}

int vkenc_encode(VkEnc *e, int idr, int reference, const uint8_t **out, uint32_t *len) {
    if (getenv("DARPAN_TEST_VULKAN_FAIL")) { vlog("failing as the test asks"); return -1; }
    if (idr || e->ref_slot < 0) { idr = 1; reference = 1; }
    uint32_t frame_num = idr ? 0 : (e->ref_frame_num + 1) & 255;
    // Reference pictures count up by 2, so the viewer's stream has no gaps however many
    // non-reference pictures were dropped; those sit in between.
    int32_t poc = idr ? 0 : reference ? e->ref_poc + 2 : e->ref_poc + 1;
    int setup = reference ? (e->ref_slot + 1) & 1 : -1;
    StdVideoH264PictureType type = idr ? STD_VIDEO_H264_PICTURE_TYPE_IDR : STD_VIDEO_H264_PICTURE_TYPE_P;

    VkVideoPictureResourceInfoKHR dpb[2];
    for (int i = 0; i < 2; i++)
        dpb[i] = (VkVideoPictureResourceInfoKHR){VK_STRUCTURE_TYPE_VIDEO_PICTURE_RESOURCE_INFO_KHR, NULL, {0, 0},
                                                 {e->cw, e->ch}, 0, e->dpb_view[i]};
    StdVideoEncodeH264ReferenceInfo setup_info = {{0}, type, frame_num, poc, 0, 0, 0};
    VkVideoEncodeH264DpbSlotInfoKHR setup_dpb = {VK_STRUCTURE_TYPE_VIDEO_ENCODE_H264_DPB_SLOT_INFO_KHR, NULL, &setup_info};
    VkVideoEncodeH264DpbSlotInfoKHR ref_dpb = {VK_STRUCTURE_TYPE_VIDEO_ENCODE_H264_DPB_SLOT_INFO_KHR, NULL,
                                               e->ref_slot >= 0 ? &e->slot_info[e->ref_slot] : NULL};
    VkVideoReferenceSlotInfoKHR setup_slot = {VK_STRUCTURE_TYPE_VIDEO_REFERENCE_SLOT_INFO_KHR, &setup_dpb, setup,
                                              setup >= 0 ? &dpb[setup] : NULL};
    VkVideoReferenceSlotInfoKHR ref_slot = {VK_STRUCTURE_TYPE_VIDEO_REFERENCE_SLOT_INFO_KHR, &ref_dpb, e->ref_slot,
                                            e->ref_slot >= 0 ? &dpb[e->ref_slot] : NULL};
    VkVideoReferenceSlotInfoKHR bound[2];
    uint32_t nbound = 0;
    if (!idr) bound[nbound++] = ref_slot;
    if (reference) { bound[nbound] = setup_slot; bound[nbound++].slotIndex = -1; }   // to be (re)activated

    VK(vkBeginCommandBuffer(e->ecb, &once));
    vkCmdResetQueryPool(e->ecb, e->query, 0, 1);
    if (!e->started) {
        VkImageMemoryBarrier2 init = {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2, NULL, VK_PIPELINE_STAGE_2_NONE, 0,
                                      VK_PIPELINE_STAGE_2_VIDEO_ENCODE_BIT_KHR,
                                      VK_ACCESS_2_VIDEO_ENCODE_READ_BIT_KHR | VK_ACCESS_2_VIDEO_ENCODE_WRITE_BIT_KHR,
                                      VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_VIDEO_ENCODE_DPB_KHR,
                                      VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, e->dpb,
                                      {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 2}};
        VkDependencyInfo dep = {VK_STRUCTURE_TYPE_DEPENDENCY_INFO, NULL, 0, 0, NULL, 0, NULL, 1, &init};
        vkCmdPipelineBarrier2(e->ecb, &dep);
    }
    VkVideoBeginCodingInfoKHR begin = {VK_STRUCTURE_TYPE_VIDEO_BEGIN_CODING_INFO_KHR, e->started ? &e->cur.rc : NULL, 0,
                                       e->session, e->params, nbound, bound};
    vkCmdBeginVideoCodingKHR(e->ecb, &begin);
    if (!e->started || e->rc_pending) {
        e->quality.pNext = &e->next.rc;
        VkVideoCodingControlInfoKHR ctl = {VK_STRUCTURE_TYPE_VIDEO_CODING_CONTROL_INFO_KHR,
                                           e->started ? (const void *)&e->next.rc : (const void *)&e->quality,
                                           VK_VIDEO_CODING_CONTROL_ENCODE_RATE_CONTROL_BIT_KHR};
        if (!e->started)
            ctl.flags |= VK_VIDEO_CODING_CONTROL_RESET_BIT_KHR | VK_VIDEO_CODING_CONTROL_ENCODE_QUALITY_LEVEL_BIT_KHR;
        vkCmdControlVideoCodingKHR(e->ecb, &ctl);
    }

    StdVideoEncodeH264SliceHeader sh = {0};
    sh.slice_type = idr ? STD_VIDEO_H264_SLICE_TYPE_I : STD_VIDEO_H264_SLICE_TYPE_P;
    sh.cabac_init_idc = STD_VIDEO_H264_CABAC_INIT_IDC_0;
    sh.disable_deblocking_filter_idc = STD_VIDEO_H264_DISABLE_DEBLOCKING_FILTER_IDC_DISABLED;   // 0: the loop filter runs
    StdVideoEncodeH264ReferenceListsInfo lists = {0};
    memset(lists.RefPicList0, STD_VIDEO_H264_NO_REFERENCE_PICTURE, sizeof lists.RefPicList0);
    memset(lists.RefPicList1, STD_VIDEO_H264_NO_REFERENCE_PICTURE, sizeof lists.RefPicList1);
    if (!idr) lists.RefPicList0[0] = (uint8_t)e->ref_slot;
    StdVideoEncodeH264PictureInfo pic = {0};
    pic.flags.IdrPicFlag = idr;
    pic.flags.is_reference = reference;
    pic.idr_pic_id = e->idr_id;
    pic.primary_pic_type = type;
    pic.frame_num = frame_num;
    pic.PicOrderCnt = poc;
    pic.pRefLists = &lists;
    VkVideoEncodeH264NaluSliceInfoKHR slice = {VK_STRUCTURE_TYPE_VIDEO_ENCODE_H264_NALU_SLICE_INFO_KHR, NULL, 0, &sh};
    VkVideoEncodeH264PictureInfoKHR hpi = {VK_STRUCTURE_TYPE_VIDEO_ENCODE_H264_PICTURE_INFO_KHR, NULL, 1, &slice, &pic,
                                           VK_FALSE};
    VkVideoEncodeInfoKHR ei = {VK_STRUCTURE_TYPE_VIDEO_ENCODE_INFO_KHR, &hpi, 0, e->bs, 0, e->bs_size,
                               {VK_STRUCTURE_TYPE_VIDEO_PICTURE_RESOURCE_INFO_KHR, NULL, {0, 0}, {e->cw, e->ch}, 0, e->pic_view},
                               reference ? &setup_slot : NULL, idr ? 0 : 1, idr ? NULL : &ref_slot, 0};
    vkCmdBeginQuery(e->ecb, e->query, 0, 0);
    vkCmdEncodeVideoKHR(e->ecb, &ei);
    vkCmdEndQuery(e->ecb, e->query, 0);
    VkVideoEndCodingInfoKHR end = {VK_STRUCTURE_TYPE_VIDEO_END_CODING_INFO_KHR};
    vkCmdEndVideoCodingKHR(e->ecb, &end);
    VK(vkEndCommandBuffer(e->ecb));

    VkCommandBufferSubmitInfo cbs = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO, NULL, e->ecb, 0};
    VkSemaphoreSubmitInfo wait = {VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO, NULL, e->converted, 0,
                                  VK_PIPELINE_STAGE_2_VIDEO_ENCODE_BIT_KHR, 0};
    VkSubmitInfo2 si = {VK_STRUCTURE_TYPE_SUBMIT_INFO_2, NULL, 0, e->converting ? 1 : 0, &wait, 1, &cbs, 0, NULL};
    VK(vkQueueSubmit2(e->eq, 1, &si, e->done));
    e->converting = 0;
    VK(vkWaitForFences(e->dev, 1, &e->done, VK_TRUE, 1000000000ull));   // a frame takes milliseconds
    VK(vkResetFences(e->dev, 1, &e->done));
    struct { uint32_t offset, bytes; int32_t status; } fbk = {0};
    VK(vkGetQueryPoolResults(e->dev, e->query, 0, 1, sizeof fbk, &fbk, sizeof fbk,
                             VK_QUERY_RESULT_WAIT_BIT | VK_QUERY_RESULT_WITH_STATUS_BIT_KHR));
    if (fbk.status != VK_QUERY_RESULT_STATUS_COMPLETE_KHR || (VkDeviceSize)fbk.offset + fbk.bytes > e->bs_size) {
        vlog("encode failed (status %d)", fbk.status);
        return -1;
    }

    if (!e->started || e->rc_pending) {
        e->cur = e->next;
        rc_wire(&e->cur);
        e->started = 1;
        e->rc_pending = 0;
    }
    if (reference) {
        e->ref_slot = setup;
        e->slot_info[setup] = setup_info;
        e->ref_frame_num = frame_num;
        e->ref_poc = poc;
    }
    const uint8_t *bits = e->bs_ptr + fbk.offset;
    if (idr) {                                  // SPS and PPS first, like NVENC's repeatSPSPPS
        e->idr_id++;
        size_t need = e->ps_len + fbk.bytes;
        if (need > e->out_cap) {
            uint8_t *o = realloc(e->out, need);
            if (!o) return -1;
            e->out = o;
            e->out_cap = need;
        }
        memcpy(e->out, e->ps, e->ps_len);
        memcpy(e->out + e->ps_len, bits, fbk.bytes);
        *out = e->out;
        *len = (uint32_t)need;
    } else {
        *out = bits;
        *len = fbk.bytes;
    }
    return 0;
fail:
    return -1;
}

int vkenc_set_bitrate(VkEnc *e, uint32_t kbps) {
    e->next.layer.averageBitrate = e->next.layer.maxBitrate = (uint64_t)kbps * 1000u;
    e->rc_pending = 1;
    return 0;
}

void vkenc_close(VkEnc *e) {
    if (!e) return;
    if (e->dev) {
        vkDeviceWaitIdle(e->dev);
        // Everything below belongs to the device; destroying it frees their memory as well, but
        // the order keeps validation layers quiet when someone runs with them.
        if (e->done) vkDestroyFence(e->dev, e->done, NULL);
        if (e->converted) vkDestroySemaphore(e->dev, e->converted, NULL);
        if (e->cpool) vkDestroyCommandPool(e->dev, e->cpool, NULL);
        if (e->epool) vkDestroyCommandPool(e->dev, e->epool, NULL);
        if (e->dpool) vkDestroyDescriptorPool(e->dev, e->dpool, NULL);
        if (e->pipe) vkDestroyPipeline(e->dev, e->pipe, NULL);
        if (e->layout) vkDestroyPipelineLayout(e->dev, e->layout, NULL);
        if (e->dsl) vkDestroyDescriptorSetLayout(e->dev, e->dsl, NULL);
        if (e->shader) vkDestroyShaderModule(e->dev, e->shader, NULL);
        if (e->query) vkDestroyQueryPool(e->dev, e->query, NULL);
        if (e->params) vkDestroyVideoSessionParametersKHR(e->dev, e->params, NULL);
        if (e->session) vkDestroyVideoSessionKHR(e->dev, e->session, NULL);
        for (uint32_t i = 0; i < e->session_mem_n; i++) vkFreeMemory(e->dev, e->session_mem[i], NULL);
        for (int i = 0; i < 2; i++) if (e->dpb_view[i]) vkDestroyImageView(e->dev, e->dpb_view[i], NULL);
        if (e->pic_view) vkDestroyImageView(e->dev, e->pic_view, NULL);
        if (e->dpb) vkDestroyImage(e->dev, e->dpb, NULL);
        if (e->pic) vkDestroyImage(e->dev, e->pic, NULL);
        if (e->bs) vkDestroyBuffer(e->dev, e->bs, NULL);
        if (e->nv12) vkDestroyBuffer(e->dev, e->nv12, NULL);
        if (e->src) vkDestroyBuffer(e->dev, e->src, NULL);
        VkDeviceMemory mems[] = {e->dpb_mem, e->pic_mem, e->bs_mem, e->nv12_mem, e->src_mem};
        for (size_t i = 0; i < sizeof mems / sizeof mems[0]; i++) if (mems[i]) vkFreeMemory(e->dev, mems[i], NULL);
        vkDestroyDevice(e->dev, NULL);
    }
    if (e->inst && vkDestroyInstance) vkDestroyInstance(e->inst, NULL);
    // libvulkan stays loaded: unloading drivers at exit has a history of crashes
    free(e->ps);
    free(e->out);
    free(e);
}
