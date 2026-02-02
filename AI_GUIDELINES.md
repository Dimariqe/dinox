# AI Development Guidelines for DinoX

This document provides architectural context, coding standards, and "lessons learned" for AI agents working on the DinoX codebase. Usage of these guidelines ensures consistency and prevents regression of known issues.

## 1. Project Overview
- **Core Language:** Vala (compiles to C).
- **UI Toolkit:** GTK4 with Libadwaita.
- **Build System:** Meson / Ninja.
- **Primary Target:** Linux Desktop (Flatpak, AppImage).

## 2. Architecture Principles

### 2.1 Plugin Design (The "Tor-Manager" Pattern)
Complex plugins interacting with system processes MUST follow the Separation of Concerns pattern established in `plugins/tor-manager`:

1.  **`plugin.vala`**: Pure entry point. Registers the module with `stream_interactor`. No logic.
2.  **`manager.vala` (Logic Layer)**:
    - Should be the "Source of Truth".
    - Manages application state (Enabled/Disabled).
    - Synchronizes with the Database (`key config`).
    - managing Account connection logic.
3.  **`controller.vala` (Operation Layer)**:
    - Handles low-level OS interactions (Subprocess).
    - Agnostic of XMPP accounts or Database.
    - **Must** implement robust error handling (Zombie process killing, PID file management).
4.  **`ui_*.vala` (View Layer)**:
    - Visuals only. No business logic.
    - Binds signals to parameters in the Manager.

### 2.2 Asynchronous Patterns
- **Strict Rule:** Never block the main thread.
- Use Vala's `async` / `yield` syntax for:
    - File I/O (reading configs, avatars).
    - Network operations (unless handled by the XMPP stream).
    - Subprocess communication.
- *Example reference:* See `AvatarManager.publish` refactoring in v0.9.7.6.

## 3. Resource Management & Theming

### 3.1 Icon Precedence Pitfall
**CRITICAL:** GTK's icon lookup favors Scalable Vector Graphics (SVG) in `icons/scalable/` over Bitmap (PNG) in `icons/hicolor/`.
- If you update a PNG icon but an old SVG with the same ID exists in `gresource.xml` or the filesystem, **the App will display the old SVG**.
- **Fix:** Start by removing the conflicting SVG from `gresource.xml` and the source tree before updating PNGs.

### 3.2 Binary Resources
- Changes to `main/data/*.ui`, `*.css`, or icons require a full re-link.
- Always run `ninja -C build` to bake changes into the binary.

## 4. Packaging & Deployment

### 4.1 AppImage Construction
- The script `scripts/build-appimage.sh` manually copies shared libraries.
- **New Dependency Rule:** If you add a new GStreamer plugin or native library dependency, you **MUST** add it to the `copy_dependencies()` function in the build script.
- *Failure Case:* Missing `libgstaudiofx.so` caused silent failures in Audio calls.

## 5. Documentation References
- **Tor Implementation:** `docs/internal/TOR_IMPLEMENTATION.md`
- **AV Subsystem:** `docs/internal/AUDIO_VIDEO_COMPLETE_ANALYSIS.md`
