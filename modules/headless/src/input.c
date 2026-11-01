#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "input.h"

#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define BITS_PER_LONG (sizeof(unsigned long) * 8)
#define NBITS(x) ((((x) - 1) / BITS_PER_LONG) + 1)
#define OFF(x) ((x) % BITS_PER_LONG)
#define LONG(x) ((x) / BITS_PER_LONG)
#define test_bit(bit, array) (((array)[LONG(bit)] >> OFF(bit)) & 1UL)

static void write_sysfs_int(const char* path, int val) {
    FILE* f = fopen(path, "w");
    if (!f) return;
    fprintf(f, "%d\n", val);
    fclose(f);
}

int input_init(struct input_ctx* ctx, int default_brightness) {
    memset(ctx, 0, sizeof(*ctx));
    ctx->brightness_level = (default_brightness > 0) ? default_brightness : 1024;
    ctx->fd_power = -1;
    ctx->fd_touch = -1;

    char path[64];
    for (int i = 0; i < 32; i++) {
        if (ctx->fd_power >= 0 && ctx->fd_touch >= 0) {
            break;
        }

        snprintf(path, sizeof(path), "/dev/input/event%d", i);
        int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
        if (fd < 0) continue;

        unsigned long ev_bits[NBITS(EV_MAX)] = {0};
        if (ioctl(fd, EVIOCGBIT(0, sizeof(ev_bits)), ev_bits) >= 0) {
            if (ctx->fd_power < 0 && test_bit(EV_KEY, ev_bits)) {
                unsigned long key_bits[NBITS(KEY_MAX)] = {0};
                if (ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(key_bits)), key_bits) >= 0) {
                    if (test_bit(KEY_POWER, key_bits)) {
                        ctx->fd_power = fd;
                        if (ctx->fd_touch >= 0) break;
                        continue;
                    }
                }
            }

            if (ctx->fd_touch < 0 && test_bit(EV_ABS, ev_bits)) {
                unsigned long abs_bits[NBITS(ABS_MAX)] = {0};
                if (ioctl(fd, EVIOCGBIT(EV_ABS, sizeof(abs_bits)), abs_bits) >= 0) {
                    if (test_bit(ABS_MT_POSITION_X, abs_bits) || test_bit(ABS_X, abs_bits)) {
                        ctx->fd_touch = fd;
                        if (ctx->fd_power >= 0) break;
                        continue;
                    }
                }
            }
        }

        close(fd);
    }

    if (ctx->fd_power < 0) {
        fprintf(stderr, "No power button input device found\n");
        if (ctx->fd_touch >= 0) {
            close(ctx->fd_touch);
            ctx->fd_touch = -1;
        }
        return -1;
    }

    return 0;
}

void input_cleanup(struct input_ctx* ctx) {
    if (ctx->fd_power >= 0) {
        close(ctx->fd_power);
        ctx->fd_power = -1;
    }
    if (ctx->fd_touch >= 0) {
        close(ctx->fd_touch);
        ctx->fd_touch = -1;
    }
}

void input_set_screen_power(struct input_ctx* ctx, bool on) {
    if (on) {
        write_sysfs_int("/sys/class/backlight/panel0-backlight/bl_power", 0);
        write_sysfs_int("/sys/class/backlight/panel0-backlight/brightness", ctx->brightness_level);
    } else {
        write_sysfs_int("/sys/class/backlight/panel0-backlight/brightness", 0);
        write_sysfs_int("/sys/class/backlight/panel0-backlight/bl_power", 4);
    }
}

enum input_type input_poll(struct input_ctx* ctx, int timeout_ms) {
    struct pollfd pfds[2];
    int count = 0;

    if (ctx->fd_power >= 0) {
        pfds[count].fd = ctx->fd_power;
        pfds[count].events = POLLIN;
        pfds[count].revents = 0;
        count++;
    }
    if (ctx->fd_touch >= 0) {
        pfds[count].fd = ctx->fd_touch;
        pfds[count].events = POLLIN;
        pfds[count].revents = 0;
        count++;
    }

    if (count == 0) {
        if (timeout_ms < 0) {
            sleep(1);
        } else if (timeout_ms > 0) {
            usleep((useconds_t)timeout_ms * 1000);
        }
        return INPUT_EV_NONE;
    }

    int ret = poll(pfds, (nfds_t)count, timeout_ms);
    if (ret <= 0) {
        return INPUT_EV_NONE;
    }

    enum input_type result = INPUT_EV_NONE;
    struct input_event ev;

    for (int i = 0; i < count; i++) {
        if (pfds[i].revents & (POLLERR | POLLHUP | POLLNVAL)) {
            if (pfds[i].fd == ctx->fd_power) {
                close(ctx->fd_power);
                ctx->fd_power = -1;
            } else if (pfds[i].fd == ctx->fd_touch) {
                close(ctx->fd_touch);
                ctx->fd_touch = -1;
            }
            continue;
        }
        if (pfds[i].revents & POLLIN) {
            while (read(pfds[i].fd, &ev, sizeof(ev)) == sizeof(ev)) {
                if (ev.type == EV_KEY && ev.code == KEY_POWER && ev.value == 1) {
                    result = INPUT_EV_POWER;
                } else if (ev.type == EV_ABS) {
                    if (result != INPUT_EV_POWER) {
                        result = INPUT_EV_TOUCH;
                    }
                }
            }
        }
    }

    return result;
}
