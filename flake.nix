{
  description = "Static aarch64 payloads and tooling for phoenixd";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          static = pkgs.pkgsCross.aarch64-multiplatform-musl.pkgsStatic;
          phx-statusd = static.stdenv.mkDerivation {
            pname = "phx-statusd";
            version = "1.0.0";
            src = pkgs.lib.cleanSource ./modules/headless/src;
            buildPhase = "make";
            installPhase = ''
              mkdir -p $out/bin
              cp phx-statusd $out/bin/
              cp dns-forwarder $out/bin/
            '';
          };
          crossGlibc = pkgs.pkgsCross.aarch64-multiplatform;
          msm-vaapi-driver = crossGlibc.stdenv.mkDerivation {
            pname = "msm-vaapi-driver";
            version = "0.4.6";
            src = pkgs.fetchFromGitHub {
              owner = "Re-s";
              repo = "droidspaces-media-decode";
              rev = "v0.4.6";
              hash = "sha256-UjSsVVi1ighzXvlijS5WGTiKXtr6T/0J9rKKvL1hdtE=";
            };
            nativeBuildInputs = [ crossGlibc.buildPackages.pkg-config ];
            buildInputs = [ crossGlibc.libva crossGlibc.libdrm ];
            sourceRoot = "source/vaapi-driver";
            postPatch = ''
              substituteInPlace Makefile --replace-fail "pkg-config" "${crossGlibc.stdenv.cc.targetPrefix}pkg-config"
            '';
            makeFlags = [
              "AV1=1"
              "CC=${crossGlibc.stdenv.cc.targetPrefix}gcc"
            ];
            installPhase = ''
              mkdir -p $out/lib/dri
              cp build/msm_drm_drv_video.so $out/lib/dri/
            '';
          };
          mesa-kgsl = crossGlibc.stdenv.mkDerivation {
            pname = "mesa-kgsl";
            version = "24.3.4";
            src = pkgs.fetchurl {
              url = "https://archive.mesa3d.org/mesa-24.3.4.tar.xz";
              sha256 = "09b0ss722i7ldg2cw2wh3jlylzqv486md54n46cpaf0x34kswhg6";
            };
            nativeBuildInputs = [
              crossGlibc.buildPackages.meson
              crossGlibc.buildPackages.ninja
              crossGlibc.buildPackages.pkg-config
              crossGlibc.buildPackages.bison
              crossGlibc.buildPackages.flex
              (crossGlibc.buildPackages.python3.withPackages
                (p: [ p.mako p.pyyaml p.packaging ]))
            ];
            buildInputs = [
              crossGlibc.libdrm
              crossGlibc.zlib
            ];
            postPatch = ''
              patchShebangs src/
              substituteInPlace meson.build \
                --replace-fail "  if with_platform_android" "  if true"
              substituteInPlace src/util/cnd_monotonic.c \
                --replace-fail "pthread_cond_timedwait(&cond->cond, mtx, abs_time)" "pthread_cond_timedwait(&cond->cond, (pthread_mutex_t *)mtx, abs_time)" \
                --replace-fail "pthread_cond_wait(&cond->cond, mtx)" "pthread_cond_wait(&cond->cond, (pthread_mutex_t *)mtx)"
              substituteInPlace src/freedreno/vulkan/tu_shader.cc \
                --replace-fail "pthread_mutex_lock(&dev->pipeline_mutex)" "mtx_lock(&dev->pipeline_mutex)" \
                --replace-fail "pthread_mutex_unlock(&dev->pipeline_mutex)" "mtx_unlock(&dev->pipeline_mutex)"
              substituteInPlace src/freedreno/vulkan/tu_device.cc \
                --replace-fail ".KHR_display                         = true," ".KHR_display                         = false,"
              substituteInPlace src/freedreno/vulkan/tu_knl_kgsl.cc \
                --replace-fail "if (instance->vk.enabled_extensions.KHR_display) {" "if (false) {"
            '';
            mesonAutoFeatures = "disabled";
            mesonBuildType = "release";
            mesonFlags = [
              "-Dplatforms="
              "-Dgallium-drivers="
              "-Dvulkan-drivers=freedreno"
              "-Dfreedreno-kmds=kgsl,msm"
              "-Dglx=disabled"
              "-Dopengl=false"
              "-Db_ndebug=true"
            ];
          };
          layer1-drivers = pkgs.runCommand "layer1-drivers" {
            nativeBuildInputs = [ pkgs.patchelf ];
          } ''
            mkdir -p $out/lib/dri $out/share/vulkan/icd.d
            cp ${msm-vaapi-driver}/lib/dri/msm_drm_drv_video.so $out/lib/dri/
            cp ${mesa-kgsl}/lib/libvulkan_freedreno.so $out/lib/
            cp -d ${crossGlibc.libdrm.out}/lib/libdrm.so* $out/lib/

            chmod -R u+w $out/lib

            for f in $out/lib/*.so $out/lib/*.so.*; do
              if [ -f "$f" ] && [ ! -L "$f" ]; then
                patchelf --set-rpath '$ORIGIN:$ORIGIN/dri' "$f"
              fi
            done
            for f in $out/lib/dri/*.so; do
              if [ -f "$f" ] && [ ! -L "$f" ]; then
                patchelf --set-rpath '$ORIGIN:$ORIGIN/..' "$f"
              fi
            done

            cat << 'EOF' > $out/share/vulkan/icd.d/freedreno_icd.aarch64.json
            {
                "ICD": {
                    "api_version": "1.1.296",
                    "library_path": "libvulkan_freedreno.so"
                },
                "file_format_version": "1.0.0"
            }
            EOF
          '';
          layer1-bin = pkgs.runCommand "layer1-bin" { } ''
            mkdir -p $out/bin
            cp ${static.busybox}/bin/busybox $out/bin/busybox
            cp ${static.wpa_supplicant}/bin/wpa_supplicant \
              $out/bin/wpa_supplicant
            cp ${static.wpa_supplicant}/bin/wpa_cli $out/bin/wpa_cli
            cp ${static.iw}/bin/iw $out/bin/iw
            cp ${phx-statusd}/bin/phx-statusd $out/bin/phx-statusd
            cp ${phx-statusd}/bin/dns-forwarder $out/bin/dns-forwarder
          '';
        in
        {
          inherit layer1-bin phx-statusd msm-vaapi-driver mesa-kgsl layer1-drivers;
          default = layer1-bin;
        });

      devShells = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              android-tools
              beautysh
              clang-tools
              curl
              shellcheck
              xz
              zip
            ];
          };
        });
    };
}
