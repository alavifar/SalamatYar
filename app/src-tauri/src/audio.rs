//! Sound playback on its own thread: chimes, looping break music and a soft fade-out.

use crate::synth;
use rodio::buffer::SamplesBuffer;
use rodio::{Decoder, OutputStream, OutputStreamHandle, Sink, Source};
use std::fs::File;
use std::io::BufReader;
use std::path::PathBuf;
use std::sync::mpsc::{channel, RecvTimeoutError, Sender};
use std::time::Duration;

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Fx {
    Start,
    End,
    Notify,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Slot {
    Calm,
    Active,
}

pub enum Cmd {
    Fx(Fx, f32),
    Music { slot: Slot, custom: Option<PathBuf>, vol: f32 },
    StopMusic,
    MusicVol(f32),
}

pub struct Audio {
    tx: Sender<Cmd>,
}

impl Audio {
    pub fn start() -> Audio {
        let (tx, rx) = channel::<Cmd>();
        std::thread::spawn(move || {
            // Without an output device the app still works, only silently.
            let out: Option<(OutputStream, OutputStreamHandle)> = OutputStream::try_default().ok();
            let chimes = [synth::chime(0), synth::chime(1), synth::chime(2)];
            let mut calm: Option<Vec<f32>> = None;
            let mut active: Option<Vec<f32>> = None;
            let mut music: Option<Sink> = None;
            let mut fading: Option<Sink> = None;
            let mut fx: Vec<Sink> = Vec::new();
            loop {
                match rx.recv_timeout(Duration::from_millis(70)) {
                    Ok(cmd) => {
                        let Some((_, handle)) = out.as_ref() else { continue };
                        match cmd {
                            Cmd::Fx(kind, vol) => {
                                let data = match kind {
                                    Fx::Start => &chimes[0],
                                    Fx::End => &chimes[1],
                                    Fx::Notify => &chimes[2],
                                };
                                if let Ok(s) = Sink::try_new(handle) {
                                    s.set_volume(vol);
                                    s.append(SamplesBuffer::new(1, synth::SR, data.clone()));
                                    fx.push(s);
                                }
                            }
                            Cmd::Music { slot, custom, vol } => {
                                if let Some(s) = fading.take() {
                                    s.stop();
                                }
                                if let Some(s) = music.take() {
                                    s.stop();
                                }
                                let Ok(s) = Sink::try_new(handle) else { continue };
                                s.set_volume(vol);
                                let mut done = false;
                                // A custom file that cannot be played falls back to the built-in track.
                                if let Some(p) = custom {
                                    if let Ok(f) = File::open(&p) {
                                        if let Ok(d) = Decoder::new(BufReader::new(f)) {
                                            s.append(d.repeat_infinite());
                                            done = true;
                                        }
                                    }
                                }
                                if !done {
                                    let data = match slot {
                                        Slot::Calm => calm.get_or_insert_with(synth::calm),
                                        Slot::Active => active.get_or_insert_with(synth::active),
                                    };
                                    s.append(SamplesBuffer::new(1, synth::SR, data.clone()).repeat_infinite());
                                }
                                music = Some(s);
                            }
                            Cmd::StopMusic => {
                                if let Some(s) = music.take() {
                                    if let Some(old) = fading.replace(s) {
                                        old.stop();
                                    }
                                }
                            }
                            Cmd::MusicVol(v) => {
                                if let Some(s) = &music {
                                    s.set_volume(v);
                                }
                            }
                        }
                    }
                    Err(RecvTimeoutError::Timeout) => {}
                    Err(RecvTimeoutError::Disconnected) => break,
                }
                if let Some(s) = &fading {
                    let v = s.volume() - 0.04;
                    if v <= 0.01 {
                        s.stop();
                        fading = None;
                    } else {
                        s.set_volume(v);
                    }
                }
                fx.retain(|s| !s.empty());
            }
        });
        Audio { tx }
    }

    pub fn send(&self, cmd: Cmd) {
        let _ = self.tx.send(cmd);
    }
}
