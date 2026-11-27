{
  description = "Quality of life OSC for mpv";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;

      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = lib.genAttrs supportedSystems;

      updateVersions =
        if builtins.pathExists ./updates then
          lib.pipe (builtins.readDir ./updates) [
            (lib.filterAttrs (_: type: type == "regular"))
            builtins.attrNames
            (builtins.filter (lib.hasSuffix ".txt"))
            (map (lib.removeSuffix ".txt"))
            (builtins.sort lib.versionOlder)
          ]
        else
          [ ];

      pkgVersion =
        if updateVersions != [ ] then lib.last updateVersions else (self.shortRev or "0-unstable");

      mkMaterialOsc =
        pkgs:
        pkgs.mpvScripts.buildLua (finalAttrs: {
          pname = "material-osc";
          version = pkgVersion;

          src = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./bundle.py
              ./fonts
              ./src
            ];
          };

          dontBuild = false;

          nativeBuildInputs = [
            (pkgs.python3.withPackages (ps: [ ps.fonttools ]))
          ];

          runtime-dependencies = [ pkgs.curl ];

          buildPhase = ''
            runHook preBuild
            python3 bundle.py "${finalAttrs.version}"
            runHook postBuild
          '';

          scriptPath = "build/${finalAttrs.version}/scripts/material-osc.lua";

          postInstall = ''
            mkdir -p "$out/share/mpv/fonts"
            for font in "build/${finalAttrs.version}/fonts"/*; do
              [ -f "$font" ] || continue
              name="$(basename "$font")"
              case "$name" in
                *.otf) subdir="opentype" ;;
                *.ttf) subdir="truetype" ;;
                *) subdir="misc" ;;
              esac
              install -Dm644 "$font" "$out/share/fonts/$subdir/$name"
              ln -s "$out/share/fonts/$subdir/$name" "$out/share/mpv/fonts/$name"
            done
          '';

          passthru.fontDirectories = [ "${finalAttrs.finalPackage}/share/fonts" ];

          meta = {
            description = "Quality of life OSC for mpv";
            homepage = "https://github.com/brahmkshatriya/material-osc";
            license = with lib.licenses; [
              gpl3Only # material-osc Lua source
              ofl # Google Sans Flex
              asl20 # Material Symbols Rounded
            ];
            platforms = lib.platforms.all;
          };
        });
    in
    {
      overlays.default = final: prev: {
        mpvScripts = prev.mpvScripts.overrideScope (
          _scriptFinal: _scriptPrev: {
            material-osc = mkMaterialOsc final;
          }
        );
      };

      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          material-osc = mkMaterialOsc pkgs;
        in
        {
          inherit material-osc;
          default = material-osc;
          mpv = pkgs.mpv.override {
            scripts = [
              material-osc
              pkgs.mpvScripts.thumbfast
            ];
          };
        }
      );

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = lib.getExe self.packages.${system}.mpv;
          meta = {
            description = "Run mpv with Material OSC and thumbfast preloaded";
          };
        };
      });

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShellNoCC {
            packages = [
              (pkgs.python3.withPackages (ps: [ ps.fonttools ]))
              pkgs.curl
              pkgs.mpv
            ];
          };
        }
      );

      checks = forAllSystems (system: {
        inherit (self.packages.${system}) material-osc;
      });
    };
}
