#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "drm.h"
#include "fb.h"
#include "input.h"
#include "status.h"

static volatile sig_atomic_t g_running = 1;

static void handle_signal(int sig) {
    (void)sig;
    g_running = 0;
}

int main(int argc, char** argv) {
    int timeout_sec = 30;
    int brightness = 1024;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--timeout") == 0 && i + 1 < argc) {
            timeout_sec = atoi(argv[++i]);
            if (timeout_sec < 5) timeout_sec = 5;
        } else if (strcmp(argv[i], "--brightness") == 0 && i + 1 < argc) {
            brightness = atoi(argv[++i]);
            if (brightness < 10) brightness = 10;
            if (brightness > 4095) brightness = 4095;
        }
    }

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = handle_signal;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);

    struct drm_dev drm;
    if (drm_init(&drm) < 0) {
        fprintf(stderr, "Failed to initialize DRM subsystem\n");
        return 1;
    }

    struct drm_buf* buf = drm_get_buffer(&drm);

    /* Pre-render dashboard BEFORE activating display */
    struct sys_status st;
    status_collect(&st);
    st.timeout_remaining = timeout_sec;
    status_render(buf, &st);
    drm_present(&drm);

    struct input_ctx input;
    if (input_init(&input, brightness) < 0) {
        fprintf(stderr, "Failed to initialize input devices\n");
        drm_cleanup(&drm);
        return 1;
    }

    if (drm_set_active(&drm, true) < 0) {
        fprintf(stderr, "Failed to activate DRM CRTC\n");
        input_cleanup(&input);
        drm_cleanup(&drm);
        return 1;
    }
    input_set_screen_power(&input, true);

    bool screen_on = true;
    time_t last_active = time(NULL);
    time_t last_render = 0;

    printf("phx-statusd started (timeout=%ds, brightness=%d)\n", timeout_sec, brightness);
    fflush(stdout);

    while (g_running) {
        time_t now = time(NULL);

        if (screen_on) {
            int remain = timeout_sec - (int)(now - last_active);
            if (remain <= 0) {
                /* Auto-off timeout reached: backlight off first to prevent flash */
                input_set_screen_power(&input, false);
                drm_set_active(&drm, false);
                screen_on = false;
                continue;
            }

            if (now != last_render) {
                status_collect(&st);
                st.timeout_remaining = remain;
                status_render(buf, &st);
                drm_present(&drm);
                last_render = now;
            }

            enum input_type ev = input_poll(&input, 1000);
            if (ev == INPUT_EV_POWER) {
                /* Power button pressed to sleep */
                input_set_screen_power(&input, false);
                drm_set_active(&drm, false);
                screen_on = false;
                usleep(250000);
            } else if (ev == INPUT_EV_TOUCH) {
                last_active = time(NULL);
            }
        } else {
            /* Wait for input to wake screen (1s poll allows clean signal handling) */
            enum input_type ev = input_poll(&input, 1000);
            if (ev == INPUT_EV_POWER || ev == INPUT_EV_TOUCH) {
                /* Input event pressed to wake */
                status_collect(&st);
                st.timeout_remaining = timeout_sec;
                status_render(buf, &st);
                drm_present(&drm);
                last_render = time(NULL);

                drm_set_active(&drm, true);
                input_set_screen_power(&input, true);
                screen_on = true;
                last_active = time(NULL);
                usleep(250000);
            }
        }
    }

    printf("phx-statusd stopping...\n");
    input_set_screen_power(&input, false);
    drm_set_active(&drm, false);
    drm_cleanup(&drm);
    input_cleanup(&input);

    return 0;
}
