//! Chimes and break music, synthesized by the app itself (no audio files shipped).
//! Ported from the `Synth` class of the Windows edition (SalamatYar.ps1).

use std::f64::consts::PI;

pub const SR: u32 = 32000;
const SRF: f64 = SR as f64;

fn hz(midi: f64) -> f64 {
    440.0 * 2f64.powf((midi - 69.0) / 12.0)
}

fn put(b: &mut [f32], k: usize, v: f64, wrap: bool) -> bool {
    let n = b.len();
    if k >= n {
        if !wrap {
            return false;
        }
        b[k % n] += v as f32;
    } else {
        b[k] += v as f32;
    }
    true
}

fn bell(b: &mut [f32], start: f64, midi: f64, amp: f64, decay: f64, wrap: bool) {
    let f = hz(midi);
    let s0 = (start * SRF) as usize;
    let len = (SRF * (7.0 / decay).min(6.0)) as usize;
    for i in 0..len {
        let t = i as f64 / SRF;
        let e = (t / 0.006).min(1.0) * (-t * decay).exp();
        let v = (2.0 * PI * f * t).sin()
            + 0.35 * (-t * decay).exp() * (4.0 * PI * f * t).sin()
            + 0.12 * (-2.0 * t * decay).exp() * (6.0 * PI * f * t).sin();
        if !put(b, s0 + i, amp * e * v, wrap) {
            break;
        }
    }
}

fn pad(b: &mut [f32], start: f64, midi: f64, dur: f64, amp: f64, wrap: bool) {
    let f = hz(midi);
    let s0 = (start * SRF) as usize;
    let (a, r) = (1.6, 2.4);
    let len = ((dur + r) * SRF) as usize;
    for i in 0..len {
        let t = i as f64 / SRF;
        let mut e = if t < a {
            t / a
        } else if t < dur {
            1.0
        } else {
            (1.0 - (t - dur) / r).max(0.0)
        };
        e = e * e * (3.0 - 2.0 * e);
        let v = (2.0 * PI * f * t).sin()
            + 0.6 * (2.0 * PI * f * 1.004 * t).sin()
            + 0.6 * (2.0 * PI * f * 0.996 * t).sin()
            + 0.22 * (4.0 * PI * f * t).sin() * (0.5 + 0.5 * (2.0 * PI * 0.13 * t).sin());
        if !put(b, s0 + i, amp * e * v, wrap) {
            break;
        }
    }
}

fn kick(b: &mut [f32], start: f64, amp: f64, wrap: bool) {
    let s0 = (start * SRF) as usize;
    let len = (0.24 * SRF) as usize;
    let mut ph = 0.0;
    for i in 0..len {
        let t = i as f64 / SRF;
        let f = 48.0 + 95.0 * (-t * 32.0).exp();
        ph += 2.0 * PI * f / SRF;
        let e = (t / 0.003).min(1.0) * (-t * 17.0).exp();
        if !put(b, s0 + i, amp * e * f64::sin(ph), wrap) {
            break;
        }
    }
}

/// Small deterministic noise source, so the built-in track is the same on every run.
struct Noise(u32);
impl Noise {
    fn next(&mut self) -> f64 {
        self.0 = self.0.wrapping_mul(1664525).wrapping_add(1013904223);
        (self.0 >> 8) as f64 / 16_777_216.0
    }
}

fn hat(b: &mut [f32], start: f64, amp: f64, rnd: &mut Noise, wrap: bool) {
    let s0 = (start * SRF) as usize;
    let len = (0.045 * SRF) as usize;
    let mut prev = 0.0;
    for i in 0..len {
        let t = i as f64 / SRF;
        let x = rnd.next() * 2.0 - 1.0;
        let v = (x - prev) * 0.5;
        prev = x;
        if !put(b, s0 + i, amp * (-t * 85.0).exp() * v, wrap) {
            break;
        }
    }
}

fn echo(b: &[f32], delay: f64, fb: f64, wrap: bool) -> Vec<f32> {
    let n = b.len();
    let d = (delay * SRF) as usize;
    let mut o = vec![0f32; n];
    let passes = if wrap { 2 } else { 1 };
    for p in 0..passes {
        for i in 0..n {
            let prev = if i >= d {
                o[i - d]
            } else if wrap && p > 0 {
                o[i + n - d]
            } else {
                0.0
            };
            o[i] = b[i] + (fb as f32) * prev;
        }
    }
    o
}

fn finish(mut b: Vec<f32>, peak: f32, fade_out: f64) -> Vec<f32> {
    let n = b.len();
    let mx = b.iter().fold(1e-9f32, |m, v| m.max(v.abs()));
    let g = peak / mx;
    let fo = (fade_out * SRF) as usize;
    for (i, v) in b.iter_mut().enumerate() {
        *v *= g;
        if fo > 0 && i + fo > n {
            *v *= (n - i) as f32 / fo as f32;
        }
    }
    b
}

/// Calm track for eye breaks (48 seconds, loops seamlessly).
pub fn calm() -> Vec<f32> {
    let cd = 6.0;
    let roots = [48, 45, 41, 43, 40, 45, 38, 43];
    let tones = [
        [60, 64, 67, 71],
        [57, 60, 64, 67],
        [53, 57, 60, 64],
        [55, 59, 62, 64],
        [52, 55, 59, 62],
        [57, 60, 64, 67],
        [57, 60, 62, 65],
        [55, 60, 62, 67],
    ];
    let pat = [0, 2, 1, 3, 2, 3, 1, 2];
    let mut b = vec![0f32; (cd * roots.len() as f64 * SRF) as usize];
    for c in 0..roots.len() {
        let t0 = c as f64 * cd;
        pad(&mut b, t0, roots[c] as f64, cd, 0.50, true);
        for k in 0..4 {
            pad(&mut b, t0, tones[c][k] as f64, cd, 0.20, true);
        }
        for k in 0..8 {
            bell(&mut b, t0 + k as f64 * 0.75, (tones[c][pat[k]] + 12) as f64, 0.17, 2.0, true);
        }
        bell(&mut b, t0, (tones[c][3] + 24) as f64, 0.07, 1.2, true);
    }
    finish(echo(&b, 0.5625, 0.38, true), 0.72, 0.0)
}

/// Livelier track for movement breaks (38.4 seconds, loops seamlessly).
pub fn active() -> Vec<f32> {
    let beat = 0.6;
    let roots = [48, 43, 45, 41, 48, 43, 41, 43];
    let tr = [
        [60, 64, 67],
        [59, 62, 67],
        [60, 64, 69],
        [60, 65, 69],
        [60, 64, 67],
        [59, 62, 67],
        [60, 65, 69],
        [59, 62, 67],
    ];
    let pat = [0, 1, 2, 1, 0, 2, 1, 2];
    let mut b = vec![0f32; (beat * 8.0 * roots.len() as f64 * SRF) as usize];
    let mut rnd = Noise(7);
    for c in 0..roots.len() {
        let t0 = c as f64 * 8.0 * beat;
        for k in 0..3 {
            pad(&mut b, t0, tr[c][k] as f64, 8.0 * beat - 1.0, 0.10, true);
        }
        for bt in 0..8 {
            let tb = t0 + bt as f64 * beat;
            kick(&mut b, tb, 0.50, true);
            if bt % 2 == 0 {
                bell(&mut b, tb, roots[c] as f64, 0.50, 3.0, true);
            }
            if bt % 4 == 3 {
                bell(&mut b, tb + beat / 2.0, (roots[c] + 7) as f64, 0.28, 4.0, true);
            }
            for e in 0..2 {
                let note = tr[c][pat[(bt * 2 + e) % 8]] + 12;
                bell(&mut b, tb + e as f64 * beat / 2.0, note as f64, 0.16, 5.0, true);
            }
            hat(&mut b, tb + beat / 2.0, 0.05, &mut rnd, true);
        }
        bell(&mut b, t0, (tr[c][2] + 24) as f64, 0.10, 2.0, true);
        bell(&mut b, t0 + 4.0 * beat, (tr[c][1] + 24) as f64, 0.10, 2.0, true);
    }
    finish(echo(&b, 0.45, 0.25, true), 0.72, 0.0)
}

/// Chimes: 0 = break starts, 1 = break ends, 2 = message.
pub fn chime(kind: u8) -> Vec<f32> {
    let mut b;
    match kind {
        0 => {
            b = vec![0f32; (2.4 * SRF) as usize];
            bell(&mut b, 0.00, 76.0, 0.6, 3.2, false);
            bell(&mut b, 0.16, 79.0, 0.6, 3.2, false);
            bell(&mut b, 0.32, 84.0, 0.7, 2.8, false);
        }
        1 => {
            b = vec![0f32; (2.8 * SRF) as usize];
            bell(&mut b, 0.00, 72.0, 0.5, 3.5, false);
            bell(&mut b, 0.11, 76.0, 0.5, 3.5, false);
            bell(&mut b, 0.22, 79.0, 0.5, 3.5, false);
            bell(&mut b, 0.33, 84.0, 0.6, 3.0, false);
            bell(&mut b, 0.55, 88.0, 0.45, 2.6, false);
        }
        _ => {
            b = vec![0f32; (1.6 * SRF) as usize];
            bell(&mut b, 0.00, 81.0, 0.6, 4.5, false);
            bell(&mut b, 0.10, 88.0, 0.5, 4.5, false);
        }
    }
    finish(echo(&b, 0.21, 0.22, false), 0.75, 0.08)
}
