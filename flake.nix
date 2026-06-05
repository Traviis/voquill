{
  description = "Voquill — AI voice dictation desktop app";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    crane.url = "github:ipetkov/crane";
  };

  outputs = { nixpkgs, rust-overlay, crane, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ rust-overlay.overlays.default ];
      };
      lib = pkgs.lib;
      craneLib = crane.mkLib pkgs;

      targetTriple = "x86_64-unknown-linux-gnu";

      repoSrc = lib.cleanSourceWith {
        src = ./.;
        filter = path: type:
          let base = baseNameOf (toString path);
          in base != "flake.nix" && base != "flake.lock";
      };

      # Libraries loaded via dlopen at runtime (not in RUNPATH)
      runtimeLibs = with pkgs; [
        vulkan-loader
        libGL
        gtk3
        webkitgtk_4_1
        libayatana-appindicator
        librsvg
        alsa-lib
        libpulseaudio
        libxkbcommon
      ];

      # Shared native build inputs for Rust crates that use bindgen/cmake
      whisperNativeBuildInputs = with pkgs; [
        cmake
        pkg-config
        llvmPackages.clang
        rustPlatform.bindgenHook
        git
      ];

      # ──────────────────────────────────────────────
      #  Whisper transcription sidecars (CPU + GPU)
      #  Uses crane for deps caching — source-only rebuilds are fast.
      # ──────────────────────────────────────────────
      transcriptionSrc = lib.cleanSourceWith {
        src = ./packages/rust_transcription;
        filter = path: type:
          (craneLib.filterCargoSources path type) || lib.hasSuffix ".h" path
          || lib.hasSuffix ".c" path || lib.hasSuffix ".cpp" path
          || lib.hasSuffix ".metal" path || lib.hasSuffix ".comp" path;
      };

      transcriptionCommonArgs = {
        src = transcriptionSrc;
        strictDeps = true;
        nativeBuildInputs = whisperNativeBuildInputs
          ++ (with pkgs; [ shaderc ]);
        buildInputs = with pkgs; [ vulkan-loader vulkan-headers ];
        doCheck = false;
      };

      transcriptionDeps = craneLib.buildDepsOnly (transcriptionCommonArgs // {
        pname = "voquill-transcription-deps";
        version = "0.1.0";
        cargoExtraArgs = "--features gpu,gpu-vulkan";
      });

      sidecarCpu = craneLib.buildPackage (transcriptionCommonArgs // {
        pname = "voquill-sidecar-cpu";
        version = "0.1.0";
        cargoArtifacts = transcriptionDeps;
        cargoExtraArgs = "--bin rust-transcription-cpu";
      });

      sidecarGpu = craneLib.buildPackage (transcriptionCommonArgs // {
        pname = "voquill-sidecar-gpu";
        version = "0.1.0";
        cargoArtifacts = transcriptionDeps;
        cargoExtraArgs =
          "--bin rust-transcription-gpu --features gpu,gpu-vulkan";
      });

      # ──────────────────────────────────────────────
      #  GTK pill overlay (Wayland layer-shell)
      #  Uses crane for deps caching.
      # ──────────────────────────────────────────────
      gtkPillSrc = craneLib.cleanCargoSource ./packages/rust_gtk_pill;

      gtkPillCommonArgs = {
        src = gtkPillSrc;
        strictDeps = true;
        nativeBuildInputs = with pkgs; [ pkg-config ];
        buildInputs = with pkgs; [ gtk3 gtk-layer-shell ];
        doCheck = false;
      };

      gtkPillDeps = craneLib.buildDepsOnly (gtkPillCommonArgs // {
        pname = "voquill-gtk-pill-deps";
        version = "0.1.0";
      });

      gtkPill = craneLib.buildPackage (gtkPillCommonArgs // {
        pname = "voquill-gtk-pill";
        version = "0.1.0";
        cargoArtifacts = gtkPillDeps;
      });

      # ──────────────────────────────────────────────
      #  Frontend (pnpm workspace + Vite build)
      # ──────────────────────────────────────────────
      frontend = pkgs.stdenv.mkDerivation (finalAttrs: {
        pname = "voquill-frontend";
        version = "0.1.0";
        src = lib.cleanSourceWith {
          src = repoSrc;
          filter = path: type:
            let
              relPath = lib.removePrefix (toString ./. + "/") (toString path);
              isRustArtifact = lib.hasPrefix "packages/rust_" relPath
                && !(lib.hasSuffix "/Cargo.toml" relPath
                  || lib.hasSuffix "/Cargo.lock" relPath
                  || lib.hasInfix "/src/" relPath);
              isTarget = lib.hasInfix "/target/" relPath;
              isMobile = lib.hasPrefix "mobile/" relPath;
              isDotJj = lib.hasPrefix ".jj/" relPath;
              isResult = relPath == "result";
            in !(isRustArtifact || isTarget || isMobile || isDotJj || isResult);
        };

        pnpmDeps = pkgs.fetchPnpmDeps {
          inherit (finalAttrs) pname version src;
          pnpm = pkgs.pnpm_10;
          hash = "sha256-RylMZU/3MYR7rKJrOSD2PNcF1OMAdN8TCPztbQTsk90=";
          fetcherVersion = 3;
        };

        nativeBuildInputs = with pkgs; [ nodejs pnpm_10 pnpmConfigHook ];

        env.FLAVOR = "dev";
        env.VITE_FLAVOR = "dev";

        buildPhase = ''
          runHook preBuild
          pnpm exec turbo run build --filter=desktop...
          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall
          mkdir -p $out
          cp -r apps/desktop/dist/* $out/
          runHook postInstall
        '';
      });

      # ──────────────────────────────────────────────
      #  Tauri desktop app (Rust)
      #  Uses buildRustPackage — crane can't handle path+git deps with sourceRoot.
      # ──────────────────────────────────────────────
      desktopSrc = pkgs.runCommand "voquill-desktop-src" { } ''
        cp -r ${repoSrc} $out
        chmod -R u+w $out
        mkdir -p $out/apps/desktop/dist
        cp -r ${frontend}/* $out/apps/desktop/dist/
        mkdir -p $out/apps/desktop/src-tauri/binaries
        cp ${sidecarCpu}/bin/rust-transcription-cpu \
          "$out/apps/desktop/src-tauri/binaries/rust-transcription-cpu-${targetTriple}"
        cp ${sidecarGpu}/bin/rust-transcription-gpu \
          "$out/apps/desktop/src-tauri/binaries/rust-transcription-gpu-${targetTriple}"
        mkdir -p $out/apps/desktop/src-tauri/resources
        cp ${gtkPill}/bin/voquill-gtk-pill $out/apps/desktop/src-tauri/resources/voquill-gtk-pill
      '';

      desktop = pkgs.rustPlatform.buildRustPackage {
        pname = "voquill-desktop";
        version = "0.1.0";
        src = desktopSrc;
        sourceRoot = "${desktopSrc.name}/apps/desktop/src-tauri";

        cargoLock = {
          lockFile = ./apps/desktop/src-tauri/Cargo.lock;
          outputHashes = {
            "ferrous-focus-0.4.1" =
              "sha256-r2S76pQXfA7BMFVfueB9mesPcJu6Ejv3trZx/9c8ldQ=";
            "rdev-0.5.0-2" =
              "sha256-ubO66nZawEjU8pnQnfXHTVcfnDJ51IOFPsAxqp8NnkE=";
          };
        };

        nativeBuildInputs = with pkgs; [ pkg-config ];
        buildInputs = with pkgs; [
          gtk3
          gtk-layer-shell
          webkitgtk_4_1
          libayatana-appindicator
          librsvg
          openssl
          alsa-lib
          libpulseaudio
          libxkbcommon
          xdotool
          libx11
          libxtst
        ];

        env.FLAVOR = "dev";

        doCheck = false;
        buildFeatures = [ "tauri/custom-protocol" ];
      };

      # ──────────────────────────────────────────────
      #  Final assembled + wrapped package
      # ──────────────────────────────────────────────
      voquill = pkgs.stdenv.mkDerivation {
        pname = "voquill";
        version = "0.1.0";
        dontUnpack = true;
        nativeBuildInputs = [ pkgs.makeWrapper ];

        installPhase = ''
                    runHook preInstall

                    mkdir -p $out/bin $out/lib/Voquill/binaries $out/lib/Voquill/resources
                    mkdir -p $out/share/applications $out/share/icons/hicolor/128x128/apps

                    # Main binary (must be in bin/ so Tauri resolves ../lib/Voquill for resources)
                    install -m755 ${desktop}/bin/Voquill $out/bin/Voquill

                    # Sidecars (canonical location with target triple suffix)
                    install -m755 ${sidecarCpu}/bin/rust-transcription-cpu \
                      "$out/lib/Voquill/binaries/rust-transcription-cpu-${targetTriple}"
                    install -m755 ${sidecarGpu}/bin/rust-transcription-gpu \
                      "$out/lib/Voquill/binaries/rust-transcription-gpu-${targetTriple}"

                    # Sidecars next to binary (shell plugin strips path to last component, no triple)
                    ln -s "$out/lib/Voquill/binaries/rust-transcription-cpu-${targetTriple}" \
                      "$out/bin/rust-transcription-cpu"
                    ln -s "$out/lib/Voquill/binaries/rust-transcription-gpu-${targetTriple}" \
                      "$out/bin/rust-transcription-gpu"

                    # Resources
                    install -m755 ${gtkPill}/bin/voquill-gtk-pill \
                      $out/lib/Voquill/resources/voquill-gtk-pill
                    install -m755 ${
                      ./apps/desktop/src-tauri/resources/trigger-hotkey.sh
                    } \
                      $out/lib/Voquill/resources/trigger-hotkey.sh

                    # Icon
                    install -m644 ${
                      ./apps/desktop/src-tauri/icons/128x128.png
                    } \
                      $out/share/icons/hicolor/128x128/apps/voquill.png

                    # Desktop entry
                    cat > $out/share/applications/voquill.desktop <<'EOF'
          [Desktop Entry]
          Type=Application
          Name=Voquill
          Comment=AI voice dictation with local Whisper transcription
          Exec=voquill %U
          Icon=voquill
          Terminal=false
          Categories=Audio;Utility;
          Keywords=voice;dictation;transcription;whisper;
          StartupWMClass=Voquill
          EOF

                    # Wrapper sets LD_LIBRARY_PATH for dlopen'd libs
                    makeWrapper $out/bin/Voquill $out/bin/voquill \
                      --prefix LD_LIBRARY_PATH : "${
                        lib.makeLibraryPath runtimeLibs
                      }" \
                      --prefix PATH : "${lib.makeBinPath [ pkgs.wtype ]}"

                    runHook postInstall
        '';

        meta = with lib; {
          description =
            "AI voice dictation — local Whisper transcription with GPU acceleration";
          homepage = "https://github.com/voquill/voquill";
          platforms = [ "x86_64-linux" ];
          mainProgram = "voquill";
        };
      };

      # Dev shell toolchain (uses rust-overlay for latest stable)
      rustToolchain = pkgs.rust-bin.stable.latest.default.override {
        extensions = [ "rust-src" "rustfmt" "clippy" ];
      };
    in {
      packages.${system} = {
        inherit sidecarCpu sidecarGpu gtkPill frontend desktop voquill;
        default = voquill;
      };

      devShells.${system}.default = pkgs.mkShell {
        nativeBuildInputs = with pkgs; [
          rustToolchain
          cargo-tauri
          cmake
          pkg-config
          nodejs
          pnpm
        ];

        buildInputs = with pkgs; [
          gtk3
          gtk-layer-shell
          webkitgtk_4_1
          libayatana-appindicator
          librsvg
          openssl
          alsa-lib
          libpulseaudio
          libxkbcommon
          ydotool
          xdotool
          libx11
          libxtst
          vulkan-loader
          vulkan-headers
          shaderc
          clang
        ];

        shellHook = ''
          export LD_LIBRARY_PATH="${
            lib.makeLibraryPath runtimeLibs
          }:$LD_LIBRARY_PATH"
          export LIBCLANG_PATH="${pkgs.llvmPackages.libclang.lib}/lib"
          export BINDGEN_EXTRA_CLANG_ARGS="-isystem ${pkgs.llvmPackages.libclang.lib}/lib/clang/${pkgs.llvmPackages.libclang.version}/include"
        '';
      };
    };
}
