//! Timers, statistics and break logic. No windows or sound here: every side effect is
//! returned as an `Effect` and carried out by the caller after the engine lock is released.

use crate::audio::{Fx, Slot};
use chrono::Local;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::PathBuf;
use std::time::SystemTime;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");
pub const LANGS: [&str; 6] = ["fa", "en", "ar", "ru", "zh", "sv"];

// ---------- texts ----------

pub struct Lang {
    order: Vec<String>,
    strings: HashMap<String, Vec<String>>,
}

impl Lang {
    /// lang.json is shared with the Windows edition; lang-extra.json overrides the few
    /// texts that mention Windows.
    pub fn load() -> Lang {
        let mut lang = Lang { order: Vec::new(), strings: HashMap::new() };
        for src in [include_str!("../../../lang.json"), include_str!("../../lang-extra.json")] {
            let v: Value = serde_json::from_str(src.trim_start_matches('\u{feff}')).expect("language file is damaged");
            if lang.order.is_empty() {
                lang.order = serde_json::from_value(v["_order"].clone()).expect("language order");
            }
            let part: HashMap<String, Vec<String>> = serde_json::from_value(v["strings"].clone()).expect("language strings");
            lang.strings.extend(part);
        }
        lang
    }

    pub fn t(&self, key: &str, code: &str) -> String {
        let i = self.order.iter().position(|c| c == code).unwrap_or(1);
        match self.strings.get(key).and_then(|v| v.get(i)) {
            Some(s) => s.clone(),
            None => format!("[{key}]"),
        }
    }

    /// Number of entries in a numbered pool (eyeTip1, eyeTip2, ...).
    pub fn pool_len(&self, prefix: &str) -> usize {
        let mut n = 0;
        while self.strings.contains_key(&format!("{prefix}{}", n + 1)) {
            n += 1;
        }
        n
    }

    pub fn to_json(&self) -> Value {
        json!({ "order": self.order, "strings": self.strings })
    }
}

// ---------- settings and statistics ----------

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(default, rename_all = "camelCase")]
pub struct Cfg {
    pub eye_interval: u32,
    pub eye_duration: u32,
    pub move_interval: u32,
    pub move_duration: u32,
    pub water_interval: u32,
    pub idle_reset: u32,
    pub idle_detect: bool,
    pub sound: bool,
    pub music: bool,
    pub volume: u32,
    pub music_eye: String,
    pub music_move: String,
    pub theme: String,
    pub break_mode: String,
    pub lang: String,
}

// Defaults follow published guidance (see the "Health guide" page of the app).
impl Default for Cfg {
    fn default() -> Cfg {
        Cfg {
            eye_interval: 20,
            eye_duration: 20,
            move_interval: 30,
            move_duration: 120,
            water_interval: 60,
            idle_reset: 5,
            idle_detect: true,
            sound: true,
            music: true,
            volume: 60,
            music_eye: String::new(),
            music_move: String::new(),
            theme: "dark".into(),
            break_mode: "full".into(),
            lang: String::new(),
        }
    }
}

impl Cfg {
    fn sanitize(&mut self) {
        self.eye_interval = self.eye_interval.clamp(10, 40);
        self.eye_duration = self.eye_duration.clamp(20, 60);
        self.move_interval = self.move_interval.clamp(20, 90);
        self.move_duration = self.move_duration.clamp(60, 600);
        self.water_interval = self.water_interval.clamp(30, 120);
        self.idle_reset = self.idle_reset.clamp(3, 15);
        self.volume = self.volume.min(100);
        if !["dark", "light", "auto"].contains(&self.theme.as_str()) {
            self.theme = "dark".into();
        }
        if !["full", "window", "tray"].contains(&self.break_mode.as_str()) {
            self.break_mode = "full".into();
        }
        if !LANGS.contains(&self.lang.as_str()) {
            self.lang = detect_lang();
        }
    }
}

fn detect_lang() -> String {
    let loc = sys_locale::get_locale().unwrap_or_default().to_lowercase();
    let two: String = loc.chars().take(2).collect();
    if LANGS.contains(&two.as_str()) {
        two
    } else {
        "en".into()
    }
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
#[serde(default)]
pub struct Stats {
    pub date: String,
    pub work: f64,
    pub eye: u32,
    #[serde(rename = "move")]
    pub mv: u32,
    pub water: u32,
    pub skipped: u32,
}

fn today() -> String {
    Local::now().format("%Y-%m-%d").to_string()
}

// ---------- side effects ----------

#[derive(Debug)]
pub enum Effect {
    /// Show the break in the given mode: "full" or "window".
    OpenBreak(String),
    CloseBreak,
    OpenToast,
    CloseToast,
    Fx(Fx, f32),
    Music(Slot, Option<PathBuf>, f32),
    StopMusic,
    MusicVol(f32),
    Notify(String, String),
    /// Texts of the tray menu must be refreshed (language changed).
    TrayMenu,
}

pub struct Break {
    pub kind: &'static str,
    total: f64,
    left: f64,
    count: usize,
    tip_acc: f64,
    mode: String,
    preview: bool,
    tips: Vec<usize>,
}

pub struct Engine {
    pub cfg: Cfg,
    pub stats: Stats,
    pub lang: Lang,
    eye: f64,
    mv: f64,
    water: f64,
    pub paused: bool,
    away: bool,
    brk: Option<Break>,
    toast: Option<(f64, usize)>,
    last: SystemTime,
    save_acc: f64,
    dirty: bool,
    music_on: bool,
    sample_left: f64,
    decks: HashMap<&'static str, Vec<usize>>,
    dir: PathBuf,
}

impl Engine {
    pub fn new(dir: PathBuf) -> Engine {
        let _ = std::fs::create_dir_all(&dir);
        let read = |name: &str| std::fs::read_to_string(dir.join(name)).ok();
        let mut cfg: Cfg = read("settings.json").and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default();
        let first_run = cfg.lang.is_empty();
        cfg.sanitize();
        let mut stats: Stats = read("stats.json").and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default();
        if stats.date != today() {
            stats = Stats { date: today(), ..Stats::default() };
        }
        let e = Engine {
            cfg,
            stats,
            lang: Lang::load(),
            eye: 0.0,
            mv: 0.0,
            water: 0.0,
            paused: false,
            away: false,
            brk: None,
            toast: None,
            last: SystemTime::now(),
            save_acc: 0.0,
            dirty: false,
            music_on: false,
            sample_left: 0.0,
            decks: HashMap::new(),
            dir,
        };
        if first_run {
            e.save_cfg();
        }
        e
    }

    pub fn t(&self, key: &str) -> String {
        self.lang.t(key, &self.cfg.lang)
    }

    fn save_cfg(&self) {
        if let Ok(s) = serde_json::to_string_pretty(&self.cfg) {
            let _ = std::fs::write(self.dir.join("settings.json"), s);
        }
    }

    fn save_stats(&self) {
        if let Ok(s) = serde_json::to_string_pretty(&self.stats) {
            let _ = std::fs::write(self.dir.join("stats.json"), s);
        }
    }

    pub fn save_all(&self) {
        self.save_cfg();
        self.save_stats();
    }

    fn vol(&self) -> f32 {
        self.cfg.volume as f32 / 100.0
    }

    fn music_effect(&mut self, slot: Slot) -> Effect {
        let p = match slot {
            Slot::Calm => &self.cfg.music_eye,
            Slot::Active => &self.cfg.music_move,
        };
        let custom = if p.is_empty() { None } else { Some(PathBuf::from(p)).filter(|x| x.is_file()) };
        self.music_on = true;
        Effect::Music(slot, custom, self.vol() * 0.85)
    }

    fn stop_music(&mut self, fx: &mut Vec<Effect>) {
        if self.music_on {
            self.music_on = false;
            self.sample_left = 0.0;
            fx.push(Effect::StopMusic);
        }
    }

    /// Activities come in shuffled order without repeats, so the whole set is seen once
    /// before anything shows again. Returns 1-based indexes into the numbered pool.
    fn next_tips(&mut self, name: &'static str, count: usize) -> Vec<usize> {
        let len = self.lang.pool_len(&format!("{name}Tip"));
        let mut out = Vec::new();
        if len == 0 {
            return out;
        }
        let deck = self.decks.entry(name).or_default();
        for _ in 0..count {
            if deck.is_empty() {
                *deck = (1..=len).collect();
                fastrand::shuffle(deck);
            }
            out.push(deck.remove(0));
        }
        out
    }

    fn tips_text(&self, name: &str, tips: &[usize]) -> String {
        let texts: Vec<String> = tips.iter().map(|i| self.t(&format!("{name}Tip{i}"))).collect();
        if texts.len() > 1 {
            texts.iter().map(|s| format!("• {s}")).collect::<Vec<_>>().join("\n")
        } else {
            texts.into_iter().next().unwrap_or_default()
        }
    }

    pub fn start_break(&mut self, kind: &str, preview: bool) -> Vec<Effect> {
        let mut fx = Vec::new();
        if self.brk.is_some() {
            return fx;
        }
        if self.toast.take().is_some() {
            fx.push(Effect::CloseToast);
        }
        let (kind, mut dur, slot): (&'static str, f64, Slot) = if kind == "eye" {
            ("eye", self.cfg.eye_duration as f64, Slot::Calm)
        } else {
            ("move", self.cfg.move_duration as f64, Slot::Active)
        };
        // A short break reminds of one activity, a longer one of two.
        let mut count = if dur < 30.0 { 1 } else { 2 };
        // Settings preview: a few seconds, with no effect on statistics or timers.
        if preview {
            dur = 8.0;
            count = 2;
        }
        let mode = self.cfg.break_mode.clone();
        let tips = self.next_tips(kind, count);
        if mode == "tray" {
            // Only a notification; the break is counted silently and its end is announced by a chime.
            let (title, instr) = if kind == "eye" { ("ovEyeTitle", "ovEyeInstr") } else { ("ovMoveTitle", "ovMoveInstr") };
            let body = format!("{}\n{}", self.t(instr), self.tips_text(kind, &tips));
            fx.push(Effect::Notify(self.t(title), body));
        } else {
            fx.push(Effect::OpenBreak(mode.clone()));
        }
        if self.cfg.sound {
            fx.push(Effect::Fx(Fx::Start, self.vol()));
        }
        self.sample_left = 0.0;
        if mode != "tray" && self.cfg.music {
            let m = self.music_effect(slot);
            fx.push(m);
        } else {
            self.stop_music(&mut fx);
        }
        self.brk = Some(Break { kind, total: dur, left: dur, count, tip_acc: 0.0, mode, preview, tips });
        fx
    }

    pub fn end_break(&mut self, how: &str) -> Vec<Effect> {
        let mut fx = Vec::new();
        let Some(b) = self.brk.take() else { return fx };
        if b.mode != "tray" {
            fx.push(Effect::CloseBreak);
        }
        self.stop_music(&mut fx);
        self.last = SystemTime::now();
        if b.preview {
            return fx;
        }
        if how == "later" {
            if b.kind == "eye" {
                self.eye = (self.cfg.eye_interval as f64 * 60.0 - 300.0).max(0.0);
            } else {
                self.mv = (self.cfg.move_interval as f64 * 60.0 - 300.0).max(0.0);
            }
        } else {
            if how == "done" {
                if b.kind == "eye" {
                    self.stats.eye += 1;
                } else {
                    self.stats.mv += 1;
                }
                if self.cfg.sound {
                    fx.push(Effect::Fx(Fx::End, self.vol()));
                }
            } else {
                self.stats.skipped += 1;
            }
            self.eye = 0.0;
            if b.kind == "move" {
                self.mv = 0.0;
            }
        }
        self.save_stats();
        fx
    }

    /// Shows a few seconds of a sample break in the display mode that was just chosen.
    pub fn preview_break(&mut self) -> Vec<Effect> {
        let mut fx = Vec::new();
        if self.brk.as_ref().is_some_and(|b| b.preview) {
            fx.extend(self.end_break("skip"));
        }
        fx.extend(self.start_break("move", true));
        fx
    }

    fn water_toast(&mut self) -> Vec<Effect> {
        let mut fx = Vec::new();
        let tip = self.next_tips("water", 1).first().copied().unwrap_or(1);
        if self.cfg.break_mode == "tray" {
            let body = format!("{}\n{}", self.t("toastWaterText"), self.t(&format!("waterTip{tip}")));
            fx.push(Effect::Notify(self.t("toastWaterTitle"), body));
        } else {
            if self.toast.is_some() {
                fx.push(Effect::CloseToast);
            }
            self.toast = Some((14.0, tip));
            fx.push(Effect::OpenToast);
        }
        if self.cfg.sound {
            fx.push(Effect::Fx(Fx::Notify, self.vol()));
        }
        fx
    }

    pub fn close_toast(&mut self) -> Vec<Effect> {
        if self.toast.take().is_some() {
            vec![Effect::CloseToast]
        } else {
            Vec::new()
        }
    }

    pub fn drink(&mut self) -> Vec<Effect> {
        self.stats.water += 1;
        self.water = 0.0;
        self.save_stats();
        self.close_toast()
    }

    pub fn toggle_pause(&mut self) {
        self.paused = !self.paused;
        self.last = SystemTime::now();
    }

    pub fn reset_timers(&mut self) {
        self.eye = 0.0;
        self.mv = 0.0;
        self.water = 0.0;
        self.last = SystemTime::now();
    }

    pub fn set_cfg(&mut self, mut new: Cfg) -> Vec<Effect> {
        let mut fx = Vec::new();
        new.sanitize();
        let old = std::mem::replace(&mut self.cfg, new);
        if old == self.cfg {
            return fx;
        }
        self.dirty = true;
        if old.lang != self.cfg.lang {
            fx.push(Effect::TrayMenu);
        }
        if !self.cfg.music {
            self.stop_music(&mut fx);
        } else if old.volume != self.cfg.volume && self.music_on {
            fx.push(Effect::MusicVol(self.vol() * 0.85));
        }
        fx
    }

    pub fn restore_defaults(&mut self) {
        let d = Cfg::default();
        self.cfg.eye_interval = d.eye_interval;
        self.cfg.eye_duration = d.eye_duration;
        self.cfg.move_interval = d.move_interval;
        self.cfg.move_duration = d.move_duration;
        self.cfg.water_interval = d.water_interval;
        self.cfg.idle_reset = d.idle_reset;
        self.dirty = true;
    }

    pub fn play_fx(&self, kind: Fx) -> Vec<Effect> {
        vec![Effect::Fx(kind, self.vol())]
    }

    /// Plays a few seconds of break music as a sample (settings preview).
    pub fn sample(&mut self, slot: Slot, seconds: f64) -> Vec<Effect> {
        if self.brk.is_some() {
            return Vec::new();
        }
        self.sample_left = seconds;
        vec![self.music_effect(slot)]
    }

    /// The "Play" button: starts a sample, or stops the music that is playing.
    pub fn toggle_sample(&mut self, slot: Slot) -> Vec<Effect> {
        if self.music_on {
            let mut fx = Vec::new();
            if self.brk.is_none() {
                self.stop_music(&mut fx);
            }
            fx
        } else {
            self.sample(slot, 15.0)
        }
    }

    pub fn set_music(&mut self, key: &str, path: String) -> Vec<Effect> {
        let has = !path.is_empty();
        let slot = if key == "musicEye" {
            self.cfg.music_eye = path;
            Slot::Calm
        } else {
            self.cfg.music_move = path;
            Slot::Active
        };
        self.dirty = true;
        self.sample(slot, if has { 10.0 } else { 8.0 })
    }

    /// One step of the clock. `idle` is the number of seconds without keyboard or mouse input.
    pub fn tick(&mut self, idle: f64) -> Vec<Effect> {
        let mut fx = Vec::new();
        let now = SystemTime::now();
        let dt = now.duration_since(self.last).map(|d| d.as_secs_f64()).unwrap_or(0.0);
        self.last = now;
        if self.stats.date != today() {
            self.stats = Stats { date: today(), ..Stats::default() };
        }
        if self.dirty {
            self.dirty = false;
            self.save_cfg();
        }
        if let Some((left, tip)) = self.toast {
            if left - dt <= 0.0 {
                fx.extend(self.close_toast());
            } else {
                self.toast = Some((left - dt, tip));
            }
        }
        if self.sample_left > 0.0 {
            self.sample_left -= dt;
            if self.sample_left <= 0.0 && self.brk.is_none() {
                self.stop_music(&mut fx);
            }
        }

        if self.brk.is_some() {
            let (left, rotate, kind, count) = {
                let b = self.brk.as_mut().unwrap();
                b.left -= dt.min(5.0);
                b.tip_acc += dt;
                let rotate = b.tip_acc >= 30.0 && b.left > 12.0 && b.mode != "tray";
                if rotate {
                    b.tip_acc = 0.0;
                }
                (b.left, rotate, b.kind, b.count)
            };
            if left <= 0.0 {
                fx.extend(self.end_break("done"));
            } else if rotate {
                let tips = self.next_tips(kind, count);
                if let Some(b) = self.brk.as_mut() {
                    b.tips = tips;
                }
            }
            return fx;
        }

        if !self.paused {
            let limit = self.cfg.idle_reset as f64 * 60.0;
            let idle = if self.cfg.idle_detect { idle } else { 0.0 };
            if dt >= limit || idle >= limit {
                // Time away from the computer counts as a break.
                self.eye = 0.0;
                self.mv = 0.0;
                self.away = idle >= limit;
            } else {
                self.away = false;
                self.eye += dt;
                self.mv += dt;
                self.water += dt;
                self.stats.work += dt;
            }
            if self.mv >= self.cfg.move_interval as f64 * 60.0 {
                fx.extend(self.start_break("move", false));
                return fx;
            }
            if self.eye >= self.cfg.eye_interval as f64 * 60.0 {
                fx.extend(self.start_break("eye", false));
                return fx;
            }
            if self.water >= self.cfg.water_interval as f64 * 60.0 {
                self.water = 0.0;
                fx.extend(self.water_toast());
            }
        }
        self.save_acc += dt;
        if self.save_acc >= 60.0 {
            self.save_acc = 0.0;
            self.save_stats();
        }
        fx
    }

    /// Self-check helper: makes the water reminder due on the next step.
    pub fn make_water_due(&mut self) {
        self.water = self.cfg.water_interval as f64 * 60.0;
    }

    /// Everything the windows need to draw themselves.
    pub fn snapshot(&self) -> Value {
        let brk = self.brk.as_ref().map(|b| {
            json!({ "kind": b.kind, "total": b.total, "left": b.left.max(0.0), "mode": b.mode, "preview": b.preview, "tips": b.tips })
        });
        json!({
            "version": VERSION,
            "cfg": self.cfg,
            "stats": self.stats,
            "eye": self.eye,
            "move": self.mv,
            "water": self.water,
            "paused": self.paused,
            "away": self.away,
            "musicOn": self.music_on,
            "brk": brk,
            "toast": self.toast.map(|(_, tip)| json!({ "tip": tip })),
        })
    }

    pub fn tooltip(&self) -> String {
        if self.paused {
            return self.t("trayPaused");
        }
        let fmt = |total: u32, used: f64| {
            let s = (total as f64 * 60.0 - used).max(0.0).ceil() as u64;
            format!("{:02}:{:02}", s / 60, s % 60)
        };
        format!(
            "{} — {} {} | {} {}",
            self.t("appName"),
            self.t("trayEye"),
            fmt(self.cfg.eye_interval, self.eye),
            self.t("tileMove"),
            fmt(self.cfg.move_interval, self.mv)
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn engine(name: &str) -> Engine {
        let dir = std::env::temp_dir().join(format!("salamatyar-test-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let mut e = Engine::new(dir);
        e.cfg.lang = "en".into();
        e
    }

    fn rewind(e: &mut Engine, secs: u64) {
        e.last = SystemTime::now() - std::time::Duration::from_secs(secs);
    }

    #[test]
    fn language_files_are_complete() {
        let l = Lang::load();
        assert_eq!(l.order, LANGS);
        for (k, v) in &l.strings {
            assert_eq!(v.len(), LANGS.len(), "key {k}");
            assert!(v.iter().all(|s| !s.trim().is_empty()), "key {k}");
        }
        assert_eq!(l.pool_len("eyeTip"), 14);
        assert_eq!(l.pool_len("moveTip"), 22);
        assert_eq!(l.pool_len("waterTip"), 8);
        assert_eq!(l.pool_len("dashTip"), 14);
        assert_eq!(l.t("ckAuto", "en"), "Start automatically when you sign in");
    }

    #[test]
    fn tips_do_not_repeat_within_a_round() {
        let mut e = engine("tips");
        let mut seen = Vec::new();
        for _ in 0..11 {
            seen.extend(e.next_tips("move", 2));
        }
        seen.sort();
        assert_eq!(seen, (1..=22).collect::<Vec<_>>());
    }

    #[test]
    fn eye_break_starts_and_counts() {
        let mut e = engine("eye");
        e.eye = 20.0 * 60.0 - 1.0;
        rewind(&mut e, 2);
        let fx = e.tick(0.0);
        assert!(fx.iter().any(|f| matches!(f, Effect::OpenBreak(m) if m == "full")));
        assert_eq!(e.brk.as_ref().unwrap().kind, "eye");
        assert_eq!(e.brk.as_ref().unwrap().tips.len(), 1);
        // The break runs for 20 seconds; a long gap is counted as at most 5 seconds per step.
        for _ in 0..4 {
            rewind(&mut e, 6);
            e.tick(0.0);
        }
        assert!(e.brk.is_none());
        assert_eq!(e.stats.eye, 1);
        assert_eq!(e.eye, 0.0);
    }

    #[test]
    fn movement_break_has_priority_and_resets_both() {
        let mut e = engine("move");
        e.eye = 5000.0;
        e.mv = 5000.0;
        rewind(&mut e, 1);
        e.tick(0.0);
        assert_eq!(e.brk.as_ref().unwrap().kind, "move");
        assert_eq!(e.brk.as_ref().unwrap().tips.len(), 2);
        e.end_break("done");
        assert_eq!((e.stats.mv, e.eye, e.mv), (1, 0.0, 0.0));
    }

    #[test]
    fn later_skip_and_preview() {
        let mut e = engine("later");
        e.start_break("eye", false);
        e.end_break("later");
        assert_eq!(e.eye, 20.0 * 60.0 - 300.0);
        e.start_break("move", false);
        e.end_break("skip");
        assert_eq!(e.stats.skipped, 1);
        e.eye = 100.0;
        e.preview_break();
        assert!(e.brk.as_ref().unwrap().preview);
        e.end_break("done");
        assert_eq!((e.stats.mv, e.stats.skipped, e.eye), (0, 1, 100.0));
    }

    #[test]
    fn absence_resets_timers_and_pause_stops_them() {
        let mut e = engine("idle");
        e.eye = 600.0;
        e.mv = 600.0;
        rewind(&mut e, 1);
        e.tick(301.0);
        assert_eq!((e.eye, e.mv, e.away), (0.0, 0.0, true));
        e.toggle_pause();
        rewind(&mut e, 30);
        e.tick(0.0);
        assert_eq!(e.eye, 0.0);
    }

    #[test]
    fn tray_mode_sends_notifications_only() {
        let mut e = engine("tray");
        e.cfg.break_mode = "tray".into();
        let fx = e.start_break("eye", false);
        assert!(fx.iter().any(|f| matches!(f, Effect::Notify(..))));
        assert!(!fx.iter().any(|f| matches!(f, Effect::OpenBreak(_) | Effect::Music(..))));
        e.end_break("done");
        e.water = 60.0 * 60.0;
        rewind(&mut e, 1);
        let fx = e.tick(0.0);
        assert!(fx.iter().any(|f| matches!(f, Effect::Notify(..))));
        assert!(e.toast.is_none());
    }

    #[test]
    fn settings_are_clamped() {
        let mut e = engine("cfg");
        let mut c = e.cfg.clone();
        c.eye_interval = 1;
        c.volume = 900;
        c.theme = "pink".into();
        c.lang = "ru".into();
        let fx = e.set_cfg(c);
        assert_eq!((e.cfg.eye_interval, e.cfg.volume, e.cfg.theme.as_str()), (10, 100, "dark"));
        assert!(fx.iter().any(|f| matches!(f, Effect::TrayMenu)));
    }
}
