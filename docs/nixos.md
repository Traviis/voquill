# NixOS

The repository includes a Nix flake that builds Voquill and all of its sidecars entirely from source. No pre-built binaries or containers are required.

## Quick start

```sh
# Build
nix build github:voquill/voquill

# Install into your profile
nix profile install github:voquill/voquill

# Run
voquill
```

The flake also provides a dev shell with the full Rust + Node toolchain:

```sh
nix develop   # or use direnv with `use flake`
```

## What the flake builds

| Output | Description |
| --- | --- |
| `sidecarCpu` | Whisper transcription sidecar (CPU) |
| `sidecarGpu` | Whisper transcription sidecar (Vulkan GPU) |
| `gtkPill` | GTK pill overlay (Wayland layer-shell) |
| `frontend` | pnpm/Vite workspace build |
| `desktop` | Tauri desktop app (Rust) |
| `voquill` (default) | Assembled package with wrapper, desktop entry, and icon |

Build individual components with `nix build .#sidecarGpu`, etc.

## System configuration

The flake handles build-time and runtime library dependencies. The following system-level configuration is needed for full functionality on NixOS.

### Input simulation (required for typing output)

Voquill uses ydotool (Wayland) and wtype (Hyprland/Sway) to inject keystrokes into other applications. The wrapper bundles wtype, but ydotool requires a system service and group membership.

Add to your NixOS configuration:

```nix
{
  programs.ydotool.enable = true;

  users.users.<your-username>.extraGroups = [ "ydotool" "input" ];
}
```

Rebuild and **reboot** (or re-login) for group membership to take effect.

### Vulkan (required for GPU transcription)

Most NixOS desktop configurations already include Vulkan support. Verify with:

```sh
vulkaninfo --summary
```

If not configured, add:

```nix
{
  hardware.graphics.enable = true;
}
```

For AMD GPUs, the `amdgpu` kernel driver and Mesa Vulkan driver are typically loaded automatically.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `GTK pill binary not found` | Resource directory not resolved | Ensure you're running the `voquill` wrapper (lowercase), not `Voquill` directly |
| `wtype not found in PATH` | Not using the wrapper | Run via the `voquill` command or .desktop entry |
| `ydotoold not running` | ydotool service not enabled | `programs.ydotool.enable = true` in NixOS config |
| Typing doesn't appear in other apps | Missing group membership | Add user to `ydotool` and `input` groups, then reboot |
| `Failed to load Stripe.js` | No internet / expected offline | Non-fatal; Voquill works fully offline for local transcription |
