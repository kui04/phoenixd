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
          inherit layer1-bin phx-statusd;
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
