# Nix-managed frontend tools, built from the locked package manifest below.
{ pkgs }:
import ../vendor/master-builder/pkgs/mk-npm-tools.nix {
  inherit pkgs;
  name = "tabcat";
  src = ./.;
  hash = "sha256-OUp1NmxTQsIX73mZMCVPRQGLkYzvWF0hQwDNV5AOnlo=";
}
