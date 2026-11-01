#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "drm.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

static int find_dpms_prop(int fd, uint32_t conn_id, uint32_t* prop_id) {
    struct drm_mode_get_connector conn = {0};
    conn.connector_id = conn_id;
    if (ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &conn) < 0) {
        return -1;
    }
    if (conn.count_props == 0) {
        return -1;
    }

    uint32_t* props = calloc(conn.count_props, sizeof(uint32_t));
    uint64_t* values = calloc(conn.count_props, sizeof(uint64_t));
    if (!props || !values) {
        free(props);
        free(values);
        return -1;
    }

    conn.props_ptr = (uint64_t)(uintptr_t)props;
    conn.prop_values_ptr = (uint64_t)(uintptr_t)values;
    conn.count_modes = 0;
    conn.count_encoders = 0;

    if (ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &conn) < 0) {
        free(props);
        free(values);
        return -1;
    }

    int ret = -1;
    for (uint32_t i = 0; i < conn.count_props; i++) {
        struct drm_mode_get_property prop = {0};
        prop.prop_id = props[i];
        if (ioctl(fd, DRM_IOCTL_MODE_GETPROPERTY, &prop) == 0) {
            if (strcmp(prop.name, "DPMS") == 0) {
                *prop_id = prop.prop_id;
                ret = 0;
                break;
            }
        }
    }

    free(props);
    free(values);
    return ret;
}

static int alloc_dumb_buf(int fd, int width, int height, struct drm_buf* buf) {
    struct drm_mode_create_dumb creq = {0};
    creq.width = (uint32_t)width;
    creq.height = (uint32_t)height;
    creq.bpp = 32;

    if (ioctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &creq) < 0) {
        perror("DRM_IOCTL_MODE_CREATE_DUMB");
        return -1;
    }

    struct drm_mode_fb_cmd fbreq = {0};
    fbreq.width = (uint32_t)width;
    fbreq.height = (uint32_t)height;
    fbreq.pitch = creq.pitch;
    fbreq.bpp = 32;
    fbreq.depth = 24;
    fbreq.handle = creq.handle;

    if (ioctl(fd, DRM_IOCTL_MODE_ADDFB, &fbreq) < 0) {
        perror("DRM_IOCTL_MODE_ADDFB");
        struct drm_mode_destroy_dumb dreq = {.handle = creq.handle};
        ioctl(fd, DRM_IOCTL_MODE_DESTROY_DUMB, &dreq);
        return -1;
    }

    struct drm_mode_map_dumb mreq = {0};
    mreq.handle = creq.handle;
    if (ioctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &mreq) < 0) {
        perror("DRM_IOCTL_MODE_MAP_DUMB");
        ioctl(fd, DRM_IOCTL_MODE_RMFB, &fbreq.fb_id);
        struct drm_mode_destroy_dumb dreq = {.handle = creq.handle};
        ioctl(fd, DRM_IOCTL_MODE_DESTROY_DUMB, &dreq);
        return -1;
    }

    void* map = mmap(NULL, creq.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)mreq.offset);
    if (map == MAP_FAILED) {
        perror("mmap dumb buffer");
        ioctl(fd, DRM_IOCTL_MODE_RMFB, &fbreq.fb_id);
        struct drm_mode_destroy_dumb dreq = {.handle = creq.handle};
        ioctl(fd, DRM_IOCTL_MODE_DESTROY_DUMB, &dreq);
        return -1;
    }

    buf->handle = creq.handle;
    buf->fb_id = fbreq.fb_id;
    buf->width = (uint32_t)width;
    buf->height = (uint32_t)height;
    buf->stride = creq.pitch;
    buf->size = creq.size;
    buf->map = (uint32_t*)map;
    return 0;
}

int drm_init(struct drm_dev* dev) {
    memset(dev, 0, sizeof(*dev));
    dev->fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
    if (dev->fd < 0) {
        perror("open /dev/dri/card0");
        return -1;
    }

    for (int retry = 0; retry < 10; retry++) {
        if (ioctl(dev->fd, DRM_IOCTL_SET_MASTER, 0) == 0) {
            break;
        }
        if (errno != EBUSY && errno != EACCES) {
            break;
        }
        usleep(100000);
    }

    struct drm_mode_card_res res = {0};
    if (ioctl(dev->fd, DRM_IOCTL_MODE_GETRESOURCES, &res) < 0) {
        perror("DRM_IOCTL_MODE_GETRESOURCES count");
        close(dev->fd);
        dev->fd = -1;
        return -1;
    }

    uint32_t* fb_ids = res.count_fbs ? calloc(res.count_fbs, sizeof(uint32_t)) : NULL;
    uint32_t* crtc_ids = res.count_crtcs ? calloc(res.count_crtcs, sizeof(uint32_t)) : NULL;
    uint32_t* conn_ids =
        res.count_connectors ? calloc(res.count_connectors, sizeof(uint32_t)) : NULL;
    uint32_t* enc_ids = res.count_encoders ? calloc(res.count_encoders, sizeof(uint32_t)) : NULL;

    res.fb_id_ptr = (uint64_t)(uintptr_t)fb_ids;
    res.crtc_id_ptr = (uint64_t)(uintptr_t)crtc_ids;
    res.connector_id_ptr = (uint64_t)(uintptr_t)conn_ids;
    res.encoder_id_ptr = (uint64_t)(uintptr_t)enc_ids;

    if (ioctl(dev->fd, DRM_IOCTL_MODE_GETRESOURCES, &res) < 0) {
        perror("DRM_IOCTL_MODE_GETRESOURCES ids");
        free(fb_ids);
        free(crtc_ids);
        free(conn_ids);
        free(enc_ids);
        close(dev->fd);
        dev->fd = -1;
        return -1;
    }

    if (res.count_crtcs == 0 || !crtc_ids || res.count_connectors == 0 || !conn_ids) {
        fprintf(stderr, "No CRTC or connector found in DRM resources\n");
        free(fb_ids);
        free(enc_ids);
        free(conn_ids);
        free(crtc_ids);
        close(dev->fd);
        dev->fd = -1;
        return -1;
    }

    bool found_conn = false;
    uint32_t conn_encoder_id = 0;
    for (uint32_t i = 0; i < res.count_connectors; i++) {
        struct drm_mode_get_connector conn = {0};
        conn.connector_id = conn_ids[i];
        if (ioctl(dev->fd, DRM_IOCTL_MODE_GETCONNECTOR, &conn) < 0) {
            continue;
        }
        if (conn.connection != 1 || conn.count_modes == 0) {
            continue;
        }

        struct drm_mode_modeinfo* modes =
            calloc(conn.count_modes, sizeof(struct drm_mode_modeinfo));
        if (!modes) {
            continue;
        }
        conn.modes_ptr = (uint64_t)(uintptr_t)modes;
        conn.count_props = 0;
        conn.count_encoders = 0;
        if (ioctl(dev->fd, DRM_IOCTL_MODE_GETCONNECTOR, &conn) < 0) {
            free(modes);
            continue;
        }

        /* Prefer 60 Hz mode if available; otherwise use preferred native mode 0 */
        int selected_mode = 0;
        for (uint32_t m = 0; m < conn.count_modes; m++) {
            if (modes[m].hdisplay == modes[0].hdisplay && modes[m].vdisplay == modes[0].vdisplay &&
                modes[m].vrefresh == 60) {
                selected_mode = (int)m;
                break;
            }
        }

        dev->connector_id = conn.connector_id;
        dev->mode = modes[selected_mode];
        dev->width = (int)dev->mode.hdisplay;
        dev->height = (int)dev->mode.vdisplay;
        conn_encoder_id = conn.encoder_id;
        free(modes);
        found_conn = true;
        break;
    }

    if (!found_conn) {
        fprintf(stderr, "No connected DRM display found\n");
        free(fb_ids);
        free(enc_ids);
        free(conn_ids);
        free(crtc_ids);
        close(dev->fd);
        dev->fd = -1;
        return -1;
    }

    uint32_t selected_crtc = 0;
    if (conn_encoder_id) {
        struct drm_mode_get_encoder enc = {0};
        enc.encoder_id = conn_encoder_id;
        if (ioctl(dev->fd, DRM_IOCTL_MODE_GETENCODER, &enc) == 0) {
            for (uint32_t j = 0; j < res.count_crtcs; j++) {
                if (enc.possible_crtcs & (1u << j)) {
                    selected_crtc = crtc_ids[j];
                    break;
                }
            }
        }
    }

    if (selected_crtc == 0) {
        selected_crtc = crtc_ids[0];
    }
    dev->crtc_id = selected_crtc;
    free(fb_ids);
    free(enc_ids);
    free(conn_ids);
    free(crtc_ids);

    find_dpms_prop(dev->fd, dev->connector_id, &dev->dpms_prop_id);

    if (alloc_dumb_buf(dev->fd, dev->width, dev->height, &dev->buf) < 0) {
        drm_cleanup(dev);
        return -1;
    }

    dev->shadow_map = (uint32_t*)malloc(dev->buf.size);
    dev->draw_buf = dev->buf;
    if (dev->shadow_map) {
        dev->draw_buf.map = dev->shadow_map;
    }

    dev->is_active = false;
    return 0;
}

void drm_cleanup(struct drm_dev* dev) {
    if (dev->fd < 0) return;

    if (dev->shadow_map) {
        free(dev->shadow_map);
        dev->shadow_map = NULL;
    }
    if (dev->buf.map) {
        munmap(dev->buf.map, dev->buf.size);
    }
    if (dev->buf.fb_id) {
        ioctl(dev->fd, DRM_IOCTL_MODE_RMFB, &dev->buf.fb_id);
    }
    if (dev->buf.handle) {
        struct drm_mode_destroy_dumb dreq = {.handle = dev->buf.handle};
        ioctl(dev->fd, DRM_IOCTL_MODE_DESTROY_DUMB, &dreq);
    }

    ioctl(dev->fd, DRM_IOCTL_DROP_MASTER, 0);
    close(dev->fd);
    dev->fd = -1;
}

struct drm_buf* drm_get_buffer(struct drm_dev* dev) { return &dev->draw_buf; }

void drm_present(struct drm_dev* dev) {
    if (dev->buf.map && dev->shadow_map) {
        memcpy(dev->buf.map, dev->shadow_map, dev->buf.size);
        struct drm_mode_fb_dirty_cmd dirty = {
            .fb_id = dev->buf.fb_id,
            .flags = 0,
            .color = 0,
            .num_clips = 0,
            .clips_ptr = 0,
        };
        ioctl(dev->fd, DRM_IOCTL_MODE_DIRTYFB, &dirty);
    }
}

int drm_set_active(struct drm_dev* dev, bool active) {
    if (dev->dpms_prop_id) {
        struct drm_mode_connector_set_property sp = {
            .value = active ? 0 : 3, /* 0: On, 3: Off */
            .prop_id = dev->dpms_prop_id,
            .connector_id = dev->connector_id,
        };
        ioctl(dev->fd, DRM_IOCTL_MODE_SETPROPERTY, &sp);
    }

    if (active) {
        uint32_t conn_id = dev->connector_id;
        struct drm_mode_crtc crtc = {
            .crtc_id = dev->crtc_id,
            .fb_id = dev->buf.fb_id,
            .set_connectors_ptr = (uint64_t)(uintptr_t)&conn_id,
            .count_connectors = 1,
            .mode = dev->mode,
            .mode_valid = 1,
        };
        if (ioctl(dev->fd, DRM_IOCTL_MODE_SETCRTC, &crtc) < 0) {
            perror("DRM_IOCTL_MODE_SETCRTC active");
            return -1;
        }
    } else {
        struct drm_mode_crtc crtc = {
            .crtc_id = dev->crtc_id,
            .fb_id = 0,
            .set_connectors_ptr = 0,
            .count_connectors = 0,
            .mode_valid = 0,
        };
        ioctl(dev->fd, DRM_IOCTL_MODE_SETCRTC, &crtc);
    }

    dev->is_active = active;
    return 0;
}
