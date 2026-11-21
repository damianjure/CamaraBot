#ifndef NDI_BRIDGE_H
#define NDI_BRIDGE_H
#include <stdint.h>
#include <stdbool.h>

// NDI by dynamic loading: no SDK needed to build. The runtime comes from
// NDI Tools, the NDI SDK, or (on a ProPresenter Mac) ProPresenter's copy.
// NDI is a registered trademark of Vizrt NDI AB.

/// Loads and initializes the runtime. Returns the path loaded, or NULL.
const char *ndi_load(void);
/// Names of the NDI sources on the network now (waits up to timeout_ms for
/// changes). Writes up to max names of 256 bytes each; returns the count.
int ndi_sources(char *names, int max, int timeout_ms);

void *ndi_recv_open(const char *source_name);
/// lowest: ask for the sender's small preview stream (about 640 wide), for monitors.
void *ndi_recv_open_bw(const char *source_name, bool lowest);
/// As ndi_recv_frame, and says whether the frame carries alpha (BGRA) or not (BGRX).
bool ndi_recv_frame_alpha(void *recv, int timeout_ms, const uint8_t **data, int *width, int *height, int *stride, bool *alpha, void **frame);
/// Waits up to timeout_ms for a video frame. On success fills in BGRA data,
/// size and stride, and a handle to release with ndi_recv_release.
bool ndi_recv_frame(void *recv, int timeout_ms, const uint8_t **data, int *width, int *height, int *stride, void **frame);
/// The shape the picture should be shown at (width ÷ height) for a frame from ndi_recv_frame,
/// which differs from its pixel size when the pixels aren't square. 0 if the sender didn't say.
float ndi_frame_aspect(void *frame);
/// The frame rate the sender says (numerator and denominator), or 0 and 0 when it didn't.
void ndi_frame_rate(void *frame, int *n, int *d);
void ndi_recv_release(void *recv, void *frame);
void ndi_recv_close(void *recv);

void *ndi_send_open(const char *name);
/// As ndi_send_open, in these NDI groups (comma separated). Only receivers looking in a group
/// can see the source; NULL or empty is the public group everyone looks in.
void *ndi_send_open_groups(const char *name, const char *groups);
void ndi_send_frame(void *send, const uint8_t *bgra, int width, int height, int stride, int fps_n, int fps_d);
void ndi_send_close(void *send);
#endif
