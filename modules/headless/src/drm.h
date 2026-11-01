#ifndef DRM_H
#define DRM_H

#include <drm/drm.h>
#include <drm/drm_mode.h>
#include <stdbool.h>
#include <stdint.h>

struct drm_buf {
    uint32_t handle;
    uint32_t fb_id;
    uint32_t width;
    uint32_t height;
    uint32_t stride;
    uint64_t size;
    uint32_t* map;
};

struct drm_dev {
    int fd;
    uint32_t connector_id;
    uint32_t crtc_id;
    uint32_t dpms_prop_id;
    int width;
    int height;
    struct drm_mode_modeinfo mode;
    struct drm_buf buf;
    struct drm_buf draw_buf;
    uint32_t* shadow_map;
    bool is_active;
};

int drm_init(struct drm_dev* dev);
void drm_cleanup(struct drm_dev* dev);
struct drm_buf* drm_get_buffer(struct drm_dev* dev);
void drm_present(struct drm_dev* dev);
int drm_set_active(struct drm_dev* dev, bool active);

#endif /* DRM_H */
