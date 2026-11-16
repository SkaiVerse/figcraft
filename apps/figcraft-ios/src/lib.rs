//! FigCraft for iPad: the engine and egui interface, drawn with Metal, driven by a Swift shell.
#![allow(clippy::missing_safety_doc)]

use std::cell::RefCell;
use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::future::Future;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;
use std::pin::Pin;
use std::rc::Rc;
use std::sync::{Arc, Mutex, Once};
use std::task::{Context as TaskContext, Poll, Waker};
use std::time::{Duration, Instant};

use figcraft_engine::Session;
use figcraft_ui_egui::{ContentsFuture, FigApp, Services};
use serde_json::json;

// ---------------------------------------------------------------------------------------------
// Callbacks into Swift (must match FigCraft-Bridging-Header.h, field for field)
// ---------------------------------------------------------------------------------------------

#[repr(C)]
#[derive(Clone, Copy)]
pub struct FCCallbacks {
    pub user: *mut c_void,
    pub open_files: Option<unsafe extern "C" fn(*mut c_void)>,
    pub save_file: Option<unsafe extern "C" fn(*mut c_void, *const c_char, *const u8, usize)>,
    pub open_url: Option<unsafe extern "C" fn(*mut c_void, *const c_char)>,
    pub copy_text: Option<unsafe extern "C" fn(*mut c_void, *const c_char)>,
    pub paste_text: Option<unsafe extern "C" fn(*mut c_void) -> *const c_char>,
    pub paste_html: Option<unsafe extern "C" fn(*mut c_void) -> *const c_char>,
    pub copy_image: Option<unsafe extern "C" fn(*mut c_void, u32, u32, *const u8, usize)>,
    pub paste_png: Option<unsafe extern "C" fn(*mut c_void, *mut usize) -> *const u8>,
    pub reduce_motion: Option<unsafe extern "C" fn(*mut c_void) -> c_int>,
    pub system_language: Option<unsafe extern "C" fn(*mut c_void) -> *const c_char>,
}

// ---------------------------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------------------------

fn documents_dir() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|h| PathBuf::from(h).join("Documents"))
}

fn note(msg: &str) {
    use std::io::Write;
    let Some(dir) = documents_dir() else { return };
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(dir.join("FigCraft-log.txt")) {
        let _ = writeln!(f, "[rust] {msg}");
    }
}

/// Sends the app's own warnings and errors to FigCraft-log.txt.
struct FileLogger;

impl log::Log for FileLogger {
    fn enabled(&self, m: &log::Metadata) -> bool {
        m.level() <= log::Level::Warn
    }
    fn log(&self, r: &log::Record) {
        if self.enabled(r.metadata()) {
            note(&format!("{} {}: {}", r.level(), r.target(), r.args()));
        }
    }
    fn flush(&self) {}
}

static LOGGER: FileLogger = FileLogger;

fn cstring(s: &str) -> CString {
    CString::new(s.replace('\0', "")).unwrap_or_default()
}

unsafe fn from_c(p: *const c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    Some(unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned())
}

fn guard<R>(default: R, f: impl FnOnce() -> R) -> R {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or(default)
}

fn to_mods(m: u32) -> egui::Modifiers {
    // Only Apple's modifier rules: Command is the shortcut key, Control stays Control.
    let cmd = m & 8 != 0;
    egui::Modifiers { alt: m & 4 != 0, ctrl: m & 2 != 0, shift: m & 1 != 0, mac_cmd: cmd, command: cmd }
}

fn hid_to_key(hid: u32) -> Option<egui::Key> {
    use egui::Key;
    const LETTERS: [Key; 26] = [
        Key::A, Key::B, Key::C, Key::D, Key::E, Key::F, Key::G, Key::H, Key::I, Key::J, Key::K, Key::L, Key::M,
        Key::N, Key::O, Key::P, Key::Q, Key::R, Key::S, Key::T, Key::U, Key::V, Key::W, Key::X, Key::Y, Key::Z,
    ];
    const DIGITS: [Key; 9] =
        [Key::Num1, Key::Num2, Key::Num3, Key::Num4, Key::Num5, Key::Num6, Key::Num7, Key::Num8, Key::Num9];
    const FKEYS: [Key; 12] =
        [Key::F1, Key::F2, Key::F3, Key::F4, Key::F5, Key::F6, Key::F7, Key::F8, Key::F9, Key::F10, Key::F11, Key::F12];
    Some(match hid {
        0x04..=0x1D => LETTERS[(hid - 0x04) as usize],
        0x1E..=0x26 => DIGITS[(hid - 0x1E) as usize],
        0x27 => Key::Num0,
        0x28 => Key::Enter,
        0x29 => Key::Escape,
        0x2A => Key::Backspace,
        0x2B => Key::Tab,
        0x2C => Key::Space,
        0x2D => Key::Minus,
        0x2E => Key::Equals,
        0x2F => Key::OpenBracket,
        0x30 => Key::CloseBracket,
        0x31 => Key::Backslash,
        0x33 => Key::Semicolon,
        0x34 => Key::Quote,
        0x35 => Key::Backtick,
        0x36 => Key::Comma,
        0x37 => Key::Period,
        0x38 => Key::Slash,
        0x3A..=0x45 => FKEYS[(hid - 0x3A) as usize],
        0x49 => Key::Insert,
        0x4A => Key::Home,
        0x4B => Key::PageUp,
        0x4C => Key::Delete,
        0x4D => Key::End,
        0x4E => Key::PageDown,
        0x4F => Key::ArrowRight,
        0x50 => Key::ArrowLeft,
        0x51 => Key::ArrowDown,
        0x52 => Key::ArrowUp,
        _ => return None,
    })
}

// ---------------------------------------------------------------------------------------------
// Preferences (the same state.json the desktop app keeps, in the app's own folder)
// ---------------------------------------------------------------------------------------------

fn config_dir() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|h| PathBuf::from(h).join("Library/Application Support/FigCraft"))
}

/// The saved preferences, and whether this is the very first run (nothing saved yet).
fn load_prefs() -> (Option<figcraft_engine::Prefs>, bool) {
    let Some(dir) = config_dir() else { return (None, true) };
    let Ok(text) = std::fs::read_to_string(dir.join("state.json")) else { return (None, true) };
    let state: serde_json::Value = serde_json::from_str(&text).unwrap_or(json!({}));
    let prefs = state.get("prefs").and_then(|p| serde_json::from_value::<figcraft_engine::Prefs>(p.clone()).ok());
    (prefs, false)
}

fn write_prefs(prefs: &figcraft_engine::Prefs) {
    let Some(dir) = config_dir() else { return };
    let _ = std::fs::create_dir_all(&dir);
    let tmp = dir.join("state.json.tmp");
    if std::fs::write(&tmp, json!({ "prefs": prefs }).to_string()).is_ok() {
        let _ = std::fs::rename(&tmp, dir.join("state.json"));
    }
}

// ---------------------------------------------------------------------------------------------
// Services: what the app asks the iPad to do
// ---------------------------------------------------------------------------------------------

type OpenResult = Option<Result<(String, Vec<u8>), String>>;

/// The answer of Apple's Open sheet, on its way to the app's waiting dialog.
#[derive(Default)]
struct OpenSlot {
    waiting: bool,
    result: Option<OpenResult>,
    waker: Option<Waker>,
}

struct OpenFuture(Rc<RefCell<OpenSlot>>);

impl Future for OpenFuture {
    type Output = OpenResult;
    fn poll(self: Pin<&mut Self>, cx: &mut TaskContext<'_>) -> Poll<Self::Output> {
        let mut s = self.0.borrow_mut();
        match s.result.take() {
            Some(r) => Poll::Ready(r),
            None => {
                s.waker = Some(cx.waker().clone());
                Poll::Pending
            }
        }
    }
}

type PendingSave = Rc<RefCell<Option<(String, Vec<u8>)>>>;

struct IosServices {
    cb: FCCallbacks,
    open: Rc<RefCell<OpenSlot>>,
    pending_save: PendingSave,
}

fn web_safe(url: &str) -> bool {
    let u = url.trim().to_ascii_lowercase();
    u.starts_with("http://") || u.starts_with("https://") || u.starts_with("mailto:")
}

impl Services for IosServices {
    fn pick_open_contents(&mut self, _title: &str, _exts: &[&str]) -> Option<ContentsFuture> {
        note("the app asked to open a file");
        {
            let mut s = self.open.borrow_mut();
            s.waiting = true;
            s.result = None;
        }
        if let Some(f) = self.cb.open_files {
            unsafe { f(self.cb.user) }
        }
        Some(Box::pin(OpenFuture(self.open.clone())))
    }

    fn downloads(&self) -> bool {
        true
    }

    fn download(&mut self, name: &str, bytes: &[u8]) -> bool {
        let Some(f) = self.cb.save_file else { return false };
        *self.pending_save.borrow_mut() = Some((name.to_string(), bytes.to_vec()));
        let n = cstring(name);
        unsafe { f(self.cb.user, n.as_ptr(), bytes.as_ptr(), bytes.len()) };
        true
    }

    fn clipboard_set_text(&mut self, s: &str) {
        if let Some(f) = self.cb.copy_text {
            let c = cstring(s);
            unsafe { f(self.cb.user, c.as_ptr()) }
        }
    }

    fn clipboard_get_text(&mut self) -> Option<String> {
        let f = self.cb.paste_text?;
        unsafe { from_c(f(self.cb.user)) }
    }

    fn clipboard_get_html(&mut self) -> Option<String> {
        let f = self.cb.paste_html?;
        unsafe { from_c(f(self.cb.user)) }
    }

    fn clipboard_set_png(&mut self, w: u32, h: u32, rgba: &[u8]) {
        if let Some(f) = self.cb.copy_image {
            unsafe { f(self.cb.user, w, h, rgba.as_ptr(), rgba.len()) }
        }
    }

    fn clipboard_get_png(&mut self) -> Option<Vec<u8>> {
        let f = self.cb.paste_png?;
        let mut len: usize = 0;
        let p = unsafe { f(self.cb.user, &mut len) };
        if p.is_null() || len == 0 {
            return None;
        }
        Some(unsafe { std::slice::from_raw_parts(p, len) }.to_vec())
    }

    fn open_url(&mut self, url: &str) {
        if !web_safe(url) {
            return;
        }
        if let Some(f) = self.cb.open_url {
            let c = cstring(url);
            unsafe { f(self.cb.user, c.as_ptr()) }
        }
    }

    fn reduce_motion(&self) -> bool {
        match self.cb.reduce_motion {
            Some(f) => unsafe { f(self.cb.user) != 0 },
            None => false,
        }
    }

    fn save_prefs(&mut self, prefs: &figcraft_engine::Prefs) {
        write_prefs(prefs);
    }

    fn system_language(&self) -> Option<String> {
        let f = self.cb.system_language?;
        unsafe { from_c(f(self.cb.user)) }
    }
}

// ---------------------------------------------------------------------------------------------
// Graphics (Metal through wgpu)
// ---------------------------------------------------------------------------------------------

struct Gpu {
    surface: wgpu::Surface<'static>,
    device: wgpu::Device,
    queue: wgpu::Queue,
    renderer: egui_wgpu::Renderer,
    config: wgpu::SurfaceConfiguration,
    needs_reconfigure: bool,
}

impl Gpu {
    fn new(layer: *mut c_void, width: u32, height: u32) -> Result<Gpu, String> {
        let instance = wgpu::Instance::default();
        let surface: wgpu::Surface<'static> =
            unsafe { instance.create_surface_unsafe(wgpu::SurfaceTargetUnsafe::CoreAnimationLayer(layer)) }
                .map_err(|e| format!("surface: {e}"))?;
        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            compatible_surface: Some(&surface),
            force_fallback_adapter: false,
            apply_limit_buckets: false,
        }))
        .map_err(|e| format!("adapter: {e}"))?;
        let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
            label: Some("figcraft"),
            required_limits: wgpu::Limits { max_texture_dimension_2d: 8192, ..wgpu::Limits::default() },
            ..Default::default()
        }))
        .map_err(|e| format!("device: {e}"))?;
        let caps = surface.get_capabilities(&adapter);
        let format = egui_wgpu::preferred_framebuffer_format(&caps.formats).map_err(|e| format!("format: {e}"))?;
        let mut config = surface
            .get_default_config(&adapter, width.max(1), height.max(1))
            .ok_or_else(|| "this surface is not supported".to_string())?;
        config.format = format;
        config.view_formats = vec![format];
        config.present_mode = wgpu::PresentMode::AutoVsync;
        surface.configure(&device, &config);
        let renderer = egui_wgpu::Renderer::new(&device, format, egui_wgpu::RendererOptions::default());
        Ok(Gpu { surface, device, queue, renderer, config, needs_reconfigure: false })
    }
}

// ---------------------------------------------------------------------------------------------
// The host: one per window
// ---------------------------------------------------------------------------------------------

struct Host {
    fig: FigApp,
    ctx: egui::Context,
    gpu: Gpu,
    scale: f32,
    events: Vec<egui::Event>,
    modifiers: egui::Modifiers,
    dark: bool,
    focused: bool,
    start: Instant,
    deadline: Arc<Mutex<Option<Instant>>>,
    cb: FCCallbacks,
    open: Rc<RefCell<OpenSlot>>,
    pending_save: PendingSave,
    wants_keyboard: bool,
    fonts_logged: bool,
}

fn wake_at(deadline: &Arc<Mutex<Option<Instant>>>, at: Instant) {
    let mut d = deadline.lock().unwrap_or_else(|e| e.into_inner());
    if d.is_none_or(|cur| at < cur) {
        *d = Some(at);
    }
}

impl Host {
    fn new(layer: *mut c_void, width: u32, height: u32, scale: f32, cb: FCCallbacks) -> Result<Host, String> {
        // Folders that show up in Files > On My iPad > FigCraft.
        if let Some(docs) = documents_dir() {
            let _ = std::fs::create_dir_all(docs.join("Fonts"));
            let _ = std::fs::create_dir_all(docs.join("Working"));
        }

        let gpu = Gpu::new(layer, width, height)?;
        let ctx = egui::Context::default();
        // Apple's shortcut set only: the app asks the context which system it runs on.
        ctx.set_os(egui::os::OperatingSystem::Mac);
        let deadline: Arc<Mutex<Option<Instant>>> = Arc::new(Mutex::new(Some(Instant::now())));
        {
            let dl = deadline.clone();
            ctx.set_request_repaint_callback(move |info| {
                let now = Instant::now();
                let at = now.checked_add(info.delay).unwrap_or(now + Duration::from_secs(3600));
                wake_at(&dl, at);
            });
        }

        // Catalog the fonts on this iPad in the background, then draw again with them.
        {
            let dl = deadline.clone();
            std::thread::spawn(move || {
                figcraft_text::scan_system_fonts();
                wake_at(&dl, Instant::now());
            });
        }

        let open: Rc<RefCell<OpenSlot>> = Rc::new(RefCell::new(OpenSlot::default()));
        let pending_save: PendingSave = Rc::new(RefCell::new(None));
        let services = IosServices { cb, open: open.clone(), pending_save: pending_save.clone() };

        let mut session = Session::empty();
        let (prefs, first_run) = load_prefs();
        if let Some(p) = prefs {
            session.prefs = p;
        }
        if first_run {
            // A bigger interface for fingers and the Apple Pencil (Preferences > Interface size).
            session.prefs.ui_scale = 1.5;
        }
        figcraft_ui_egui::i18n::set(&session.prefs.language, services.system_language().as_deref());
        if !first_run && !session.prefs.start_on_home {
            let _ = session.execute("file.new", &json!({}));
        }
        let mut fig = FigApp::new(session, Box::new(services));
        fig.ui.home = false;

        Ok(Host {
            fig,
            ctx,
            gpu,
            scale,
            events: Vec::new(),
            modifiers: egui::Modifiers::NONE,
            dark: false,
            focused: true,
            start: Instant::now(),
            deadline,
            cb,
            open,
            pending_save,
            wants_keyboard: false,
            fonts_logged: false,
        })
    }

    fn wake(&self) {
        wake_at(&self.deadline, Instant::now());
    }

    fn push(&mut self, e: egui::Event) {
        self.events.push(e);
        self.wake();
    }

    /// Tells egui which modifier keys (Shift, Command, ...) are down, whenever that changes.
    /// This egui version learns modifier state only from this event.
    fn set_modifiers(&mut self, m: egui::Modifiers) {
        if m != self.modifiers {
            self.modifiers = m;
            self.push(egui::Event::ModifiersChanged(m));
        }
    }

    /// Points in the UIKit sense, converted to egui points (the interface size preference zooms).
    fn pt(&self, x: f32, y: f32) -> egui::Pos2 {
        let z = self.ctx.zoom_factor().max(0.1);
        egui::pos2(x / z, y / z)
    }

    fn handle_output(&self, out: &egui::PlatformOutput) {
        for cmd in &out.commands {
            match cmd {
                egui::OutputCommand::CopyText(text) => {
                    if let Some(f) = self.cb.copy_text {
                        let c = cstring(text);
                        unsafe { f(self.cb.user, c.as_ptr()) }
                    }
                }
                egui::OutputCommand::OpenUrl(open) => {
                    if web_safe(&open.url)
                        && let Some(f) = self.cb.open_url
                    {
                        let c = cstring(&open.url);
                        unsafe { f(self.cb.user, c.as_ptr()) }
                    }
                }
                _ => {}
            }
        }
    }

    fn flags(&self, drew: bool) -> c_int {
        (drew as c_int) | ((self.wants_keyboard as c_int) << 1)
    }

    fn frame(&mut self) -> c_int {
        let now = Instant::now();
        let due = self.deadline.lock().unwrap_or_else(|e| e.into_inner()).is_some_and(|t| now >= t);
        if !due {
            return self.flags(false);
        }
        *self.deadline.lock().unwrap_or_else(|e| e.into_inner()) = None;

        if !self.fonts_logged && figcraft_text::system_fonts_scanned() {
            self.fonts_logged = true;
            note(&format!("fonts: the system font scan finished, {} families", figcraft_text::family_names().len()));
        }

        let ppp = self.scale * self.ctx.zoom_factor().max(0.1);
        let rect = egui::Rect::from_min_size(
            egui::Pos2::ZERO,
            egui::vec2(self.gpu.config.width as f32 / ppp, self.gpu.config.height as f32 / ppp),
        );
        let mut raw = egui::RawInput::default();
        raw.time = Some(self.start.elapsed().as_secs_f64());
        raw.screen_rect = Some(rect);
        raw.focused = self.focused;
        raw.system_theme = Some(if self.dark { egui::Theme::Dark } else { egui::Theme::Light });
        raw.max_texture_side = Some(self.gpu.device.limits().max_texture_dimension_2d as usize);
        raw.events = std::mem::take(&mut self.events);
        if let Some(v) = raw.viewports.get_mut(&egui::ViewportId::ROOT) {
            v.native_pixels_per_point = Some(self.scale);
            v.inner_rect = Some(rect);
        }

        let ctx = self.ctx.clone();
        let extra_events = figcraft_ui_egui::windows::take_input(&mut self.fig, raw.viewport_id);
        raw.events.extend(extra_events);
        let logic = ctx.run_logic(&raw, |c| {
            figcraft_ui_egui::windows::guard(&mut self.fig, c, |f| f.background_tick(c));
        });
        let mut full = ctx.run_ui(raw, |ui| {
            let c = ui.ctx().clone();
            figcraft_ui_egui::windows::guard(&mut self.fig, &c, |f| f.ui(ui));
        });
        self.handle_output(&logic.platform_output);
        self.handle_output(&full.platform_output);
        self.wants_keyboard = ctx.egui_wants_keyboard_input();

        if let Some(vo) = full.viewport_output.get(&egui::ViewportId::ROOT)
            && let Some(at) = Instant::now().checked_add(vo.repaint_delay)
        {
            wake_at(&self.deadline, at);
        }

        let ppp_out = full.pixels_per_point;
        let shapes = std::mem::take(&mut full.shapes);
        let prims = ctx.tessellate(shapes, ppp_out);

        let deadline = self.deadline.clone();
        let gpu = &mut self.gpu;
        for (id, deltas) in full.textures_delta.set.drain() {
            for d in deltas {
                gpu.renderer.update_texture(&gpu.device, &gpu.queue, id, &d);
            }
        }

        if gpu.needs_reconfigure {
            gpu.surface.configure(&gpu.device, &gpu.config);
            gpu.needs_reconfigure = false;
        }
        let frame = if prims.is_empty() {
            // The app skips painting for one frame now and then (while it switches fonts).
            // Showing that empty frame would flash a blank screen, so the picture is kept.
            None
        } else {
            match gpu.surface.get_current_texture() {
                wgpu::CurrentSurfaceTexture::Success(f) => Some(f),
                wgpu::CurrentSurfaceTexture::Suboptimal(f) => {
                    gpu.needs_reconfigure = true;
                    Some(f)
                }
                _ => {
                    gpu.surface.configure(&gpu.device, &gpu.config);
                    wake_at(&deadline, Instant::now());
                    None
                }
            }
        };

        if let Some(frame) = frame {
            let view = frame.texture.create_view(&wgpu::TextureViewDescriptor::default());
            let mut encoder = gpu
                .device
                .create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("figcraft") });
            let screen = egui_wgpu::ScreenDescriptor {
                size_in_pixels: [gpu.config.width, gpu.config.height],
                pixels_per_point: ppp_out,
            };
            let extra = gpu.renderer.update_buffers(&gpu.device, &gpu.queue, &mut encoder, &prims, &screen);
            {
                let pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                    label: Some("figcraft"),
                    color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                        view: &view,
                        resolve_target: None,
                        ops: wgpu::Operations {
                            load: wgpu::LoadOp::Clear(wgpu::Color { r: 0.11, g: 0.11, b: 0.12, a: 1.0 }),
                            store: wgpu::StoreOp::Store,
                        },
                        depth_slice: None,
                    })],
                    depth_stencil_attachment: None,
                    timestamp_writes: None,
                    occlusion_query_set: None,
                    multiview_mask: None,
                });
                gpu.renderer.render(&mut pass.forget_lifetime(), &prims, &screen);
            }
            gpu.queue.submit(extra.into_iter().chain(std::iter::once(encoder.finish())));
            gpu.queue.present(frame);
        }

        for id in full.textures_delta.free.drain() {
            gpu.renderer.free_texture(&id);
        }
        self.flags(true)
    }
}

// ---------------------------------------------------------------------------------------------
// The C interface Swift calls
// ---------------------------------------------------------------------------------------------

unsafe fn host<'a>(h: *mut c_void) -> Option<&'a mut Host> {
    unsafe { (h as *mut Host).as_mut() }
}

static HOOK: Once = Once::new();

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fc_create(layer: *mut c_void, width_px: u32, height_px: u32, scale: f32, cb: FCCallbacks) -> *mut c_void {
    HOOK.call_once(|| {
        std::panic::set_hook(Box::new(|info| {
            note(&format!("PANIC: {info}\n{}", std::backtrace::Backtrace::force_capture()));
        }));
        let _ = log::set_logger(&LOGGER).map(|()| log::set_max_level(log::LevelFilter::Warn));
    });
    guard(std::ptr::null_mut(), || match Host::new(layer, width_px, height_px, scale, cb) {
        Ok(h) => Box::into_raw(Box::new(h)) as *mut c_void,
        Err(e) => {
            note(&format!("start failed: {e}"));
            std::ptr::null_mut()
        }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fc_destroy(h: *mut c_void) {
    if !h.is_null() {
        guard((), || drop(unsafe { Box::from_raw(h as *mut Host) }));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fc_resize(h: *mut c_void, width_px: u32, height_px: u32, scale: f32) {
    guard((), || {
        if let Some(h) = unsafe { host(h) } {
            h.scale = scale;
            h.gpu.config.width = width_px.max(1);
            h.gpu.config.height = height_px.max(1);
            h.gpu.surface.configure(&h.gpu.device, &h.gpu.config);
            h.wake();
        }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fc_set_dark(h: *mut c_void, dark: c_int) {
    if let Some(h) = unsafe { host(h) } {
        h.dark = dark != 0;
        h.wake();
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fc_set_focused(h: *mut c_void, focused: c_int) {
    if let Some(h) = unsafe { host(h) } {
        h.focused = focused != 0;
        h.wake();
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fc_pointer_moved(h: *mut c_void, x: f32, y: f32) {
    if let Some(h) = unsafe { host(h) } {
        let p = h.pt(x, y);
        h.push(egui::Event::PointerMoved(p));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fc_pointer_gone(h: *mut c_void) {
    if let Some(h) = unsafe { host(h) } {
        h.push(egui::Event::PointerGone);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fc_pointer_button(h: *mut c_void, x: f32, y: f32, button: c_int, pressed: c_int, mods: u32) {
    if let Some(h) = unsafe { host(h) } {
        h.set_modifiers(to_mods(mods));
        let pos = h.pt(x, y);
        let button = match button {
            1 => egui::PointerButton::Secondary,
            2 => egui::PointerButton::Middle,
            _ => egui::PointerButton::Primary,
        };
        let m = h.modifiers;
        h.push(egui::Event::PointerButton { pos, button, pressed: pressed != 0, modifiers: m });
    }
}

/// One finger of a multi-finger gesture (two fingers pan and pinch the canvas).
/// phase: 0 start, 1 move, 2 end, 3 cancel.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fc_touch(h: *mut c_void, id: u64, phase: c_int, x: f32, y: f32, force: f32) {
    if let Some(h) = unsafe { host(h) } {
        let phase = match phase {
            0 => egui::TouchPhase::Start,
            1 => egui::TouchPhase::Move,
            2 => egui::TouchPhase::End,
            _ => egui::TouchPhase::Cancel,
        };
        let pos = h.pt(x, y);
        h.push(egui::Event::Touch {
            device_id: egui::TouchDeviceId(0),
            id: egui::TouchId(id),
            phase,
            pos,
            force: if force > 0.0 { Some(force) } else { None },
        });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fc_scroll(h: *mut c_void, dx: f32, dy: f32, mods: u32) {
    if let Some(h) = unsafe { host(h) } {
        h.set_modifiers(to_mods(mods));
        let z = h.ctx.zoom_factor().max(0.1);
        let m = h.modifiers;
        h.push(egui::Event::MouseWheel {
            unit: egui::MouseWheelUnit::Point,
            delta: egui::vec2(dx / z, dy / z),
            phase: egui::TouchPhase::Move,
            source: egui::MouseWheelSource::Unknown,
            modifiers: m,
        });
    }
}

/// Trackpad pinch: a zoom factor for this step.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fc_zoom(h: *mut c_void, factor: f32) {
    if let Some(h) = unsafe { host(h) } {
        if !factor.is_finite() || factor <= 0.0 {
            return;
        }
        h.push(egui::Event::Zoom(factor));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fc_key(h: *mut c_void, hid: u32, pressed: c_int, repeat: c_int, mods: u32) {
    if let Some(h) = unsafe { host(h) } {
        h.set_modifiers(to_mods(mods));
        let Some(key) = hid_to_key(hid) else { return };
        let m = h.modifiers;
        h.push(egui::Event::Key { key, physical_key: Some(key), pressed: pressed != 0, repeat: repeat != 0, modifiers: m });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fc_text(h: *mut c_void, utf8: *const c_char) {
    if let Some(h) = unsafe { host(h) }
        && let Some(s) = unsafe { from_c(utf8) }
        && !s.is_empty()
    {
        h.push(egui::Event::Text(s));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fc_copy(h: *mut c_void) {
    if let Some(h) = unsafe { host(h) } {
        h.push(egui::Event::Copy);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fc_cut(h: *mut c_void) {
    if let Some(h) = unsafe { host(h) } {
        h.push(egui::Event::Cut);
    }
}

/// Command-V. `utf8` is the clipboard's text (empty when it holds a picture instead).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fc_paste(h: *mut c_void, utf8: *const c_char) {
    if let Some(h) = unsafe { host(h) } {
        let s = unsafe { from_c(utf8) }.unwrap_or_default();
        h.push(egui::Event::Paste(s));
    }
}

/// A file the person picked in Apple's Open sheet (or opened from Files into FigCraft).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fc_open_file(h: *mut c_void, name: *const c_char, data: *const u8, len: usize) {
    if let Some(h) = unsafe { host(h) }
        && let Some(name) = unsafe { from_c(name) }
    {
        note(&format!("a file arrived: {name}, {len} bytes"));
        let bytes = if data.is_null() || len == 0 { Vec::new() } else { unsafe { std::slice::from_raw_parts(data, len) }.to_vec() };
        let waiting = {
            let mut s = h.open.borrow_mut();
            let w = s.waiting;
            if w {
                s.waiting = false;
                s.result = Some(Some(Ok((name.clone(), bytes.clone()))));
                if let Some(waker) = s.waker.take() {
                    waker.wake();
                }
            }
            w
        };
        if !waiting {
            // Nobody asked (the file came from "Open in FigCraft"): open it like a dropped file.
            let read: figcraft_ui_egui::ReadFuture = Box::pin(std::future::ready(Ok(bytes)));
            h.fig.ui.pending_opens.push(figcraft_ui_egui::pending_open::PendingOpen {
                label: name.clone(),
                params: json!({ "name": name }),
                command: "file.open",
                target: None,
                read: Some(read),
            });
        }
        h.wake();
    }
}

/// The Open sheet was cancelled, or its file could not be read (`error` not null).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fc_open_cancel(h: *mut c_void, error: *const c_char) {
    if let Some(h) = unsafe { host(h) } {
        let err = unsafe { from_c(error) };
        let mut s = h.open.borrow_mut();
        if s.waiting {
            s.waiting = false;
            s.result = Some(err.map(Err));
            if let Some(waker) = s.waker.take() {
                waker.wake();
            }
        }
        drop(s);
        h.wake();
    }
}

/// The Save to Files sheet finished (ok = 1, with the name of the file the person chose) or was
/// cancelled (ok = 0). A saved .figcraft file gets a working copy in the app's Working folder:
/// from then on Save and AutoSave write there silently and the shell copies the result to the
/// chosen file. Save As does not use that path; it always asks.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fc_save_result(h: *mut c_void, ok: c_int, final_name: *const c_char) {
    guard((), || {
        let Some(h) = (unsafe { host(h) }) else { return };
        let asked = h.pending_save.borrow_mut().take();
        let chosen = unsafe { from_c(final_name) };
        let asked_name = asked.as_ref().map(|(n, _)| n.clone());
        let name = chosen.or(asked_name);
        let is_design = name.as_deref().is_some_and(|n| n.to_ascii_lowercase().ends_with(".figcraft"));
        if is_design && let Some(name) = name {
            let working = documents_dir().map(|d| d.join("Working").join(name.replace('/', "_")));
            if let Some(path) = working {
                if let Some(parent) = path.parent() {
                    let _ = std::fs::create_dir_all(parent);
                }
                if ok != 0 {
                    // The file becomes this document's own: later saves go to the working copy.
                    let r = h.fig.run("file.saveAs", json!({ "path": path.to_string_lossy() }));
                    note(&format!("working copy {} -> {}", path.display(), if r.is_some() { "ok" } else { "failed" }));
                } else if let Some((_, bytes)) = &asked {
                    // Cancelled: the app already counts the file as saved, so keep a copy.
                    let _ = std::fs::write(&path, bytes);
                    note(&format!("save cancelled, copy kept in {}", path.display()));
                }
            }
        }
        h.wake();
    })
}

/// Called every display refresh. Bit 0: a frame was drawn. Bit 1: the on-screen keyboard is wanted.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fc_frame(h: *mut c_void) -> c_int {
    guard(0, || match unsafe { host(h) } {
        Some(h) => h.frame(),
        None => 0,
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fc_save_state(h: *mut c_void) {
    if let Some(h) = unsafe { host(h) } {
        write_prefs(&h.fig.session.prefs);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn fc_is_dirty(h: *mut c_void) -> c_int {
    match unsafe { host(h) } {
        Some(h) => h.fig.session.docs.iter().any(|d| d.is_dirty()) as c_int,
        None => 0,
    }
}
