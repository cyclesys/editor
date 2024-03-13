#include "internal.h"

D2D1_COLOR_F colorToD2D(Color color) {
    static const int r_shift = 24;
    static const Color r_mask = 0xFF << r_shift;
    static const int g_shift = 16;
    static const Color g_mask = 0xFF << g_shift;
    static const int b_shift = 8;
    static const Color b_mask = 0xFF << b_shift;
    static const int a_shift = 0;
    static const Color a_mask = 0xFF << a_shift;

    D2D1_COLOR_F color_f;
    color_f.r = static_cast<FLOAT>((color & r_mask) >> r_shift) / 255.f;
    color_f.g = static_cast<FLOAT>((color & g_mask) >> g_shift) / 255.f;
    color_f.b = static_cast<FLOAT>((color & b_mask) >> b_shift) / 255.f;
    color_f.a = static_cast<FLOAT>((color & a_mask) >> a_shift) / 255.f;
    return color_f;
}

D2D1_RECT_F rectToD2D(Rect r) {
    D2D1_RECT_F rect;
    rect.left = r.offset.dx;
    rect.top = r.offset.dy;
    rect.right = r.offset.dx + r.size.width;
    rect.bottom = r.offset.dy + r.size.height;
    return rect;
}

D2D1_ROUNDED_RECT rrectToD2D(RRect rr) {
    D2D1_ROUNDED_RECT rrect;
    rrect.rect = rectToD2D(rr.rect);
    rrect.radiusX = rr.rx;
    rrect.radiusY = rr.ry;
    return rrect;
}