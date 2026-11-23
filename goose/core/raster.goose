// Umbra core: a software rasterizer, for proving that the geometry and the atlas are
// what a picture is made of - with no GPU in the loop.
//
// Why this exists: the phone draws with GLES and CI has no GPU, so the only way to
// check "the jar's models and the jar's textures come out as a world" in CI is to
// rasterize the same vertex buffer on the CPU. This is a small, honest rasterizer:
// perspective divide, barycentric fill, a depth buffer, nearest-neighbour sampling,
// alpha cutout, a blended pass, and fog. It is not fast and it is not a renderer;
// it is a measuring instrument that happens to write a picture.
//
// Everything here is Goose, which compiles to C, so a 960x540 frame of half a million
// triangles takes a second or two rather than a minute.

import std;
import os;
import core.mesh;

var rst_w: i64 = 0;
var rst_h: i64 = 0;
var rst_color: u8[>..] = [];
var rst_depth: f32[>..] = [];
var rst_view: f32[16] = [
    1.0, 0.0, 0.0, 0.0,
    0.0, 1.0, 0.0, 0.0,
    0.0, 0.0, 1.0, 0.0,
    0.0, 0.0, 0.0, 1.0,
];
var rst_proj: f32[16] = [
    1.0, 0.0, 0.0, 0.0,
    0.0, 1.0, 0.0, 0.0,
    0.0, 0.0, 1.0, 0.0,
    0.0, 0.0, 0.0, 1.0,
];
var rst_eye: f32[3] = [0.0, 0.0, 0.0];
var rst_fog_near: f32 = 24.0;
var rst_fog_far: f32 = 96.0;
var rst_sky: f32[3] = [0.55, 0.70, 0.92];

var rst_tris: i64 = 0;
var rst_tris_drawn: i64 = 0;
var rst_tris_clipped: i64 = 0;
var rst_pixels: i64 = 0;          // pixels the geometry covered
var rst_fragments: i64 = 0;       // pixels tested
// Fragments that passed the depth test, i.e. were actually shaded. Overdraw is this per
// covered pixel, and it is a *deterministic* number: unlike a frame time it does not
// depend on the machine, so it can be a gate on a software rasteriser that says nothing
// about a phone GPU.
var rst_shaded: i64 = 0;
// Pixels the geometry reached *at all*, counted once however many times they are written.
// Overdraw is shaded fragments per covered pixel, so the denominator has to be distinct
// pixels; `rst_pixels` counts writes and is therefore equal to `rst_shaded` by
// construction, which makes shaded/rst_pixels always exactly 1000 and means nothing.
var rst_unique: i64 = 0;
// One byte per pixel saying whether it has been written at all. A mask rather than a
// "depth still 1.0" test because blended fragments do not write depth, so they would
// otherwise be counted as covering the pixel again on every pass.
var rst_covered: u8[>..] = [];
var rst_discarded: i64 = 0;       // pixels an alpha test threw away
var rst_max_depth: f32 = 0.0;

fn rst_mat4_identity(out: f32[16]&) {
    for i in 16 { out[i] = if i % 5 == 0 { 1.0 } else { 0.0 }; }
}

fn rst_mat4_mul(out: f32[16]&, a: f32[16], b: f32[16]) {
    for c in 4 {
        for r in 4 {
            var s: f32 = 0.0;
            for k in 4 { s += a[k * 4 + r] * b[c * 4 + k]; }
            out[c * 4 + r] = s;
        }
    }
}

// Column-major, right handed, looking down -Z, the same convention as the C side.
fn rst_look_at(out: f32[16]&, eye: f32[3], target: f32[3], up: f32[3]) {
    var f = [target[0] - eye[0], target[1] - eye[1], target[2] - eye[2]];
    let fl = (f[0] * f[0] + f[1] * f[1] + f[2] * f[2]) as f32;
    if fl <= 0.0 { rst_mat4_identity(out); return; }
    var inv: f32 = 1.0;
    var mag: f32 = 0.0;
    // sqrt without a builtin: Newton from a float guess.
    mag = fl;
    var guess: f32 = if mag > 0.0 { mag } else { 1.0 };
    for i in 24 { guess = 0.5 * (guess + mag / guess); }
    if guess > 0.0 { inv = 1.0 / guess; }
    f[0] *= inv; f[1] *= inv; f[2] *= inv;
    var s = [f[1] * up[2] - f[2] * up[1], f[2] * up[0] - f[0] * up[2], f[0] * up[1] - f[1] * up[0]];
    var sm: f32 = s[0] * s[0] + s[1] * s[1] + s[2] * s[2];
    var sg: f32 = if sm > 0.0 { sm } else { 1.0 };
    for i in 24 { sg = 0.5 * (sg + sm / sg); }
    if sg > 0.0 { s[0] *= 1.0 / sg; s[1] *= 1.0 / sg; s[2] *= 1.0 / sg; }
    var u = [s[1] * f[2] - s[2] * f[1], s[2] * f[0] - s[0] * f[2], s[0] * f[1] - s[1] * f[0]];
    out[0] = s[0]; out[1] = u[0]; out[2] = -f[0]; out[3] = 0.0;
    out[4] = s[1]; out[5] = u[1]; out[6] = -f[1]; out[7] = 0.0;
    out[8] = s[2]; out[9] = u[2]; out[10] = -f[2]; out[11] = 0.0;
    out[12] = -(s[0] * eye[0] + s[1] * eye[1] + s[2] * eye[2]);
    out[13] = -(u[0] * eye[0] + u[1] * eye[1] + u[2] * eye[2]);
    out[14] = (f[0] * eye[0] + f[1] * eye[1] + f[2] * eye[2]);
    out[15] = 1.0;
}

fn rst_perspective(out: f32[16]&, fovy_rad: f32, aspect: f32, near: f32, far: f32) {
    for i in 16 { out[i] = 0.0; }
    // tan(fovy/2) by a short series-free route: tan = sin/cos, both from a Taylor
    // expansion good to 1e-6 over the angles a camera uses.
    let x = fovy_rad * 0.5;
    var s: f32 = x;
    var term: f32 = x;
    for i in 4 {
        term = -term * x * x / (((i * 2 + 2) * (i * 2 + 3)) as f32);
        s += term;
    }
    var c: f32 = 1.0;
    term = 1.0;
    for i in 4 {
        term = -term * x * x / (((i * 2 + 1) * (i * 2 + 2)) as f32);
        c += term;
    }
    let t = s / c;
    out[0] = (1.0 as f32) / (aspect * t);
    out[5] = (1.0 as f32) / t;
    out[10] = -(far + near) / (far - near);
    out[11] = -1.0;
    out[14] = -(2.0 * far * near) / (far - near);
}

fn rst_begin(w: i64, h: i64) {
    rst_w = w;
    rst_h = h;
    rst_color = [];
    for i in w * h * 4 { rst_color.push(0); }
    rst_depth = [];
    for i in w * h { rst_depth.push(1.0); }
    rst_tris = 0; rst_tris_drawn = 0; rst_tris_clipped = 0;
    rst_pixels = 0; rst_fragments = 0; rst_discarded = 0; rst_max_depth = 0.0;
    rst_shaded = 0;
    rst_unique = 0;
    rst_covered = [];
    for i in w * h { rst_covered.push(0); }
}

fn rst_clear(r: f32, g: f32, b: f32) {
    rst_sky[0] = r; rst_sky[1] = g; rst_sky[2] = b;
    let ri = (r * 255.0) as i64;
    let gi = (g * 255.0) as i64;
    let bi = (b * 255.0) as i64;
    for i in rst_w * rst_h {
        rst_color[i * 4] = ri as u8;
        rst_color[i * 4 + 1] = gi as u8;
        rst_color[i * 4 + 2] = bi as u8;
        rst_color[i * 4 + 3] = 255;
        rst_depth[i] = 1.0;
    }
}

fn rst_camera(eye: f32[3], target: f32[3], up: f32[3], fovy_deg: f32, near: f32, far: f32) {
    rst_eye[0] = eye[0]; rst_eye[1] = eye[1]; rst_eye[2] = eye[2];
    rst_look_at(rst_view, eye, target, up);
    let aspect = (rst_w as f32) / (rst_h as f32);
    rst_perspective(rst_proj, fovy_deg * (3.14159265 / 180.0), aspect, near, far);
}

fn rst_set_fog(near: f32, far: f32) {
    rst_fog_near = near;
    rst_fog_far = far;
}

fn rst_color_at(x: i64, y: i64) -> i64 {
    if x < 0 || y < 0 || x >= rst_w || y >= rst_h { return -1; }
    let i = (y * rst_w + x) * 4;
    return ((rst_color[i] as i64) << 16) | ((rst_color[i + 1] as i64) << 8) | (rst_color[i + 2] as i64);
}

fn rst_pixels_covered() -> i64 { return rst_pixels; }
fn rst_fragments_shaded() -> i64 { return rst_shaded; }
// Overdraw in permille: shaded fragments per covered pixel, times 1000. Integer arithmetic
// on purpose -- a ratio printed as a float is a number two builds can disagree about in the
// last digit, and this is meant to be a gate. 1000 is "every pixel shaded exactly once".
fn rst_overdraw_permille() -> i64 {
    if rst_unique <= 0 { return 0; }
    return (rst_shaded * 1000) / rst_unique;
}
fn rst_pixels_covered_once() -> i64 { return rst_unique; }
fn rst_triangles_drawn() -> i64 { return rst_tris_drawn; }
fn rst_triangles_clipped() -> i64 { return rst_tris_clipped; }
fn rst_discarded() -> i64 { return rst_discarded; }
fn rst_width() -> i64 { return rst_w; }
fn rst_height() -> i64 { return rst_h; }

// PPM P6, because a picture with no encoder between it and the pixels is the one you
// can trust when the question is "did the renderer draw that".
fn rst_write_ppm(path: const u8[:]) -> bool {
    var out: u8[>..] = [];
    out.append("P6\n");
    format_int(out, rst_w);
    out.push(' ');
    format_int(out, rst_h);
    out.append("\n255\n");
    for i in rst_w * rst_h {
        out.push(rst_color[i * 4]);
        out.push(rst_color[i * 4 + 1]);
        out.push(rst_color[i * 4 + 2]);
    }
    return write_file(path, out);
}

fn format_int(out: u8[>..]&, v: i64) {
    if v == 0 { out.push('0'); return; }
    var digits: u8[>..] = [];
    var x = v;
    while x > 0 {
        digits.push((48 + (x % 10)) as u8);
        x = x / 10;
    }
    var i = digits.len;
    while i > 0 { i -= 1; out.push(digits[i]); }
}

// --- the rasterizer itself ----------------------------------------------

// Draws indices [start, start+count) from `indices` against `verts`, sampling
// `atlas` (aw x ah RGBA). `blend` selects the translucent pass: alpha blend, no depth
// write. `alpha_test` discards anything under 0.5, which is what a leaf or a plant
// needs and what a solid block passes trivially.
fn rst_draw(start: i64, count: i64, verts: Vertex[>..]&, indices: u32[>..]&,
            atlas: const u8[:], aw: i64, ah: i64, blend: bool, alpha_test: bool) {
    var i: i64 = start;
    let end = start + count;
    while i + 2 < end {
        rst_triangle(indices[i], indices[i + 1], indices[i + 2], verts, atlas, aw, ah,
                     blend, alpha_test);
        i += 3;
    }
}

fn rst_triangle(i0: u32, i1: u32, i2: u32, verts: Vertex[>..]&, atlas: const u8[:],
                aw: i64, ah: i64, blend: bool, alpha_test: bool) {
    rst_tris += 1;
    let a = verts[i0 as i64];
    let b = verts[i1 as i64];
    let c = verts[i2 as i64];
    var sx: f32[3] = [0.0, 0.0, 0.0];
    var sy: f32[3] = [0.0, 0.0, 0.0];
    var sz: f32[3] = [0.0, 0.0, 0.0];
    var inv_w: f32[3] = [0.0, 0.0, 0.0];
    var uu: f32[3] = [0.0, 0.0, 0.0];
    var vv: f32[3] = [0.0, 0.0, 0.0];
    var dist: f32[3] = [0.0, 0.0, 0.0];
    var cr: f32[3] = [0.0, 0.0, 0.0];
    var cg: f32[3] = [0.0, 0.0, 0.0];
    var cb: f32[3] = [0.0, 0.0, 0.0];
    var p = [a.x, a.y, a.z, a.u, a.v, a.r, a.g, a.b];
    var q = [b.x, b.y, b.z, b.u, b.v, b.r, b.g, b.b];
    var r = [c.x, c.y, c.z, c.u, c.v, c.r, c.g, c.b];
    for k in 3 {
        let px = if k == 0 { a.x } else if k == 1 { b.x } else { c.x };
        let py = if k == 0 { a.y } else if k == 1 { b.y } else { c.y };
        let pz = if k == 0 { a.z } else if k == 1 { b.z } else { c.z };
        let tu = if k == 0 { a.u } else if k == 1 { b.u } else { c.u };
        let tv = if k == 0 { a.v } else if k == 1 { b.v } else { c.v };
        let tr = if k == 0 { a.r } else if k == 1 { b.r } else { c.r };
        let tg = if k == 0 { a.g } else if k == 1 { b.g } else { c.g };
        let tb = if k == 0 { a.b } else if k == 1 { b.b } else { c.b };
        // view * position
        let vx = rst_view[0] * px + rst_view[4] * py + rst_view[8] * pz + rst_view[12];
        let vy = rst_view[1] * px + rst_view[5] * py + rst_view[9] * pz + rst_view[13];
        let vz = rst_view[2] * px + rst_view[6] * py + rst_view[10] * pz + rst_view[14];
        // proj * view * position
        let cx = rst_proj[0] * vx + rst_proj[4] * vy + rst_proj[8] * vz + rst_proj[12];
        let cy = rst_proj[1] * vx + rst_proj[5] * vy + rst_proj[9] * vz + rst_proj[13];
        let cw = rst_proj[3] * vx + rst_proj[7] * vy + rst_proj[11] * vz + rst_proj[15];
        if cw <= 0.0001 {
            rst_tris_clipped += 1;
            return;
        }
        let iw = 1.0 / cw;
        sx[k] = (cx * iw * 0.5 + 0.5) * (rst_w as f32);
        sy[k] = (0.5 - cy * iw * 0.5) * (rst_h as f32);
        sz[k] = 1.0 - iw * 0.5;   // nearer is smaller; monotonic in w
        inv_w[k] = iw;
        uu[k] = tu * iw;
        vv[k] = tv * iw;
        cr[k] = tr; cg[k] = tg; cb[k] = tb;
        let dx = px - rst_eye[0];
        let dy = py - rst_eye[1];
        let dz = pz - rst_eye[2];
        dist[k] = dx * dx + dy * dy + dz * dz;
        let unused = p;
        let unused2 = q;
        let unused3 = r;
    }
    // Degenerate triangles cover nothing and would divide by zero.
    let area = (sx[1] - sx[0]) * (sy[2] - sy[0]) - (sx[2] - sx[0]) * (sy[1] - sy[0]);
    if area > -0.0001 && area < 0.0001 { return; }
    rst_tris_drawn += 1;
    var minx = sx[0]; var maxx = sx[0]; var miny = sy[0]; var maxy = sy[0];
    for k in 3 {
        if sx[k] < minx { minx = sx[k]; }
        if sx[k] > maxx { maxx = sx[k]; }
        if sy[k] < miny { miny = sy[k]; }
        if sy[k] > maxy { maxy = sy[k]; }
    }
    var x0 = minx as i64; if x0 < 0 { x0 = 0; }
    var y0 = miny as i64; if y0 < 0 { y0 = 0; }
    var x1 = (maxx as i64) + 1; if x1 > rst_w { x1 = rst_w; }
    var y1 = (maxy as i64) + 1; if y1 > rst_h { y1 = rst_h; }
    let inv_area = 1.0 / area;
    for py_i in y0..y1 {
        for px_i in x0..x1 {
            let fx = (px_i as f32) + 0.5;
            let fy = (py_i as f32) + 0.5;
            var w0 = ((sx[1] - fx) * (sy[2] - fy) - (sx[2] - fx) * (sy[1] - fy)) * inv_area;
            var w1 = ((sx[2] - fx) * (sy[0] - fy) - (sx[0] - fx) * (sy[2] - fy)) * inv_area;
            var w2 = 1.0 - w0 - w1;
            if w0 < 0.0 || w1 < 0.0 || w2 < 0.0 { continue; }
            rst_fragments += 1;
            let z = w0 * sz[0] + w1 * sz[1] + w2 * sz[2];
            let di = py_i * rst_w + px_i;
            if z < 0.0 || z >= rst_depth[di] { continue; }
            let iw = w0 * inv_w[0] + w1 * inv_w[1] + w2 * inv_w[2];
            if iw <= 0.0 { continue; }
            let u = (w0 * uu[0] + w1 * uu[1] + w2 * uu[2]) / iw;
            let v = (w0 * vv[0] + w1 * vv[1] + w2 * vv[2]) / iw;
            var tx = (u * (aw as f32)) as i64;
            var ty = (v * (ah as f32)) as i64;
            if tx < 0 { tx = 0; }
            if ty < 0 { ty = 0; }
            if tx >= aw { tx = aw - 1; }
            if ty >= ah { ty = ah - 1; }
            let ti = (ty * aw + tx) * 4;
            let tr = atlas[ti];
            let tg = atlas[ti + 1];
            let tb = atlas[ti + 2];
            let ta = atlas[ti + 3];
            if alpha_test && ta < 128 {
                rst_discarded += 1;
                continue;
            }
            let vr = w0 * cr[0] + w1 * cr[1] + w2 * cr[2];
            let vg = w0 * cg[0] + w1 * cg[1] + w2 * cg[2];
            let vb = w0 * cb[0] + w1 * cb[1] + w2 * cb[2];
            // Fog: distance squared is interpolated linearly (it is a monotonic
            // stand-in for the GPU's per-pixel length, and the picture says whether
            // that is good enough).
            let d2 = w0 * dist[0] + w1 * dist[1] + w2 * dist[2];
            var d = if d2 > 0.0 { d2 } else { 0.0 };
            if d > 0.0 { for s in 20 { d = 0.5 * (d + d2 / d); } }
            var fog = (d - rst_fog_near) / (rst_fog_far - rst_fog_near);
            if fog < 0.0 { fog = 0.0; }
            if fog > 1.0 { fog = 1.0; }
            var sr = (tr as f32) * vr / 255.0;
            var sg = (tg as f32) * vg / 255.0;
            var sb = (tb as f32) * vb / 255.0;
            if sr > 1.0 { sr = 1.0; }
            if sg > 1.0 { sg = 1.0; }
            if sb > 1.0 { sb = 1.0; }
            sr = sr + (rst_sky[0] - sr) * fog;
            sg = sg + (rst_sky[1] - sg) * fog;
            sb = sb + (rst_sky[2] - sb) * fog;
            let ci = di * 4;
            if blend {
                let alpha = (ta as f32) / 255.0;
                let dr = (rst_color[ci] as f32) / 255.0;
                let dg = (rst_color[ci + 1] as f32) / 255.0;
                let db = (rst_color[ci + 2] as f32) / 255.0;
                rst_color[ci] = (((sr * alpha + dr * (1.0 - alpha)) * 255.0) as i64) as u8;
                rst_color[ci + 1] = (((sg * alpha + dg * (1.0 - alpha)) * 255.0) as i64) as u8;
                rst_color[ci + 2] = (((sb * alpha + db * (1.0 - alpha)) * 255.0) as i64) as u8;
                rst_pixels += 1;
                rst_shaded += 1;
                if rst_covered[di] == 0 { rst_covered[di] = 1; rst_unique += 1; }
            } else {
                rst_color[ci] = ((sr * 255.0) as i64) as u8;
                rst_color[ci + 1] = ((sg * 255.0) as i64) as u8;
                rst_color[ci + 2] = ((sb * 255.0) as i64) as u8;
                rst_depth[di] = z;
                rst_pixels += 1;
                rst_shaded += 1;
                if rst_covered[di] == 0 { rst_covered[di] = 1; rst_unique += 1; }
                if z > rst_max_depth { rst_max_depth = z; }
            }
        }
    }
}
