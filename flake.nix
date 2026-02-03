{
  description = "IBKR TWS with Arion";
  
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    arion.url = "github:hercules-ci/arion";
  };
  
  outputs = { self, nixpkgs, arion }: 
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      devShells.${system}.default = pkgs.mkShell {
        buildInputs = [
          arion.packages.${system}.arion
          pkgs.docker
        ];
      };
    };
}
