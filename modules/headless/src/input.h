#ifndef INPUT_H
#define INPUT_H

#include <stdbool.h>

enum input_type {
    INPUT_EV_NONE = 0,
    INPUT_EV_POWER,
    INPUT_EV_TOUCH,
};

struct input_ctx {
    int fd_power;
    int fd_touch;
    int brightness_level;
};

int input_init(struct input_ctx* ctx, int default_brightness);
void input_cleanup(struct input_ctx* ctx);
enum input_type input_poll(struct input_ctx* ctx, int timeout_ms);
void input_set_screen_power(struct input_ctx* ctx, bool on);

#endif /* INPUT_H */
