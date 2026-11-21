#include "NDIBridge.h"
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

// Layouts as in the NDI SDK (Processing.NDI.*.h, version 5 and 6).
typedef struct { const char *p_ndi_name; const char *p_url_address; } source_t;
typedef struct { bool show_local_sources; const char *p_groups; const char *p_extra_ips; } find_create_t;
typedef struct { source_t source_to_connect_to; int color_format; int bandwidth; bool allow_video_fields; const char *p_ndi_recv_name; } recv_create_v3_t;
typedef struct {
    int xres, yres; uint32_t FourCC; int frame_rate_N, frame_rate_D; float picture_aspect_ratio;
    int frame_format_type; int64_t timecode; uint8_t *p_data; int line_stride_in_bytes; const char *p_metadata; int64_t timestamp;
} video_frame_v2_t;
typedef struct { const char *p_ndi_name; const char *p_groups; bool clock_video; bool clock_audio; } send_create_t;

static void *lib;
static bool (*f_initialize)(void);
static void *(*f_find_create_v2)(const find_create_t *);
static bool (*f_find_wait)(void *, uint32_t);
static const source_t *(*f_find_sources)(void *, uint32_t *);
static void *(*f_recv_create_v3)(const recv_create_v3_t *);
static int (*f_recv_capture_v2)(void *, video_frame_v2_t *, void *, void *, uint32_t);
static void (*f_recv_free_video_v2)(void *, const video_frame_v2_t *);
static void (*f_recv_destroy)(void *);
static void *(*f_send_create)(const send_create_t *);
static void (*f_send_video_v2)(void *, const video_frame_v2_t *);
static void (*f_send_destroy)(void *);
static void *finder;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static char loaded[1024];

#define FOURCC(a,b,c,d) ((uint32_t)(a) | ((uint32_t)(b) << 8) | ((uint32_t)(c) << 16) | ((uint32_t)(d) << 24))

const char *ndi_load(void) {
    pthread_mutex_lock(&lock);
    if (lib) { pthread_mutex_unlock(&lock); return loaded; }
    const char *env = getenv("NDI_RUNTIME_DIR_V6") ? getenv("NDI_RUNTIME_DIR_V6") : getenv("NDI_RUNTIME_DIR_V5");
    char envPath[1024] = {0};
    if (env) { strncpy(envPath, env, 900); strcat(envPath, "/libndi.dylib"); }
    const char *paths[] = {
        envPath[0] ? envPath : NULL,
        "/usr/local/lib/libndi.dylib",
        "/Library/NDI SDK for Apple/lib/macOS/libndi.dylib",
        "/Library/Application Support/NewTek/NDI/libndi.dylib",
        "/Applications/NDI Tools/NDI Virtual Input.app/Contents/Frameworks/libndi.dylib",
        "/Library/NDI/libndi.dylib",
        // NDI Tools 6 ships no shared runtime on the Mac, only copies inside its own apps.
        "/Applications/NDI Scan Converter.app/Contents/Frameworks/libndi.dylib",
        "/Library/CoreMediaIO/Plug-Ins/DAL/NDIVideoOut.plugin/Contents/Frameworks/libndi.dylib",
        "/Applications/NDI Router.app/Contents/Frameworks/NTFramework.framework/Versions/A/Frameworks/libndi.dylib",
        "/Applications/NDI Video Monitor.app/Contents/Frameworks/libndi_advanced.dylib",
        // Another app's bundled copy is that app's licence, not ours: only when a developer asks.
        getenv("CUEVIDEO_NDI_BORROW") ? "/Applications/ProPresenter.app/Contents/Frameworks/libndi.dylib" : NULL,
    };
    for (unsigned i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        if (!paths[i]) continue;
        lib = dlopen(paths[i], RTLD_NOW | RTLD_LOCAL);
        if (lib) { strncpy(loaded, paths[i], sizeof(loaded) - 1); break; }
    }
    if (!lib) { pthread_mutex_unlock(&lock); return NULL; }
    f_initialize = dlsym(lib, "NDIlib_initialize");
    f_find_create_v2 = dlsym(lib, "NDIlib_find_create_v2");
    f_find_wait = dlsym(lib, "NDIlib_find_wait_for_sources");
    f_find_sources = dlsym(lib, "NDIlib_find_get_current_sources");
    f_recv_create_v3 = dlsym(lib, "NDIlib_recv_create_v3");
    f_recv_capture_v2 = dlsym(lib, "NDIlib_recv_capture_v2");
    f_recv_free_video_v2 = dlsym(lib, "NDIlib_recv_free_video_v2");
    f_recv_destroy = dlsym(lib, "NDIlib_recv_destroy");
    f_send_create = dlsym(lib, "NDIlib_send_create");
    f_send_video_v2 = dlsym(lib, "NDIlib_send_send_video_v2");
    f_send_destroy = dlsym(lib, "NDIlib_send_destroy");
    if (!f_initialize || !f_find_create_v2 || !f_recv_create_v3 || !f_recv_capture_v2 || !f_initialize()) {
        dlclose(lib); lib = NULL; pthread_mutex_unlock(&lock); return NULL;
    }
    pthread_mutex_unlock(&lock);
    return loaded;
}

int ndi_sources(char *names, int max, int timeout_ms) {
    if (!ndi_load()) return 0;
    pthread_mutex_lock(&lock);
    if (!finder) { find_create_t fc = { true, NULL, NULL }; finder = f_find_create_v2(&fc); }
    pthread_mutex_unlock(&lock);
    if (!finder) return 0;
    if (timeout_ms > 0) f_find_wait(finder, (uint32_t)timeout_ms);
    // The list belongs to the finder until the next call, and several threads ask (the
    // source picker, and every preview working out which sender to open).
    static pthread_mutex_t list_lock = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&list_lock);
    uint32_t n = 0;
    const source_t *list = f_find_sources(finder, &n);
    int count = 0;
    for (uint32_t i = 0; i < n && count < max; i++) {
        if (!list[i].p_ndi_name) continue;
        strncpy(names + count * 256, list[i].p_ndi_name, 255);
        names[count * 256 + 255] = 0;
        count++;
    }
    pthread_mutex_unlock(&list_lock);
    return count;
}

void *ndi_recv_open(const char *source_name) { return ndi_recv_open_bw(source_name, false); }

void *ndi_recv_open_bw(const char *source_name, bool lowest) {
    if (!ndi_load()) return NULL;
    recv_create_v3_t rc;
    memset(&rc, 0, sizeof(rc));
    rc.source_to_connect_to.p_ndi_name = source_name;
    rc.color_format = 0;        // BGRX, or BGRA when the source has alpha
    rc.bandwidth = lowest ? 0 : 100;  // lowest: the sender's small preview stream
    rc.allow_video_fields = false;
    rc.p_ndi_recv_name = "CueVideo";
    return f_recv_create_v3(&rc);
}

bool ndi_recv_frame(void *recv, int timeout_ms, const uint8_t **data, int *width, int *height, int *stride, void **frame) {
    bool alpha;
    return ndi_recv_frame_alpha(recv, timeout_ms, data, width, height, stride, &alpha, frame);
}

bool ndi_recv_frame_alpha(void *recv, int timeout_ms, const uint8_t **data, int *width, int *height, int *stride, bool *alpha, void **frame) {
    if (!recv) return false;
    video_frame_v2_t *v = calloc(1, sizeof(video_frame_v2_t));
    int type = f_recv_capture_v2(recv, v, NULL, NULL, (uint32_t)timeout_ms);
    if (type != 1 || !v->p_data) { free(v); return false; }
    *data = v->p_data; *width = v->xres; *height = v->yres; *stride = v->line_stride_in_bytes; *frame = v;
    *alpha = v->FourCC == FOURCC('B', 'G', 'R', 'A') || v->FourCC == FOURCC('R', 'G', 'B', 'A');
    return true;
}

float ndi_frame_aspect(void *frame) {
    return frame ? ((video_frame_v2_t *)frame)->picture_aspect_ratio : 0;
}

void ndi_frame_rate(void *frame, int *n, int *d) {
    *n = frame ? ((video_frame_v2_t *)frame)->frame_rate_N : 0;
    *d = frame ? ((video_frame_v2_t *)frame)->frame_rate_D : 0;
}

void ndi_recv_release(void *recv, void *frame) {
    if (!recv || !frame) return;
    f_recv_free_video_v2(recv, frame);
    free(frame);
}

void ndi_recv_close(void *recv) { if (recv && f_recv_destroy) f_recv_destroy(recv); }

void *ndi_send_open(const char *name) { return ndi_send_open_groups(name, NULL); }

void *ndi_send_open_groups(const char *name, const char *groups) {
    if (!ndi_load() || !f_send_create) return NULL;
    send_create_t sc = { name, (groups && groups[0]) ? groups : NULL, true, false };
    return f_send_create(&sc);
}

void ndi_send_frame(void *send, const uint8_t *bgra, int width, int height, int stride, int fps_n, int fps_d) {
    ndi_send_frame_format(send, bgra, width, height, stride, fps_n, fps_d, 0);
}

void ndi_send_frame_format(void *send, const uint8_t *bgra, int width, int height, int stride, int fps_n, int fps_d, int uyvy) {
    if (!send || !f_send_video_v2) return;
    video_frame_v2_t v;
    memset(&v, 0, sizeof(v));
    v.xres = width; v.yres = height; v.FourCC = uyvy ? FOURCC('U', 'Y', 'V', 'Y') : FOURCC('B', 'G', 'R', 'A');
    v.frame_rate_N = fps_n; v.frame_rate_D = fps_d; v.picture_aspect_ratio = (float)width / (float)height;
    v.frame_format_type = 1;    // progressive
    v.timecode = INT64_MAX;     // synthesize
    v.p_data = (uint8_t *)bgra; v.line_stride_in_bytes = stride;
    f_send_video_v2(send, &v);
}

void ndi_send_close(void *send) { if (send && f_send_destroy) f_send_destroy(send); }
