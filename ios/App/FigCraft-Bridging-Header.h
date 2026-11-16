#ifndef FIGCRAFT_BRIDGING_H
#define FIGCRAFT_BRIDGING_H

#include <stdint.h>
#include <stddef.h>

typedef struct FCCallbacks {
    void *user;
    void (*open_files)(void *user);
    void (*save_file)(void *user, const char *name, const uint8_t *data, size_t len);
    void (*open_url)(void *user, const char *url);
    void (*copy_text)(void *user, const char *text);
    const char *(*paste_text)(void *user);
    const char *(*paste_html)(void *user);
    void (*copy_image)(void *user, uint32_t w, uint32_t h, const uint8_t *rgba, size_t len);
    const uint8_t *(*paste_png)(void *user, size_t *out_len);
    int (*reduce_motion)(void *user);
    const char *(*system_language)(void *user);
} FCCallbacks;

void *fc_create(void *metal_layer, uint32_t width_px, uint32_t height_px, float scale, FCCallbacks cb);
void fc_destroy(void *h);
void fc_resize(void *h, uint32_t width_px, uint32_t height_px, float scale);
void fc_set_dark(void *h, int dark);
void fc_set_focused(void *h, int focused);
void fc_pointer_moved(void *h, float x, float y);
void fc_pointer_gone(void *h);
void fc_pointer_button(void *h, float x, float y, int button, int pressed, uint32_t mods);
void fc_touch(void *h, uint64_t id, int phase, float x, float y, float force);
void fc_scroll(void *h, float dx, float dy, uint32_t mods);
void fc_zoom(void *h, float factor);
void fc_key(void *h, uint32_t hid, int pressed, int repeat, uint32_t mods);
void fc_text(void *h, const char *utf8);
void fc_copy(void *h);
void fc_cut(void *h);
void fc_paste(void *h, const char *utf8);
void fc_open_file(void *h, const char *name, const uint8_t *data, size_t len);
void fc_open_cancel(void *h, const char *error);
void fc_save_result(void *h, int ok, const char *final_name);
int fc_frame(void *h);
void fc_save_state(void *h);
int fc_is_dirty(void *h);

#endif
