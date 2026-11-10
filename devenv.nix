let
  npmTools = pkgs: pkgs.callPackage ./pkgs/npm-tools.nix { };
  shell =
    { pkgs, ... }:
    let
      tools = npmTools pkgs;
    in
    {
      languages.elm.enable = true;
      languages.haskell.enable = true;
      languages.haskell.package = pkgs.haskell.packages.ghc96.ghc;
      dotenv.enable = true;
      env.NODE_PATH = "${tools}/lib/node_modules";
      packages = with pkgs; [
        cabal-install
        elmPackages.elm-format
        elmPackages.elm-json
        elmPackages.elm-review
        git
        haskell.packages.ghc96.hlint
        haskell.packages.ghc96.fourmolu
        nodejs_22
        pocketbase
        tools
      ];
      enterShell = ''
        ln -sfn "${tools}/lib/node_modules" node_modules
        ln -sfn "${tools}/lib/node_modules" elm-app/node_modules
      '';
      processes.pocketbase.exec = ''
        pocketbase serve --dir="$DEVENV_ROOT/.devenv/state/pocketbase/data" \
          --migrationsDir="$DEVENV_ROOT/fixtures/pb_migrations" \
          --hooksDir="$DEVENV_ROOT/fixtures/pb_hooks" --http=0.0.0.0:8090
      '';
    };
in
{
  profiles.shell.module.imports = [ shell ];
}
