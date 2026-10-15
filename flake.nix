{
  description = "Build a portable anylinux AppImage from a Nix package";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];

      # what quick-sharun checks for, plus nix to evaluate the closure of the
      # application and curl/wget to fetch quick-sharun and the AppImage
      # tooling. quick-sharun wants xvfb-run as well when it traces GUI
      # applications, which is worth adding by hand if you package one.
      tooling = pkgs: with pkgs; [
        binutils
        coreutils
        curl
        findutils
        gawk
        glibc.bin
        gnugrep
        gnused
        gnutar
        nix
        patchelf
        strace
        wget
      ];

      niximage = pkgs: pkgs.writeShellScriptBin "niximage" ''
        export PATH="${pkgs.lib.makeBinPath (tooling pkgs)}:$PATH"
        exec ${./niximage.sh} "$@"
      '';

      # bind an application to the packager. The application is a dependency of
      # the result, so running this builds it first, and APP_STORE_PATH saves
      # the packager from having to evaluate the flake again.
      mkAppImage = pkgs: { package, name ? (package.pname or package.name), mainBin ? name, ... }:
        pkgs.writeShellScriptBin "niximage-${name}" ''
          export APPNAME="''${APPNAME:-${name}}"
          export MAIN_BIN="''${MAIN_BIN:-${mainBin}}"
          export APP_STORE_PATH="''${APP_STORE_PATH:-${package}}"
          exec ${niximage pkgs}/bin/niximage "$@"
        '';
    in
    {
      lib.mkAppImage = mkAppImage;

      packages = nixpkgs.lib.genAttrs systems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          niximage = niximage pkgs;
          hello-appimage = mkAppImage pkgs { package = pkgs.hello; mainBin = "hello"; };
          default = niximage pkgs;
        });

      apps = nixpkgs.lib.genAttrs systems (system:
        {
          niximage = {
            type = "app";
            program = "${self.packages.${system}.niximage}/bin/niximage";
          };
          hello-appimage = {
            type = "app";
            program = "${self.packages.${system}.hello-appimage}/bin/niximage-hello";
          };
          default = self.apps.${system}.niximage;
        });

      devShells = nixpkgs.lib.genAttrs systems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell { packages = tooling pkgs; };
        });
    };
}
