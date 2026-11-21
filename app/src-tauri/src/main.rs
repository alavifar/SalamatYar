// SalamatYar — health reminders for computer work (cross-platform edition).
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod audio;
mod engine;
mod synth;

use audio::{Audio, Cmd, Fx, Slot};
use engine::{Cfg, Effect, Engine};
use serde_json::Value;
use std::sync::mpsc::{channel, Sender};
use std::sync::Mutex;
use std::time::Duration;
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, LogicalPosition, LogicalSize, Manager, RunEvent, WebviewUrl, WebviewWindow, WebviewWindowBuilder, WindowEvent, Wry};
use tauri_plugin_autostart::ManagerExt as _;
use tauri_plugin_dialog::DialogExt as _;
use tauri_plugin_notification::NotificationExt as _;

const AUTHOR_LINK: &str = "https://t.me/ShrAlavifar";
const MINI_WIDTH: f64 = 420.0;

struct TrayItems {
    show: MenuItem<Wry>,
    pause: MenuItem<Wry>,
    eye: MenuItem<Wry>,
    mv: MenuItem<Wry>,
    exit: MenuItem<Wry>,
}

struct AppState {
    eng: Mutex<Engine>,
    audio: Audio,
    tx: Mutex<Sender<Effect>>,
    tray: Mutex<Option<TrayItems>>,
    hint_shown: Mutex<bool>,
    /// Lines collected during `--selfcheck`; `None` in a normal run.
    check: Mutex<Option<Vec<String>>>,
}

fn note(app: &AppHandle, line: String) {
    if let Some(log) = app.state::<AppState>().check.lock().unwrap().as_mut() {
        log.push(line);
    }
}

/// Runs `f` on the engine, queues the side effects it asks for and tells every window the new state.
fn act(app: &AppHandle, f: impl FnOnce(&mut Engine) -> Vec<Effect>) {
    let st = app.state::<AppState>();
    let (fx, snap) = {
        let mut e = st.eng.lock().unwrap();
        let fx = f(&mut e);
        (fx, e.snapshot())
    };
    if let Ok(tx) = st.tx.lock() {
        for e in fx {
            let _ = tx.send(e);
        }
    }
    let _ = app.emit("state", snap);
}

// ---------- windows ----------

fn show_main(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.unminimize();
        let _ = w.show();
        let _ = w.set_focus();
    }
}

/// Work area of the primary monitor in logical pixels: (x, y, width, height).
fn work_area(app: &AppHandle, whole_screen: bool) -> (f64, f64, f64, f64) {
    match app.primary_monitor().ok().flatten() {
        Some(m) => {
            let s = m.scale_factor();
            if whole_screen {
                let (p, z) = (m.position(), m.size());
                (p.x as f64 / s, p.y as f64 / s, z.width as f64 / s, z.height as f64 / s)
            } else {
                let r = m.work_area();
                (r.position.x as f64 / s, r.position.y as f64 / s, r.size.width as f64 / s, r.size.height as f64 / s)
            }
        }
        None => (0.0, 0.0, 1280.0, 720.0),
    }
}

/// A label can be reused only after the previous window with that label is really gone.
fn wait_gone(app: &AppHandle, label: &str) {
    for _ in 0..40 {
        if app.get_webview_window(label).is_none() {
            return;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
}

fn open_corner_window(app: &AppHandle, label: &str, page: &str, title: &str) {
    wait_gone(app, label);
    let (x, y, w, h) = work_area(app, false);
    let height = 250.0;
    let r = WebviewWindowBuilder::new(app, label, WebviewUrl::App(page.into()))
        .title(title)
        .inner_size(MINI_WIDTH, height)
        .position(x + w - MINI_WIDTH - 12.0, y + h - height - 12.0)
        .decorations(false)
        .resizable(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .focused(false)
        .build();
    if let Err(e) = r {
        eprintln!("window {label}: {e}");
    }
}

fn open_break(app: &AppHandle, mode: &str) {
    let title = app.state::<AppState>().eng.lock().unwrap().t("ovTitleWin");
    if mode == "full" {
        wait_gone(app, "overlay");
        let (x, y, w, h) = work_area(app, true);
        let r = WebviewWindowBuilder::new(app, "overlay", WebviewUrl::App("break.html".into()))
            .title(&title)
            .inner_size(w, h)
            .position(x, y)
            .decorations(false)
            .resizable(false)
            .always_on_top(true)
            .skip_taskbar(true)
            .focused(false)
            .build();
        if let Err(e) = r {
            eprintln!("window overlay: {e}");
        }
    } else {
        open_corner_window(app, "mini", "break.html", &title);
    }
}

fn close_windows(app: &AppHandle, labels: &[&str]) {
    for l in labels {
        if let Some(w) = app.get_webview_window(l) {
            let _ = w.destroy();
        }
    }
}

fn run_effect(app: &AppHandle, e: Effect) {
    let st = app.state::<AppState>();
    match e {
        Effect::OpenBreak(mode) => open_break(app, &mode),
        Effect::CloseBreak => close_windows(app, &["overlay", "mini"]),
        Effect::OpenToast => {
            let title = st.eng.lock().unwrap().t("toastWin");
            open_corner_window(app, "toast", "toast.html", &title);
        }
        Effect::CloseToast => close_windows(app, &["toast"]),
        Effect::Fx(kind, vol) => st.audio.send(Cmd::Fx(kind, vol)),
        Effect::Music(slot, custom, vol) => st.audio.send(Cmd::Music { slot, custom, vol }),
        Effect::StopMusic => st.audio.send(Cmd::StopMusic),
        Effect::MusicVol(v) => st.audio.send(Cmd::MusicVol(v)),
        Effect::Notify(title, body) => {
            let r = app.notification().builder().title(title).body(body).show();
            note(app, format!("notification sent: {}", if let Err(e) = &r { e.to_string() } else { "ok".into() }));
        }
        Effect::TrayMenu => refresh_tray(app),
    }
}

// ---------- tray ----------

fn refresh_tray(app: &AppHandle) {
    let st = app.state::<AppState>();
    let (show, pause, eye, mv, exit, tip) = {
        let e = st.eng.lock().unwrap();
        let pause = if e.paused { e.t("btnResume") } else { e.t("btnPause") };
        (e.t("miShow"), pause, e.t("miEye"), e.t("miMove"), e.t("miExit"), e.tooltip())
    };
    if let Some(items) = st.tray.lock().unwrap().as_ref() {
        let _ = items.show.set_text(show);
        let _ = items.pause.set_text(pause);
        let _ = items.eye.set_text(eye);
        let _ = items.mv.set_text(mv);
        let _ = items.exit.set_text(exit);
    }
    if let Some(t) = app.tray_by_id("main") {
        let _ = t.set_tooltip(Some(tip));
    }
}

fn build_tray(app: &AppHandle) -> tauri::Result<()> {
    let items = TrayItems {
        show: MenuItem::with_id(app, "show", "Show", true, None::<&str>)?,
        pause: MenuItem::with_id(app, "pause", "Pause", true, None::<&str>)?,
        eye: MenuItem::with_id(app, "eye", "Eye", true, None::<&str>)?,
        mv: MenuItem::with_id(app, "move", "Move", true, None::<&str>)?,
        exit: MenuItem::with_id(app, "exit", "Exit", true, None::<&str>)?,
    };
    let sep = PredefinedMenuItem::separator(app)?;
    let menu = Menu::with_items(app, &[&items.show, &items.pause, &items.eye, &items.mv, &sep, &items.exit])?;
    let mut b = TrayIconBuilder::with_id("main")
        .tooltip("SalamatYar")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, ev| match ev.id().as_ref() {
            "show" => show_main(app),
            "pause" => {
                act(app, |e| {
                    e.toggle_pause();
                    vec![Effect::TrayMenu]
                });
            }
            "eye" => act(app, |e| e.start_break("eye", false)),
            "move" => act(app, |e| e.start_break("move", false)),
            "exit" => quit(app),
            _ => {}
        })
        .on_tray_icon_event(|tray, ev| {
            if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = ev {
                show_main(tray.app_handle());
            }
        });
    if let Some(icon) = app.default_window_icon() {
        b = b.icon(icon.clone());
    }
    b.build(app)?;
    *app.state::<AppState>().tray.lock().unwrap() = Some(items);
    refresh_tray(app);
    Ok(())
}

fn quit(app: &AppHandle) {
    app.state::<AppState>().eng.lock().unwrap().save_all();
    app.exit(0);
}

// ---------- commands called by the windows ----------

#[tauri::command]
fn get_lang(app: AppHandle) -> Value {
    app.state::<AppState>().eng.lock().unwrap().lang.to_json()
}

#[tauri::command]
fn get_state(app: AppHandle) -> Value {
    app.state::<AppState>().eng.lock().unwrap().snapshot()
}

#[tauri::command]
fn set_cfg(app: AppHandle, cfg: Cfg) {
    act(&app, |e| e.set_cfg(cfg));
}

#[tauri::command]
fn restore_defaults(app: AppHandle) {
    act(&app, |e| {
        e.restore_defaults();
        Vec::new()
    });
}

#[tauri::command]
fn start_break(app: AppHandle, kind: String) {
    act(&app, |e| e.start_break(&kind, false));
}

#[tauri::command]
fn preview_break(app: AppHandle) {
    act(&app, |e| e.preview_break());
}

#[tauri::command]
fn end_break(app: AppHandle, how: String) {
    act(&app, |e| e.end_break(&how));
}

#[tauri::command]
fn drink(app: AppHandle) {
    act(&app, |e| e.drink());
}

#[tauri::command]
fn close_toast(app: AppHandle) {
    act(&app, |e| e.close_toast());
}

#[tauri::command]
fn toggle_pause(app: AppHandle) {
    act(&app, |e| {
        e.toggle_pause();
        vec![Effect::TrayMenu]
    });
}

#[tauri::command]
fn reset_timers(app: AppHandle) {
    act(&app, |e| {
        e.reset_timers();
        Vec::new()
    });
}

fn slot_of(name: &str) -> Slot {
    if name == "active" {
        Slot::Active
    } else {
        Slot::Calm
    }
}

#[tauri::command]
fn play_fx(app: AppHandle, kind: String) {
    let k = match kind.as_str() {
        "start" => Fx::Start,
        "end" => Fx::End,
        _ => Fx::Notify,
    };
    act(&app, |e| e.play_fx(k));
}

#[tauri::command]
fn play_sample(app: AppHandle, slot: String, seconds: f64) {
    act(&app, |e| e.sample(slot_of(&slot), seconds));
}

#[tauri::command]
fn toggle_sample(app: AppHandle, slot: String) {
    act(&app, |e| e.toggle_sample(slot_of(&slot)));
}

/// Lets the user choose an audio file for "musicEye" or "musicMove".
#[tauri::command]
async fn pick_music(app: AppHandle, key: String) -> Result<(), String> {
    let (title, name) = {
        let st = app.state::<AppState>();
        let e = st.eng.lock().unwrap();
        (e.t("pickTitle"), e.t("filterAudio"))
    };
    let picked = app
        .dialog()
        .file()
        .set_title(title)
        .add_filter(name, &["mp3", "wav", "flac", "ogg", "m4a", "aac"])
        .blocking_pick_file();
    if let Some(p) = picked.and_then(|f| f.into_path().ok()) {
        let path = p.to_string_lossy().to_string();
        act(&app, |e| e.set_music(&key, path));
    }
    Ok(())
}

#[tauri::command]
fn clear_music(app: AppHandle, key: String) {
    act(&app, |e| e.set_music(&key, String::new()));
}

#[tauri::command]
fn get_autostart(app: AppHandle) -> bool {
    app.autolaunch().is_enabled().unwrap_or(false)
}

#[tauri::command]
fn set_autostart(app: AppHandle, on: bool) -> bool {
    let a = app.autolaunch();
    let _ = if on { a.enable() } else { a.disable() };
    a.is_enabled().unwrap_or(false)
}

#[tauri::command]
fn open_author() {
    let _ = open::that(AUTHOR_LINK);
}

/// The small windows report the height of their content; the window is resized and kept
/// in the bottom corner of the screen.
#[tauri::command]
fn fit_window(app: AppHandle, window: WebviewWindow, height: f64) {
    if window.label() != "mini" && window.label() != "toast" {
        return;
    }
    let (x, y, w, h) = work_area(&app, false);
    let height = height.clamp(120.0, h - 24.0);
    let _ = window.set_size(LogicalSize::new(MINI_WIDTH, height));
    let _ = window.set_position(LogicalPosition::new(x + w - MINI_WIDTH - 12.0, y + h - height - 12.0));
}

#[tauri::command]
fn ui_report(app: AppHandle, window: WebviewWindow, info: String) {
    note(&app, format!("ui[{}] {}", window.label(), info));
}

// ---------- self-check ----------

/// `--selfcheck <file>`: opens every kind of window for a moment with separate, silent
/// settings, writes what happened to the file and exits. Used to test a build.
fn self_check(app: AppHandle, out: std::path::PathBuf) {
    let wait = |ms| std::thread::sleep(Duration::from_millis(ms));
    let windows = |app: &AppHandle, what: &str| {
        let mut v: Vec<String> = app
            .webview_windows()
            .iter()
            .map(|(l, w)| {
                let s = w.scale_factor().unwrap_or(1.0);
                let z = w.inner_size().map(|z| z.to_logical::<f64>(s)).unwrap_or(LogicalSize::new(0.0, 0.0));
                let p = w.outer_position().map(|p| p.to_logical::<f64>(s)).unwrap_or(LogicalPosition::new(0.0, 0.0));
                format!("{l} {:.0}x{:.0} at {:.0},{:.0} visible={}", z.width, z.height, p.x, p.y, w.is_visible().unwrap_or(false))
            })
            .collect();
        v.sort();
        note(app, format!("{what}: {}", v.join(" | ")));
    };
    wait(2500);
    note(&app, format!("version {} tray={} work_area={:?} screen={:?}", engine::VERSION, app.tray_by_id("main").is_some(), work_area(&app, false), work_area(&app, true)));
    let tip = app.state::<AppState>().eng.lock().unwrap().tooltip();
    note(&app, format!("tooltip: {tip}"));
    windows(&app, "start");
    // Drive the real controls of the main window, to check the path from a click to the engine.
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.eval("document.querySelector('[data-lang=fa]').click()");
        wait(700);
        let _ = w.eval("var s=document.getElementById('s-eyeInterval'); s.value=25; s.dispatchEvent(new Event('input'))");
        wait(700);
        let _ = w.eval("document.querySelector('#segDisp [data-v=window]').click()");
        wait(2500);
        let (lang, eye, mode, tip) = {
            let st = app.state::<AppState>();
            let e = st.eng.lock().unwrap();
            (e.cfg.lang.clone(), e.cfg.eye_interval, e.cfg.break_mode.clone(), e.tooltip())
        };
        note(&app, format!("after clicks: lang={lang} eyeInterval={eye} breakMode={mode} tooltip={tip}"));
        windows(&app, "preview from the settings page");
        let _ = w.eval("report('title=' + document.querySelector('.brand b').textContent + ' dir=' + document.documentElement.dir + ' eyeVal=' + document.getElementById('v-eyeInterval').textContent)");
        act(&app, |e| e.end_break("skip"));
        wait(700);
    }
    for mode in ["window", "full", "tray"] {
        act(&app, |e| {
            e.cfg.break_mode = mode.into();
            e.preview_break()
        });
        wait(2500);
        windows(&app, &format!("break {mode}"));
        act(&app, |e| e.end_break("skip"));
        wait(700);
    }
    act(&app, |e| {
        e.cfg.break_mode = "window".into();
        e.make_water_due();
        Vec::new()
    });
    wait(3000);
    windows(&app, "water");
    act(&app, |e| e.drink());
    wait(700);
    windows(&app, "end");
    let snap = app.state::<AppState>().eng.lock().unwrap().snapshot();
    note(&app, format!("stats: {}", snap["stats"]));
    let lines = app.state::<AppState>().check.lock().unwrap().clone().unwrap_or_default();
    let _ = std::fs::write(out, lines.join("\n"));
    app.exit(0);
}

/// Windows shows a notification only for an app it knows by its identifier. The installer
/// registers that through a Start-menu shortcut; the portable exe has none, so the app
/// registers itself for the current user (no administrator rights needed).
#[cfg(windows)]
fn register_app_id(id: &str, dir: &std::path::Path) -> std::io::Result<()> {
    let icon = dir.join("icon.png");
    std::fs::create_dir_all(dir)?;
    std::fs::write(&icon, include_bytes!("../icons/128x128.png"))?;
    let hkcu = winreg::RegKey::predef(winreg::enums::HKEY_CURRENT_USER);
    let (key, _) = hkcu.create_subkey(format!("Software\\Classes\\AppUserModelId\\{id}"))?;
    key.set_value("DisplayName", &"SalamatYar")?;
    key.set_value("IconUri", &icon.to_string_lossy().to_string())?;
    Ok(())
}

// ---------- start ----------

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let check_file = args.iter().position(|a| a == "--selfcheck").and_then(|i| args.get(i + 1)).map(std::path::PathBuf::from);
    let minimized = args.iter().any(|a| a == "--minimized");
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| show_main(app)))
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_autostart::init(tauri_plugin_autostart::MacosLauncher::LaunchAgent, Some(vec!["--minimized"])))
        .invoke_handler(tauri::generate_handler![
            get_lang,
            get_state,
            set_cfg,
            restore_defaults,
            start_break,
            preview_break,
            end_break,
            drink,
            close_toast,
            toggle_pause,
            reset_timers,
            play_fx,
            play_sample,
            toggle_sample,
            pick_music,
            clear_music,
            get_autostart,
            set_autostart,
            open_author,
            fit_window,
            ui_report
        ])
        .setup(move |app| {
            let mut dir = app.path().app_config_dir()?;
            #[cfg(windows)]
            {
                let r = register_app_id(&app.config().identifier, &dir);
                if let (Err(e), Some(_)) = (&r, &check_file) {
                    eprintln!("app id: {e}");
                }
            }
            if check_file.is_some() {
                dir = std::env::temp_dir().join("salamatyar-selfcheck");
                let _ = std::fs::remove_dir_all(&dir);
            }
            let mut eng = Engine::new(dir);
            if check_file.is_some() {
                eng.cfg.volume = 0;
            }
            let (tx, rx) = channel::<Effect>();
            app.manage(AppState {
                check: Mutex::new(check_file.as_ref().map(|_| Vec::new())),
                eng: Mutex::new(eng),
                audio: Audio::start(),
                tx: Mutex::new(tx),
                tray: Mutex::new(None),
                hint_shown: Mutex::new(false),
            });
            let handle = app.handle().clone();
            if let Err(e) = build_tray(&handle) {
                eprintln!("tray: {e}");
            }
            // Windows and sound are handled one after another on their own thread, never
            // while the engine is locked.
            let h = handle.clone();
            std::thread::spawn(move || {
                for e in rx {
                    run_effect(&h, e);
                }
            });
            // The clock: two steps per second.
            let h = handle.clone();
            std::thread::spawn(move || {
                let mut last_tip = String::new();
                loop {
                    std::thread::sleep(Duration::from_millis(500));
                    let idle = user_idle::UserIdle::get_time().map(|t| t.as_seconds() as f64).unwrap_or(0.0);
                    act(&h, |e| e.tick(idle));
                    let tip = h.state::<AppState>().eng.lock().unwrap().tooltip();
                    if tip != last_tip {
                        if let Some(t) = h.tray_by_id("main") {
                            let _ = t.set_tooltip(Some(tip.clone()));
                        }
                        last_tip = tip;
                    }
                }
            });
            if !minimized {
                show_main(&handle);
            }
            if let Some(out) = check_file.clone() {
                let h = handle.clone();
                std::thread::spawn(move || self_check(h, out));
            }
            Ok(())
        })
        .on_window_event(|window, event| {
            if let WindowEvent::CloseRequested { api, .. } = event {
                let app = window.app_handle().clone();
                api.prevent_close();
                match window.label() {
                    "main" => {
                        // Closing the window keeps the app running in the tray.
                        let _ = window.hide();
                        let st = app.state::<AppState>();
                        let mut shown = st.hint_shown.lock().unwrap();
                        if !*shown {
                            *shown = true;
                            let (title, body) = {
                                let e = st.eng.lock().unwrap();
                                (e.t("balloonTitle"), e.t("balloonText"))
                            };
                            let _ = app.notification().builder().title(title).body(body).show();
                        }
                    }
                    "toast" => act(&app, |e| e.close_toast()),
                    _ => act(&app, |e| e.end_break("skip")),
                }
            }
        })
        .build(tauri::generate_context!())
        .expect("error while starting SalamatYar");
    app.run(|_app, event| {
        // Break windows come and go; the app itself only ends from the tray menu.
        if let RunEvent::ExitRequested { api, code, .. } = event {
            if code.is_none() {
                api.prevent_exit();
            }
        }
    });
}
