#include "fb.h"

#include <ctype.h>
#include <string.h>

#include "font8x16.h"

void fb_clear(struct drm_buf* buf, uint32_t color) {
    int count = (int)(buf->stride / sizeof(uint32_t)) * (int)buf->height;
    for (int i = 0; i < count; i++) {
        buf->map[i] = color;
    }
}

void fb_draw_rect(struct drm_buf* buf, int x, int y, int w, int h, uint32_t color) {
    if (x < 0) {
        w += x;
        x = 0;
    }
    if (y < 0) {
        h += y;
        y = 0;
    }
    if (x >= (int)buf->width || y >= (int)buf->height || w <= 0 || h <= 0) return;
    if (x + w > (int)buf->width) w = (int)buf->width - x;
    if (y + h > (int)buf->height) h = (int)buf->height - y;

    int pitch_pixels = (int)(buf->stride / sizeof(uint32_t));
    for (int row = y; row < y + h; row++) {
        uint32_t* dst = buf->map + row * pitch_pixels + x;
        for (int col = 0; col < w; col++) {
            dst[col] = color;
        }
    }
}

void fb_draw_rect_outline(struct drm_buf* buf, int x, int y, int w, int h, int thickness,
                          uint32_t color) {
    fb_draw_rect(buf, x, y, w, thickness, color);
    fb_draw_rect(buf, x, y + h - thickness, w, thickness, color);
    fb_draw_rect(buf, x, y, thickness, h, color);
    fb_draw_rect(buf, x + w - thickness, y, thickness, h, color);
}

void fb_draw_card(struct drm_buf* buf, int x, int y, int w, int h, uint32_t bg_color,
                  uint32_t border_color) {
    fb_draw_rect(buf, x, y, w, h, bg_color);
    fb_draw_rect_outline(buf, x, y, w, h, 2, border_color);
}

void fb_draw_bar(struct drm_buf* buf, int x, int y, int w, int h, float percent, uint32_t bar_color,
                 uint32_t bg_color) {
    if (percent < 0.0f) percent = 0.0f;
    if (percent > 1.0f) percent = 1.0f;
    fb_draw_rect(buf, x, y, w, h, bg_color);
    int fill_w = (int)((float)w * percent);
    if (fill_w > 0) {
        fb_draw_rect(buf, x, y, fill_w, h, bar_color);
    }
}

void fb_draw_char(struct drm_buf* buf, int x, int y, char c, uint32_t fg, uint32_t bg, int scale) {
    if (scale <= 0) scale = 1;
    uint8_t uc = (uint8_t)c;
    const uint8_t* glyph = font8x16[uc];
    int pitch_pixels = (int)(buf->stride / sizeof(uint32_t));

    for (int r = 0; r < 16; r++) {
        uint8_t row_bits = glyph[r];
        for (int sy = 0; sy < scale; sy++) {
            int py = y + r * scale + sy;
            if (py < 0 || py >= (int)buf->height) continue;
            uint32_t* line = buf->map + py * pitch_pixels;

            for (int c_bit = 0; c_bit < 8; c_bit++) {
                uint32_t color = ((row_bits >> (7 - c_bit)) & 1) ? fg : bg;
                if (color == 0 && bg == 0) continue; /* Transparent background */
                for (int sx = 0; sx < scale; sx++) {
                    int px = x + c_bit * scale + sx;
                    if (px >= 0 && px < (int)buf->width) {
                        line[px] = color;
                    }
                }
            }
        }
    }
}

int fb_draw_text(struct drm_buf* buf, int x, int y, const char* str, uint32_t fg, uint32_t bg,
                 int scale) {
    if (scale <= 0) scale = 1;
    int start_x = x;
    int char_w = 8 * scale;
    while (*str) {
        if (*str == '\n') {
            x = start_x;
            y += 16 * scale;
            str++;
            continue;
        }
        fb_draw_char(buf, x, y, *str, fg, bg, scale);
        x += char_w;
        str++;
    }
    return x;
}

int fb_draw_text_box(struct drm_buf* buf, int x, int y, int max_w, const char* str, uint32_t fg,
                     uint32_t bg, int scale, int* out_h) {
    if (scale <= 0) scale = 1;
    int char_w = 8 * scale;
    int char_h = 16 * scale;
    int line_spacing = 4 * scale;
    int cur_x = x;
    int cur_y = y;
    const char* p = str;

    while (*p) {
        if (*p == '\n') {
            cur_x = x;
            cur_y += char_h + line_spacing;
            p++;
            continue;
        }

        if (isspace((unsigned char)*p)) {
            cur_x += char_w;
            p++;
            continue;
        }

        /* Identify length of current word */
        const char* word_start = p;
        while (*p && !isspace((unsigned char)*p) && *p != '\n') {
            p++;
        }
        int word_len = (int)(p - word_start);
        int word_px_len = word_len * char_w;

        /* Check if word overflows current line */
        if (cur_x + word_px_len > x + max_w && cur_x > x) {
            cur_x = x;
            cur_y += char_h + line_spacing;
        }

        /* Draw word */
        for (int i = 0; i < word_len; i++) {
            if (cur_x + char_w > x + max_w) {
                cur_x = x;
                cur_y += char_h + line_spacing;
            }
            fb_draw_char(buf, cur_x, cur_y, word_start[i], fg, bg, scale);
            cur_x += char_w;
        }
    }

    int total_h = (cur_y + char_h) - y;
    if (out_h) *out_h = total_h;
    return cur_y;
}
