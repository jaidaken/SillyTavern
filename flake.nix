{
  description = "SillyTavern fork dev shell";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in
    {
      # package.json engines wants node >=26; npm ships inside nodejs.
      # esbuild is pinned here rather than fetched by `npx --yes` at build time: the client's
      # build.sh minifies four dist assets with it, and npx would resolve an unpinned version off
      # the network (or a cold cache would fail the build offline). The nixpkgs binary is Go, so
      # this step no longer needs node at all.
      devShells.x86_64-linux.default = pkgs.mkShell {
        packages = [ pkgs.nodejs_26 pkgs.esbuild ];
      };
    };
}
