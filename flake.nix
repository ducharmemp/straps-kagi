{
  description = "Kagi search and page extraction for straps.nvim";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/3ec636362e1816bc2f0888fa0fa2c69f1bc9e504";
  inputs.straps = { url = "github:ducharmemp/straps/7396033c8f3b59d0664a030e5cbd6457e77e9ef7"; flake = false; };
  inputs.nixpkgs-0_11.url = "github:NixOS/nixpkgs/ac62194c3917d5f474c1a844b6fd6da2db95077d";
  inputs.nixvim.url = "github:nix-community/nixvim/453dc9c5037e6d1bec81d2a51ddacd58a2f44e9c";
  inputs.nixvim.inputs.nixpkgs.follows = "nixpkgs";
  outputs = { self, nixpkgs, nixpkgs-0_11, nixvim, straps }:
    let
      lib = nixpkgs.lib;
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      each = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      pluginSource = lib.fileset.toSource { root = ./.; fileset = lib.fileset.unions [ ./lua ./doc ./README.md ./LICENSE ]; };
      mkPlugin = pkgs: pkgs.vimUtils.buildVimPlugin {
        pname = "straps-kagi";
        version = "dev";
        src = pluginSource;
        meta = { description = "Kagi search tools for straps.nvim"; license = lib.licenses.mit; };
      };
      testPackages = pkgs: neovim: [ neovim pkgs.luajitPackages.busted pkgs.luajitPackages.nlua pkgs.curl pkgs.bash pkgs.coreutils ];
      strapsFlake = (import "${straps}/flake.nix").outputs { self = straps // strapsFlake; inherit nixpkgs; };
      mkCheck = pkgs: neovim: pkgs.runCommand "straps-kagi-tests" { nativeBuildInputs = testPackages pkgs neovim; } ''
        cp -r ${self} source
        chmod -R u+w source
        cd source
        export HOME="$TMPDIR/home" STRAPS_ROOT=${straps}
        mkdir -p "$HOME"
        fail=0
        count=0
        for spec in tests/*_spec.lua; do
          [ -f "$spec" ] || continue
          count=$((count + 1))
          busted "$spec" || fail=1
        done
        [ "$count" -gt 0 ] && [ "$fail" -eq 0 ]
        touch "$out"
      '';
      module = { lib, config, pkgs, ... }:
        let cfg = config.plugins.straps-kagi;
        in {
          options.plugins.straps-kagi = {
            enable = lib.mkEnableOption "Kagi search tools for straps";
            package = lib.mkOption { type = lib.types.package; default = mkPlugin pkgs; description = "The straps-kagi plugin package."; };
            settings = lib.mkOption { type = with lib.types; attrsOf anything; default = {}; description = "Options passed to require('straps_kagi').setup()."; };
          };
          config = lib.mkIf cfg.enable {
            extraPlugins = [ cfg.package ];
            extraConfigLua = lib.mkAfter ''
              require("straps_kagi").setup(${lib.generators.toLua {} cfg.settings})
            '';
          };
        };
    in {
      packages = each (pkgs: { default = mkPlugin pkgs; straps-kagi = mkPlugin pkgs; });
      overlays.default = final: prev: { vimPlugins = prev.vimPlugins // { straps-kagi = mkPlugin final; }; };
      nixvimModules = { default = module; straps-kagi = module; };
      devShells = each (pkgs: {
        default = pkgs.mkShell { packages = testPackages pkgs pkgs.neovim; STRAPS_ROOT = toString straps; };
        nvim-0_11 = pkgs.mkShell {
          packages = testPackages pkgs nixpkgs-0_11.legacyPackages.${pkgs.stdenv.hostPlatform.system}.neovim;
          STRAPS_ROOT = toString straps;
        };
      });
      checks = each (pkgs: {
        tests = mkCheck pkgs pkgs.neovim;
        tests-0_11 = mkCheck pkgs nixpkgs-0_11.legacyPackages.${pkgs.stdenv.hostPlatform.system}.neovim;
        nixvim-startup = let
          editor = nixvim.legacyPackages.${pkgs.stdenv.hostPlatform.system}.makeNixvim {
            imports = [ strapsFlake.nixvimModules.default module ];
            plugins.straps.enable = true;
            plugins.straps-kagi.enable = true;
            nixpkgs.source = nixpkgs;
          };
        in pkgs.runCommand "straps-kagi-nixvim-startup" { nativeBuildInputs = [ editor ]; } ''
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"
          nvim --headless -c 'lua local ok = pcall(function() assert(require("straps_kagi").status().registered); assert(require("straps.registry").call("fn.capability", "search", {}) == "search") end); if not ok then vim.cmd("cquit 1") end' -c 'qa!'
          touch "$out"
        '';
      });
    };
}
