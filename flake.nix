{
  description = "Static aarch64 payloads and tooling for xiaomi_phoenix_server";

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
          layer1-bin = pkgs.runCommand "layer1-bin" { } ''
            mkdir -p $out/bin
            cp ${static.busybox}/bin/busybox $out/bin/busybox
            cp ${static.wpa_supplicant}/bin/wpa_supplicant $out/bin/wpa_supplicant
            cp ${static.wpa_supplicant}/bin/wpa_cli $out/bin/wpa_cli
            cp ${static.iw}/bin/iw $out/bin/iw
          '';
        in
        {
          inherit layer1-bin;
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
              curl
              shellcheck
              xz
              zip
            ];
          };
        });
    };
}
