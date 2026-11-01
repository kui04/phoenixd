#ifndef FB_H
#define FB_H

#include <stdint.h>

#include "drm.h"

#define COLOR_BG 0xFF121417       /* Deep slate black */
#define COLOR_CARD_BG 0xFF1A1D23  /* Card background */
#define COLOR_CARD_BRD 0xFF2B303C /* Card border */
#define COLOR_TEXT 0xFFE6E8EA     /* Primary text */
#define COLOR_TEXT_MUT 0xFF8A909C /* Muted text */
#define COLOR_HEADER 0xFF4FC3F7   /* Light blue header */
#define COLOR_TITLE 0xFFFFFFFF    /* Pure white */
#define COLOR_OK 0xFF66BB6A       /* Green */
#define COLOR_WARN 0xFFFFA726     /* Amber */
#define COLOR_ERR 0xFFEF5350      /* Red */
#define COLOR_ACCENT 0xFF42A5F5   /* Blue accent */

void fb_clear(struct drm_buf* buf, uint32_t color);
void fb_draw_rect(struct drm_buf* buf, int x, int y, int w, int h, uint32_t color);
void fb_draw_rect_outline(struct drm_buf* buf, int x, int y, int w, int h, int thickness,
                          uint32_t color);
void fb_draw_card(struct drm_buf* buf, int x, int y, int w, int h, uint32_t bg_color,
                  uint32_t border_color);
void fb_draw_bar(struct drm_buf* buf, int x, int y, int w, int h, float percent, uint32_t bar_color,
                 uint32_t bg_color);
void fb_draw_char(struct drm_buf* buf, int x, int y, char c, uint32_t fg, uint32_t bg, int scale);
int fb_draw_text(struct drm_buf* buf, int x, int y, const char* str, uint32_t fg, uint32_t bg,
                 int scale);
int fb_draw_text_box(struct drm_buf* buf, int x, int y, int max_w, const char* str, uint32_t fg,
                     uint32_t bg, int scale, int* out_h);

#endif /* FB_H */
