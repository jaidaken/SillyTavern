{
  description = "SillyTavern fork dev shell";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in
    {
      # package.json engines wants node >=26; npm ships inside nodejs.
      devShells.x86_64-linux.default = pkgs.mkShell {
        packages = [ pkgs.nodejs_26 ];
      };
    };
}
