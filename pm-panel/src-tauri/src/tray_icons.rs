//! Tray icon generation for full parity with Raycast: task (arrow-circle, ellipsis, yellow/red)
//! and status (progress ring). All icons 32x32 RGBA.

use image::{ImageBuffer, RgbaImage};
use std::f64::consts::PI;
use tauri::image::Image;

const SZ: u32 = 32;
const CX: f64 = 15.5;
const CY: f64 = 15.5;

fn rgba_to_tauri(img: RgbaImage) -> Image<'static> {
    Image::new_owned(img.into_raw(), SZ, SZ)
}

/// Black (#000000) on transparent — for macOS template (system tints).
fn pixel_template(x: u32, y: u32, img: &mut RgbaImage, filled: bool) {
    let p = img.get_pixel_mut(x, y);
    if filled {
        p[0] = 0;
        p[1] = 0;
        p[2] = 0;
        p[3] = 255;
    } else {
        p[3] = 0;
    }
}

fn in_circle(x: f64, y: f64, cx: f64, cy: f64, r: f64) -> bool {
    (x - cx).mul_add(x - cx, (y - cy) * (y - cy)) <= r * r
}

fn in_ring(x: f64, y: f64, cx: f64, cy: f64, r_in: f64, r_out: f64) -> bool {
    let d = (x - cx).mul_add(x - cx, (y - cy) * (y - cy));
    d >= r_in * r_in && d <= r_out * r_out
}

/// Point-in-triangle (2D).
fn in_triangle(px: f64, py: f64, x1: f64, y1: f64, x2: f64, y2: f64, x3: f64, y3: f64) -> bool {
    let sign = |ax: f64, ay: f64, bx: f64, by: f64, cx: f64, cy: f64| {
        (bx - ax) * (cy - ay) - (cx - ax) * (by - ay)
    };
    let d1 = sign(px, py, x1, y1, x2, y2);
    let d2 = sign(px, py, x2, y2, x3, y3);
    let d3 = sign(px, py, x3, y3, x1, y1);
    (d1 >= 0.0 && d2 >= 0.0 && d3 >= 0.0) || (d1 <= 0.0 && d2 <= 0.0 && d3 <= 0.0)
}

/// Arrow-right-circle: circle outline + arrow triangle pointing right. Template (black on transparent).
pub fn task_icon_arrow_circle_template() -> Image<'static> {
    let mut img = ImageBuffer::from_pixel(SZ, SZ, image::Rgba([0, 0, 0, 0]));
    let r_out = 12.0;
    let r_in = 10.0;
    for y in 0..SZ {
        for x in 0..SZ {
            let xf = x as f64 + 0.5;
            let yf = y as f64 + 0.5;
            let on_ring = in_ring(xf, yf, CX, CY, r_in, r_out);
            let arrow = in_triangle(xf, yf, 14.0, 8.0, 14.0, 23.0, 24.0, 15.5);
            pixel_template(x, y, &mut img, on_ring || arrow);
        }
    }
    rgba_to_tauri(img)
}

/// Ellipsis: three dots. Template (black on transparent).
pub fn task_icon_ellipsis_template() -> Image<'static> {
    let mut img = ImageBuffer::from_pixel(SZ, SZ, image::Rgba([0, 0, 0, 0]));
    let centers = [(8.0, CY), (16.0, CY), (24.0, CY)];
    let r = 3.0;
    for y in 0..SZ {
        for x in 0..SZ {
            let xf = x as f64 + 0.5;
            let yf = y as f64 + 0.5;
            let on_dot = centers
                .iter()
                .any(|&(cx, cy)| in_circle(xf, yf, cx, cy, r));
            pixel_template(x, y, &mut img, on_dot);
        }
    }
    rgba_to_tauri(img)
}

fn set_rgba(img: &mut RgbaImage, x: u32, y: u32, r: u8, g: u8, b: u8, a: u8) {
    let p = img.get_pixel_mut(x, y);
    p[0] = r;
    p[1] = g;
    p[2] = b;
    p[3] = a;
}

/// Arrow-right-circle in solid color (yellow or red). Not template.
pub fn task_icon_arrow_circle_colored(r: u8, g: u8, b: u8) -> Image<'static> {
    let mut img = ImageBuffer::from_pixel(SZ, SZ, image::Rgba([0, 0, 0, 0]));
    let r_out = 12.0;
    let r_in = 10.0;
    for y in 0..SZ {
        for x in 0..SZ {
            let xf = x as f64 + 0.5;
            let yf = y as f64 + 0.5;
            let on_ring = in_ring(xf, yf, CX, CY, r_in, r_out);
            let arrow = in_triangle(xf, yf, 14.0, 8.0, 14.0, 23.0, 24.0, 15.5);
            if on_ring || arrow {
                set_rgba(&mut img, x, y, r, g, b, 255);
            }
        }
    }
    rgba_to_tauri(img)
}

// --- Menu item icons (16x16, template black on transparent) ---

const MENU_SZ: u32 = 16;
const MENU_CX: f64 = 7.5;
const MENU_CY: f64 = 7.5;

fn menu_img_to_tauri(img: ImageBuffer<image::Rgba<u8>, Vec<u8>>) -> Image<'static> {
    Image::new_owned(img.into_raw(), MENU_SZ, MENU_SZ)
}

fn menu_pixel(img: &mut ImageBuffer<image::Rgba<u8>, Vec<u8>>, x: u32, y: u32, filled: bool) {
    let p = img.get_pixel_mut(x, y);
    if filled {
        p[0] = 0;
        p[1] = 0;
        p[2] = 0;
        p[3] = 255;
    } else {
        p[3] = 0;
    }
}

fn in_circle_16(x: f64, y: f64, cx: f64, cy: f64, r: f64) -> bool {
    (x - cx).mul_add(x - cx, (y - cy) * (y - cy)) <= r * r
}

fn in_ring_16(x: f64, y: f64, cx: f64, cy: f64, r_in: f64, r_out: f64) -> bool {
    let d = (x - cx).mul_add(x - cx, (y - cy) * (y - cy));
    d >= r_in * r_in && d <= r_out * r_out
}

/// Checkmark in circle (Complete, All Done). Circle ring + two-segment check.
pub fn menu_icon_check_circle() -> Image<'static> {
    let mut img = ImageBuffer::from_pixel(MENU_SZ, MENU_SZ, image::Rgba([0, 0, 0, 0]));
    let r_out = 6.0;
    let r_in = 4.5;
    for y in 0..MENU_SZ {
        for x in 0..MENU_SZ {
            let xf = x as f64 + 0.5;
            let yf = y as f64 + 0.5;
            let ring = in_ring_16(xf, yf, MENU_CX, MENU_CY, r_in, r_out);
            let near_line = |x1: f64, y1: f64, x2: f64, y2: f64| {
                let dx = x2 - x1;
                let dy = y2 - y1;
                let t = ((xf - x1) * dx + (yf - y1) * dy) / (dx * dx + dy * dy + 1e-9);
                let t = t.clamp(0.0, 1.0);
                let px = x1 + t * dx;
                let py = y1 + t * dy;
                (xf - px).abs() + (yf - py).abs() < 1.2
            };
            let check = near_line(4.0, 5.0, 7.0, 9.0) || near_line(7.0, 9.0, 11.0, 4.0);
            menu_pixel(&mut img, x, y, ring || check);
        }
    }
    menu_img_to_tauri(img)
}

/// Empty circle (No Tasks, non-focused todo).
pub fn menu_icon_circle() -> Image<'static> {
    let mut img = ImageBuffer::from_pixel(MENU_SZ, MENU_SZ, image::Rgba([0, 0, 0, 0]));
    let r_out = 6.0;
    let r_in = 4.5;
    for y in 0..MENU_SZ {
        for x in 0..MENU_SZ {
            let xf = x as f64 + 0.5;
            let yf = y as f64 + 0.5;
            menu_pixel(&mut img, x, y, in_ring_16(xf, yf, MENU_CX, MENU_CY, r_in, r_out));
        }
    }
    menu_img_to_tauri(img)
}

/// Circle with right arrow (focused todo).
pub fn menu_icon_arrow_right_circle() -> Image<'static> {
    let mut img = ImageBuffer::from_pixel(MENU_SZ, MENU_SZ, image::Rgba([0, 0, 0, 0]));
    let r_out = 6.0;
    let r_in = 4.5;
    for y in 0..MENU_SZ {
        for x in 0..MENU_SZ {
            let xf = x as f64 + 0.5;
            let yf = y as f64 + 0.5;
            let ring = in_ring_16(xf, yf, MENU_CX, MENU_CY, r_in, r_out);
            let arrow = in_triangle(xf, yf, 6.0, 3.0, 6.0, 12.0, 12.0, 7.5);
            menu_pixel(&mut img, x, y, ring || arrow);
        }
    }
    menu_img_to_tauri(img)
}

/// Plus (Narrow Focus).
pub fn menu_icon_plus() -> Image<'static> {
    let mut img = ImageBuffer::from_pixel(MENU_SZ, MENU_SZ, image::Rgba([0, 0, 0, 0]));
    for y in 0..MENU_SZ {
        for x in 0..MENU_SZ {
            let h = (x >= 6 && x <= 9) || (y >= 6 && y <= 9);
            menu_pixel(&mut img, x, y, h);
        }
    }
    menu_img_to_tauri(img)
}

/// Down arrow (Add After).
pub fn menu_icon_arrow_down() -> Image<'static> {
    let mut img = ImageBuffer::from_pixel(MENU_SZ, MENU_SZ, image::Rgba([0, 0, 0, 0]));
    for y in 0..MENU_SZ {
        for x in 0..MENU_SZ {
            let arrow = in_triangle(x as f64 + 0.5, y as f64 + 0.5, 2.0, 4.0, 13.0, 4.0, 7.5, 12.0);
            menu_pixel(&mut img, x, y, arrow);
        }
    }
    menu_img_to_tauri(img)
}

/// Up arrow (Add Before).
pub fn menu_icon_arrow_up() -> Image<'static> {
    let mut img = ImageBuffer::from_pixel(MENU_SZ, MENU_SZ, image::Rgba([0, 0, 0, 0]));
    for y in 0..MENU_SZ {
        for x in 0..MENU_SZ {
            let arrow = in_triangle(x as f64 + 0.5, y as f64 + 0.5, 7.5, 3.0, 2.0, 11.0, 13.0, 11.0);
            menu_pixel(&mut img, x, y, arrow);
        }
    }
    menu_img_to_tauri(img)
}

/// Text cursor / edit (I-beam style).
pub fn menu_icon_text_cursor() -> Image<'static> {
    let mut img = ImageBuffer::from_pixel(MENU_SZ, MENU_SZ, image::Rgba([0, 0, 0, 0]));
    for y in 0..MENU_SZ {
        for x in 0..MENU_SZ {
            let line = (x >= 7 && x <= 8) || (y >= 2 && y <= 4 && x >= 6 && x <= 9);
            menu_pixel(&mut img, x, y, line);
        }
    }
    menu_img_to_tauri(img)
}

/// Layers / stack (Wrap).
pub fn menu_icon_layers() -> Image<'static> {
    let mut img = ImageBuffer::from_pixel(MENU_SZ, MENU_SZ, image::Rgba([0, 0, 0, 0]));
    for y in 0..MENU_SZ {
        for x in 0..MENU_SZ {
            let top = y >= 2 && y <= 4 && x >= 2 && x <= 13;
            let mid = y >= 5 && y <= 7 && x >= 4 && x <= 11;
            let bot = y >= 8 && y <= 10 && x >= 6 && x <= 9;
            menu_pixel(&mut img, x, y, top || mid || bot);
        }
    }
    menu_img_to_tauri(img)
}

/// Undo (curved arrow left).
pub fn menu_icon_undo() -> Image<'static> {
    let mut img = ImageBuffer::from_pixel(MENU_SZ, MENU_SZ, image::Rgba([0, 0, 0, 0]));
    for y in 0..MENU_SZ {
        for x in 0..MENU_SZ {
            let xf = x as f64 + 0.5;
            let yf = y as f64 + 0.5;
            let mut angle = (xf - MENU_CX).atan2(-(yf - MENU_CY));
            if angle < 0.0 {
                angle += 2.0 * PI;
            }
            let on_arc = in_ring_16(xf, yf, MENU_CX, MENU_CY, 4.0, 6.0)
                && angle >= PI * 0.3
                && angle <= PI * 1.2;
            let head = xf <= 4.0 && yf >= 5.0 && yf <= 10.0;
            menu_pixel(&mut img, x, y, on_arc || head);
        }
    }
    menu_img_to_tauri(img)
}

/// Terminal (Open in Cursor).
pub fn menu_icon_terminal() -> Image<'static> {
    let mut img = ImageBuffer::from_pixel(MENU_SZ, MENU_SZ, image::Rgba([0, 0, 0, 0]));
    for y in 0..MENU_SZ {
        for x in 0..MENU_SZ {
            let frame = (x >= 1 && x <= 14 && (y == 2 || y == 13)) || (y >= 2 && y <= 13 && (x == 1 || x == 14));
            let prompt = y >= 6 && y <= 8 && x >= 3 && x <= 5;
            let caret = y >= 10 && y <= 11 && x >= 8 && x <= 9;
            menu_pixel(&mut img, x, y, frame || prompt || caret);
        }
    }
    menu_img_to_tauri(img)
}

/// Folder (Open in Finder).
pub fn menu_icon_folder() -> Image<'static> {
    let mut img = ImageBuffer::from_pixel(MENU_SZ, MENU_SZ, image::Rgba([0, 0, 0, 0]));
    for y in 0..MENU_SZ {
        for x in 0..MENU_SZ {
            let tab = y <= 2 && x >= 2 && x <= 12;
            let body = y >= 2 && y <= 13 && x >= 1 && x <= 13;
            let left = x == 1 && y >= 2;
            let right = x == 13 && y >= 2;
            let bottom = y >= 12 && y <= 13 && x >= 1 && x <= 13;
            menu_pixel(&mut img, x, y, tab || body || left || right || bottom);
        }
    }
    menu_img_to_tauri(img)
}

/// Short paragraph / document lines (Add Session Note).
pub fn menu_icon_paragraph() -> Image<'static> {
    let mut img = ImageBuffer::from_pixel(MENU_SZ, MENU_SZ, image::Rgba([0, 0, 0, 0]));
    for y in 0..MENU_SZ {
        for x in 0..MENU_SZ {
            let line = (y >= 4 && y <= 5 && x >= 2 && x <= 13)
                || (y >= 7 && y <= 8 && x >= 2 && x <= 10)
                || (y >= 10 && y <= 11 && x >= 2 && x <= 12);
            menu_pixel(&mut img, x, y, line);
        }
    }
    menu_img_to_tauri(img)
}

/// Link (Add Link, or generic link icon).
pub fn menu_icon_link() -> Image<'static> {
    let mut img = ImageBuffer::from_pixel(MENU_SZ, MENU_SZ, image::Rgba([0, 0, 0, 0]));
    for y in 0..MENU_SZ {
        for x in 0..MENU_SZ {
            let xf = x as f64 + 0.5;
            let yf = y as f64 + 0.5;
            let left = in_circle_16(xf, yf, 5.0, 6.0, 3.0);
            let right = in_circle_16(xf, yf, 11.0, 10.0, 3.0);
            let bar = yf >= 7.0 && yf <= 9.0 && xf >= 4.0 && xf <= 12.0;
            menu_pixel(&mut img, x, y, left || right || bar);
        }
    }
    menu_img_to_tauri(img)
}

/// Progress ring 16x16 for status menu (e.g. recent projects).
pub fn menu_icon_progress(progress: f64) -> Image<'static> {
    let mut img = ImageBuffer::from_pixel(MENU_SZ, MENU_SZ, image::Rgba([0, 0, 0, 0]));
    let r_out = 6.0;
    let r_in = 4.0;
    let progress = progress.clamp(0.0, 1.0);
    for y in 0..MENU_SZ {
        for x in 0..MENU_SZ {
            let xf = x as f64 + 0.5;
            let yf = y as f64 + 0.5;
            if !in_ring_16(xf, yf, MENU_CX, MENU_CY, r_in, r_out) {
                continue;
            }
            let mut angle = (xf - MENU_CX).atan2(-(yf - MENU_CY));
            if angle < 0.0 {
                angle += 2.0 * PI;
            }
            let threshold = progress * 2.0 * PI;
            menu_pixel(&mut img, x, y, angle <= threshold);
        }
    }
    menu_img_to_tauri(img)
}

/// Progress ring: circular progress 0.0..=1.0 (0 = empty, 1 = full). Black on transparent for template.
/// Raycast uses getProgressIcon(progress, color, { backgroundOpacity, background }).
/// We draw a ring and fill the arc clockwise from top (12 o'clock).
pub fn status_icon_progress_template(progress: f64) -> Image<'static> {
    let mut img = ImageBuffer::from_pixel(SZ, SZ, image::Rgba([0, 0, 0, 0]));
    let r_out = 14.0;
    let r_in = 10.0;
    let progress = progress.clamp(0.0, 1.0);
    for y in 0..SZ {
        for x in 0..SZ {
            let xf = x as f64 + 0.5;
            let yf = y as f64 + 0.5;
            if !in_ring(xf, yf, CX, CY, r_in, r_out) {
                continue;
            }
            // Angle from top (12 o'clock), clockwise. atan2: 0 = right, PI/2 = down.
            // We want 0 = top: angle = atan2(x - cx, -(y - cy)) so top = 0, right = PI/2, etc.
            let mut angle = (xf - CX).atan2(-(yf - CY));
            if angle < 0.0 {
                angle += 2.0 * PI;
            }
            // Progress 1.0 = full circle (2*PI), 0 = none.
            let threshold = progress * 2.0 * PI;
            let filled = angle <= threshold;
            pixel_template(x, y, &mut img, filled);
        }
    }
    rgba_to_tauri(img)
}
