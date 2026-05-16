{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/63dacb46bf939521bdc93981b4cbb7ecb58427a0";
    systems.url = "github:nix-systems/x86_64-linux";
    godot.url = "git+https://github.com/haruki7049/godot?rev=df193d656aad69c0efe33fa9278907c2341d7ce9&submodules=1";
    godot-haskell.url = "git+https://github.com/haruki7049/godot-haskell?rev=b06876dcd2add327778aea03ba81751a60849cc8&submodules=1";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import inputs.systems;

      imports = [ inputs.treefmt-nix.flakeModule ];

      perSystem =
        {
          pkgs,
          lib,
          system,
          ...
        }:
        let
          godot-haskell = inputs.godot-haskell.packages."${system}".godot-haskell;
          godot-haskell-plugin = pkgs.callPackage ./addons/godot-haskell-plugin { inherit godot-haskell; };
          godot-haskell-plugin-profiled = pkgs.callPackage ./addons/godot-haskell-plugin { inherit godot-haskell; profileBuild = true; };

          # `haskell-dependencies` contains shared libraries
          # This attribute is needed to pick up `${any-package}/lib/ghc-9.6.5/lib/x86_64-linux-ghc-9.6.5/*.so` for `pkgs.autoPatchelfHook`
          haskell-dependencies = pkgs.stdenvNoCC.mkDerivation rec {
            name = "haskell-dependencies";
            dontUnpack = true;

            buildInputs = [
              # godot-haskell-plugin dependencies
              pkgs.haskellPackages.QuickCheck
              pkgs.haskellPackages.base64-bytestring
              pkgs.haskellPackages.clock
              pkgs.haskellPackages.dhall
              pkgs.haskellPackages.extra
              pkgs.haskellPackages.hspec
              pkgs.haskellPackages.hspec-core
              pkgs.haskellPackages.http-client
              pkgs.haskellPackages.http-client-tls
              pkgs.haskellPackages.http-types
              pkgs.haskellPackages.inline-c
              pkgs.haskellPackages.io-streams
              pkgs.haskellPackages.iso8601-time
              pkgs.haskellPackages.ordered-containers
              pkgs.haskellPackages.path
              pkgs.haskellPackages.path-io
              pkgs.haskellPackages.process-extras
              pkgs.haskellPackages.raw-strings-qq
              pkgs.haskellPackages.safe-exceptions
              pkgs.haskellPackages.uuid
              godot-haskell
            ];

            installPhase = ''
              mkdir -p $out/lib
              cp -r ${
                lib.strings.concatStringsSep " " (
                  builtins.map (
                    drv:
                    "${drv}/lib/ghc-${pkgs.haskellPackages.ghc.version}/lib/${pkgs.stdenv.system}-ghc-${pkgs.haskellPackages.ghc.version}/*.so"
                  ) buildInputs
                )
              } $out/lib
            '';
          };

          # A source filter for Simula
          cleanSourceFilter =
            name: type:
            let
              baseName = baseNameOf (toString name);
            in
            !(
              (baseName == ".git")
              || lib.hasSuffix "~" baseName
              || builtins.match "^\\.sw[a-z]$" baseName != null
              || builtins.match "^\\..*\\.sw[a-z]$" baseName != null
              || lib.hasSuffix ".o" baseName
              #|| lib.hasSuffix ".so" baseName # ".so" cannot remove because dynamic libraries is used by Godot plugins
              || (type == "symlink" && lib.hasPrefix "result" baseName)
              || (type == "unknown")
            );

          # Simula package, with some tools:
          # | Package name             |
          # |--------------------------|
          # | pkgs.xpra                |
          # | pkgs.xfce.xfce4-terminal |
          # | pkgs.xorg.xrdb           |
          # | pkgs.wmctrl              |
          # | pkgs.ffmpeg              |
          # | pkgs.ffmpeg              |
          # | pkgs.midori              |
          # | pkgs.synapse             |
          # | pkgs.xsel                |
          # | pkgs.mimic               |
          # | pkgs.xclip               |
          # | pkgs.curl                |
          # | pkgs.i3status            |
          simula-src = pkgs.stdenv.mkDerivation {
            pname = "simula-src";
            version = "0.0.0-dev";
            src = ./.;
            installPhase = ''
              mkdir -p $out
              cp -rv . $out/
            '';
          };

          simula = pkgs.stdenv.mkDerivation rec {
            pname = "simula";
            version = "0.0.0-dev";

            nativeBuildInputs = [ pkgs.autoPatchelfHook pkgs.makeWrapper ];

            buildInputs = [
              haskell-dependencies
              "${godot-haskell-plugin}/lib/ghc-9.6.5/lib"
              "${godot-haskell-plugin}/lib/ghc-9.6.5/lib/x86_64-linux-ghc-9.6.5"
              "${haskell-dependencies}/lib"
              inputs.godot.packages."${system}".godot
              pkgs.systemd
              pkgs.openxr-loader
              pkgs.libuuid
              pkgs.libGL
              pkgs.libvdpau
              pkgs.libglvnd
              pkgs.xorg.libxcb
              pkgs.xorg.libXau
              pkgs.xorg.libXdmcp
              pkgs.xorg.libXmu
              pkgs.xorg.libSM
              pkgs.xorg.libICE
              pkgs.glib
              pkgs.mesa
              pkgs.libepoxy
              pkgs.vulkan-loader
              pkgs.xorg.libXres
              pkgs.xorg.libXrender
              pkgs.xorg.libXcomposite
              pkgs.xorg.libXcursor
              pkgs.xorg.libXdamage
              pkgs.xorg.libXi
              pkgs.xorg.libXtst
              pkgs.fira-code
            ];

            dontUnpack = true;

            installPhase = ''
              runHook preInstall

              mkdir -p $out/opt/simula
              cp -a ${simula-src}/. $out/opt/simula/
              chmod -R +w $out/opt/simula

              # Overlay our freshly built plugin
              cp -v ${godot-haskell-plugin}/lib/ghc-9.6.5/lib/libgodot-haskell-plugin.so $out/opt/simula/addons/godot-haskell-plugin/bin/x11/libgodot-haskell-plugin.so
              chmod 755 $out/opt/simula/addons/godot-haskell-plugin/bin/x11/libgodot-haskell-plugin.so

              # Ensure dependencies are found
              addAutoPatchelfSearchPath ${haskell-dependencies}/lib
              addAutoPatchelfSearchPath ${godot-haskell-plugin}/lib/ghc-9.6.5/lib
              addAutoPatchelfSearchPath ${godot-haskell-plugin}/lib/ghc-9.6.5/lib/x86_64-linux-ghc-9.6.5
              
              autoPatchelf $out/opt/simula
              echo "DEBUG: contents of $out after autoPatchelf:"
              ls -R $out

              # Install Simula runner
              mkdir -p $out/bin
              echo '#!/usr/bin/env sh

              set -o errexit
              set -o nounset
              set -o pipefail

              export PATH="${
                lib.makeBinPath [
                  inputs.godot.packages."${system}".godot
                  pkgs.xwayland
                  pkgs.xpra
                  pkgs.xfce.xfce4-terminal
                  pkgs.foot
                  pkgs.sakura
                  pkgs.kitty
                  pkgs.tmux
                  pkgs.xterm
                  pkgs.xorg.xrdb
                  pkgs.xorg.setxkbmap
                  pkgs.wmctrl
                  pkgs.ffmpeg
                  pkgs.midori
                  pkgs.synapse
                  pkgs.xsel
                  pkgs.mimic
                  pkgs.xclip
                  pkgs.curl
                  pkgs.i3status
                  pkgs.procps
                  pkgs.bottom
                  pkgs.steam-run
                  pkgs.fira-code
                ]
              }:$PATH"

              export LD_LIBRARY_PATH="${lib.makeLibraryPath buildInputs}"

              export XDG_CACHE_HOME=''${XDG_CACHE_HOME:-$HOME/.cache}
              export XDG_DATA_HOME=''${XDG_DATA_HOME:-$HOME/.local/share}
              export XDG_CONFIG_HOME=''${XDG_CONFIG_HOME:-$HOME/.config}

              export SIMULA_LOG_DIR="$XDG_CACHE_HOME/Simula"
              export SIMULA_DATA_DIR="$XDG_DATA_HOME/Simula"
              export SIMULA_CONFIG_DIR="$XDG_CONFIG_HOME/Simula"
              export SIMULA_APP_DIR="'$out'/bin"

              # Set real-time priority for Simula and VR processes only
              set_niceness() {
                if command -v sudo >/dev/null 2>&1 && command -v renice >/dev/null 2>&1; then
                  sudo renice -n -20 -p "$1" >/dev/null 2>&1 || true
                fi
                if command -v sudo >/dev/null 2>&1 && command -v ionice >/dev/null 2>&1; then
                  sudo ionice -c 1 -n 0 -p "$1" >/dev/null 2>&1 || true
                fi
              }
              set_priority_for() {
                for pid in $(pgrep -x "$1" 2>/dev/null); do set_niceness "$pid"; done
              }

              export SIMULA_APP_DIR="'$out'/bin"

              if grep -qi NixOS /etc/os-release; then
                  echo "NixOS detected. Running Simula..."

                  # Detect active X11 display
                  export DISPLAY="''${DISPLAY:-:0}"

                  # Verify SteamVR runtime exists
                  XR_RUNTIME_JSON_CANDIDATE="$HOME/.local/share/Steam/steamapps/common/SteamVR/steamxr_linux64.json"
                  if [ -f "$XR_RUNTIME_JSON_CANDIDATE" ]; then
                      export XR_RUNTIME_JSON="$XR_RUNTIME_JSON_CANDIDATE"
                  else
                      echo "Warning: SteamVR runtime not found at $XR_RUNTIME_JSON_CANDIDATE"
                      echo "VR headset may not be detected."
                  fi

                  export XKB_DEFAULT_LAYOUT="us"
                  export XKB_DEFAULT_VARIANT=""
                  export XKB_DEFAULT_OPTIONS=""
                  export XKB_CONFIG_ROOT="${pkgs.xorg.xkeyboardconfig}/share/X11/xkb"

                  godot -m "'$out'"/opt/simula/project.godot &
                  GODOT_PID=$!

                  # Set niceness + ionice only for godot, SteamVR, and ALVR
                  set_niceness "$GODOT_PID"
                  set_priority_for vrserver
                  set_priority_for vrcompositor
                  set_priority_for alvr

                  wait "$GODOT_PID"
              else
                echo "Detects non-NixOS distribution. Running Simula with nixGL..."
                nix run --impure github:nix-community/nixGL -- godot -m "'$out'"/opt/simula/project.godot
              fi' > $out/bin/simula
              chmod 766 $out/bin/simula

              # Symlink tools for Haskell code to find via SIMULA_APP_DIR or PATH
              mkdir -p $out/bin
              ln -s ${pkgs.xpra}/bin/xpra $out/bin/xpra
              ln -s ${pkgs.xfce.xfce4-terminal}/bin/xfce4-terminal $out/bin/xfce4-terminal
              ln -s ${pkgs.foot}/bin/foot $out/bin/foot
              ln -s ${pkgs.sakura}/bin/sakura $out/bin/sakura
              ln -s ${pkgs.kitty}/bin/kitty $out/bin/kitty
              ln -s ${pkgs.tmux}/bin/tmux $out/bin/tmux
              ln -s ${pkgs.xterm}/bin/xterm $out/bin/xterm
              ln -s ${pkgs.xorg.xrdb}/bin/xrdb $out/bin/xrdb
              ln -s ${pkgs.wmctrl}/bin/wmctrl $out/bin/wmctrl
              ln -s ${pkgs.i3status}/bin/i3status $out/bin/i3status
              ln -s ${pkgs.ffmpeg-full}/bin/ffplay $out/bin/ffplay
              ln -s ${pkgs.ffmpeg-full}/bin/ffmpeg $out/bin/ffmpeg
              ln -s ${pkgs.midori}/bin/midori $out/bin/midori
              ln -s ${pkgs.synapse}/bin/synapse $out/bin/synapse
              ln -s ${pkgs.xsel}/bin/xsel $out/bin/xsel
              ln -s ${pkgs.mimic}/bin/mimic $out/bin/mimic
              ln -s ${pkgs.xclip}/bin/xclip $out/bin/xclip
              ln -s ${pkgs.patchelf}/bin/patchelf $out/bin/patchelf
              ln -s ${pkgs.dialog}/bin/dialog $out/bin/dialog
              ln -s ${pkgs.curl}/bin/curl $out/bin/curl

              # Ensure .Xdefaults and config are in the right place for Haskell code
              cp -v ${simula-src}/.Xdefaults $out/.Xdefaults || true
              cp -rv ${simula-src}/config $out/config || true

              runHook postInstall
            '';

            meta = {
              mainProgram = "simula";
              homepage = "https://github.com/SimulaVR/Simula";
              license = lib.licenses.mit;
              platforms = lib.platforms.linux;
            };
          };
        in
        {
          _module.args.pkgs = import inputs.nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };

          treefmt = {
            projectRootFile = "project.godot";
            programs.nixfmt.enable = true;
          };

          packages = {
            inherit simula godot-haskell-plugin;
            default = simula;

            simula-debug = let
              godot-haskell-plugin' = godot-haskell-plugin-profiled;
            in pkgs.stdenv.mkDerivation rec {
              pname = "simula-debug";
              version = "0.0.0-debug";

              nativeBuildInputs = [ pkgs.autoPatchelfHook pkgs.makeWrapper ];

              buildInputs = [
                haskell-dependencies
                "${godot-haskell-plugin'}/lib/ghc-9.6.5/lib"
                "${godot-haskell-plugin'}/lib/ghc-9.6.5/lib/x86_64-linux-ghc-9.6.5"
                "${haskell-dependencies}/lib"
                inputs.godot.packages."${system}".godot
                pkgs.systemd
                pkgs.openxr-loader
                pkgs.libuuid
                pkgs.libGL
                pkgs.libvdpau
                pkgs.libglvnd
                pkgs.xorg.libxcb
                pkgs.xorg.libXau
                pkgs.xorg.libXdmcp
                pkgs.xorg.libXmu
                pkgs.xorg.libSM
                pkgs.xorg.libICE
                pkgs.glib
                pkgs.mesa
                pkgs.libepoxy
                pkgs.vulkan-loader
                pkgs.xorg.libXres
                pkgs.xorg.libXrender
                pkgs.xorg.libXcomposite
                pkgs.xorg.libXcursor
                pkgs.xorg.libXdamage
                pkgs.xorg.libXi
                pkgs.xorg.libXtst
                pkgs.fira-code
              ];

              dontUnpack = true;

              installPhase = ''
                runHook preInstall

                mkdir -p $out/opt/simula
                cp -a ${simula-src}/. $out/opt/simula/
                chmod -R +w $out/opt/simula

                cp -v ${godot-haskell-plugin'}/lib/ghc-9.6.5/lib/libgodot-haskell-plugin.so $out/opt/simula/addons/godot-haskell-plugin/bin/x11/libgodot-haskell-plugin.so
                chmod 755 $out/opt/simula/addons/godot-haskell-plugin/bin/x11/libgodot-haskell-plugin.so

                addAutoPatchelfSearchPath ${haskell-dependencies}/lib
                addAutoPatchelfSearchPath ${godot-haskell-plugin'}/lib/ghc-9.6.5/lib
                addAutoPatchelfSearchPath ${godot-haskell-plugin'}/lib/ghc-9.6.5/lib/x86_64-linux-ghc-9.6.5
                
                autoPatchelf $out/opt/simula

                mkdir -p $out/bin
                echo '#!/usr/bin/env sh

                set -o errexit
                set -o nounset
                set -o pipefail

                export PATH="${
                  lib.makeBinPath [
                    inputs.godot.packages."${system}".godot
                    pkgs.xwayland
                    pkgs.xpra
                    pkgs.xfce.xfce4-terminal
                  pkgs.foot
                  pkgs.sakura
                  pkgs.tmux
                    pkgs.xterm
                    pkgs.xorg.xrdb
                    pkgs.xorg.setxkbmap
                    pkgs.wmctrl
                    pkgs.ffmpeg
                    pkgs.midori
                    pkgs.synapse
                    pkgs.xsel
                    pkgs.mimic
                    pkgs.xclip
                    pkgs.curl
                    pkgs.i3status
                    pkgs.procps
                    pkgs.bottom
                    pkgs.steam-run
                    pkgs.fira-code
                  ]
                }:$PATH"

                export LD_LIBRARY_PATH="${lib.makeLibraryPath buildInputs}"

                export XDG_CACHE_HOME=''${XDG_CACHE_HOME:-$HOME/.cache}
                export XDG_DATA_HOME=''${XDG_DATA_HOME:-$HOME/.local/share}
                export XDG_CONFIG_HOME=''${XDG_CONFIG_HOME:-$HOME/.config}

                export SIMULA_LOG_DIR="$XDG_CACHE_HOME/Simula"
                export SIMULA_DATA_DIR="$XDG_DATA_HOME/Simula"
                export SIMULA_CONFIG_DIR="$XDG_CONFIG_HOME/Simula"
                export SIMULA_APP_DIR="'$out'/bin"

                set_niceness() {
                  if command -v sudo >/dev/null 2>&1 && command -v renice >/dev/null 2>&1; then
                    sudo renice -n -20 -p "$1" >/dev/null 2>&1 || true
                  fi
                  if command -v sudo >/dev/null 2>&1 && command -v ionice >/dev/null 2>&1; then
                    sudo ionice -c 1 -n 0 -p "$1" >/dev/null 2>&1 || true
                  fi
                }
                set_priority_for() {
                  for pid in $(pgrep -x "$1" 2>/dev/null); do set_niceness "$pid"; done
                }

                # RTS flags for profiling - override via GHCRTS env var
                export GHCRTS="''${GHCRTS:--hT -sstderr}"

                export DISPLAY="''${DISPLAY:-:0}"

                XR_RUNTIME_JSON_CANDIDATE="$HOME/.local/share/Steam/steamapps/common/SteamVR/steamxr_linux64.json"
                if [ -f "$XR_RUNTIME_JSON_CANDIDATE" ]; then
                    export XR_RUNTIME_JSON="$XR_RUNTIME_JSON_CANDIDATE"
                else
                    echo "Warning: SteamVR runtime not found at $XR_RUNTIME_JSON_CANDIDATE"
                fi

                if grep -qi NixOS /etc/os-release; then
                    echo "NixOS detected. Running Simula (DEBUG/PROFILING mode)..."
                    export XKB_DEFAULT_LAYOUT="us"
                    export XKB_DEFAULT_VARIANT=""
                    export XKB_DEFAULT_OPTIONS=""
                    export XKB_CONFIG_ROOT="${pkgs.xorg.xkeyboardconfig}/share/X11/xkb"
                    godot -m "'$out'"/opt/simula/project.godot &
                    GODOT_PID=$!
                    set_niceness "$GODOT_PID"
                    set_priority_for vrserver
                    set_priority_for vrcompositor
                    set_priority_for alvr
                    wait "$GODOT_PID"
                else
                  echo "Detects non-NixOS distribution. Running Simula with nixGL..."
                  nix run --impure github:nix-community/nixGL -- godot -m "'$out'"/opt/simula/project.godot
                fi' > $out/bin/simula-debug
                chmod 755 $out/bin/simula-debug

                ln -s ${pkgs.xpra}/bin/xpra $out/bin/xpra
                ln -s ${pkgs.xfce.xfce4-terminal}/bin/xfce4-terminal $out/bin/xfce4-terminal
                ln -s ${pkgs.foot}/bin/foot $out/bin/foot
                ln -s ${pkgs.sakura}/bin/sakura $out/bin/sakura
                ln -s ${pkgs.kitty}/bin/kitty $out/bin/kitty
                ln -s ${pkgs.tmux}/bin/tmux $out/bin/tmux
                ln -s ${pkgs.xterm}/bin/xterm $out/bin/xterm
                ln -s ${pkgs.xorg.xrdb}/bin/xrdb $out/bin/xrdb
                ln -s ${pkgs.wmctrl}/bin/wmctrl $out/bin/wmctrl
                ln -s ${pkgs.i3status}/bin/i3status $out/bin/i3status
                ln -s ${pkgs.ffmpeg-full}/bin/ffplay $out/bin/ffplay
                ln -s ${pkgs.ffmpeg-full}/bin/ffmpeg $out/bin/ffmpeg
                ln -s ${pkgs.midori}/bin/midori $out/bin/midori
                ln -s ${pkgs.synapse}/bin/synapse $out/bin/synapse
                ln -s ${pkgs.xsel}/bin/xsel $out/bin/xsel
                ln -s ${pkgs.mimic}/bin/mimic $out/bin/mimic
                ln -s ${pkgs.xclip}/bin/xclip $out/bin/xclip
                ln -s ${pkgs.patchelf}/bin/patchelf $out/bin/patchelf
                ln -s ${pkgs.dialog}/bin/dialog $out/bin/dialog
                ln -s ${pkgs.curl}/bin/curl $out/bin/curl

                cp -v ${simula-src}/.Xdefaults $out/.Xdefaults || true
                cp -rv ${simula-src}/config $out/config || true

                runHook postInstall
              '';

              meta = {
                mainProgram = "simula-debug";
                homepage = "https://github.com/SimulaVR/Simula";
                license = lib.licenses.mit;
                platforms = lib.platforms.linux;
              };
            };
          };

          devShells.default = pkgs.mkShell rec {
            nativeBuildInputs = [
              # A Simula runner, Godot engine forked by SimulaVR
              inputs.godot.packages."${system}".godot

              # Development tools
              pkgs.nil
              pkgs.just
              pkgs.inotify-tools
              pkgs.cabal-install
              pkgs.haskellPackages.ghc
            ];

            buildInputs = [
              # Add build dependencies you want to add LD_LIBRARY_PATH!!

              haskell-dependencies
              pkgs.zlib
            ];

            LD_LIBRARY_PATH = lib.makeLibraryPath buildInputs;

            shellHook = ''
              export PS1="\n[nix-shell:\w]$ "
            '';
          };
        };
    };
}
