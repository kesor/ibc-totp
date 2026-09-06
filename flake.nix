{
  description = "Development environment for IBC (Interactive Brokers Controller)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        name = "ibc-dev";

        packages = with pkgs; [
          ant
          openjdk25
          curl
          unzip
        ];

        shellHook = ''
          TWS_JARS_DIR="$PWD/tws-jars/stable/jars"
          if [ ! -d "$TWS_JARS_DIR" ] || [ -z "$(ls -A "$TWS_JARS_DIR"/*.jar 2>/dev/null)" ]; then
            echo "=========================================="
            echo "Downloading and installing TWS..."
            mkdir -p tws-jars
            cd tws-jars
            curl -sL "https://download2.interactivebrokers.com/installers/tws/latest-standalone/tws-latest-standalone-linux-x64.sh" -o tws-installer.sh
            sed -i 's|\$INSTALL4J_JAVA_PREFIX "\$app_java_home/bin/java"|java|' tws-installer.sh
            echo -e "$PWD/stable\ny\nn" | bash tws-installer.sh -- -c 2>/dev/null
            rm tws-installer.sh
            cd ..
            echo "TWS installed to: $TWS_JARS_DIR"
            echo "=========================================="
          fi
          export IBC_BIN="$TWS_JARS_DIR"
          echo "IBC_BIN=$IBC_BIN"
          echo "Ready to build! cd IBC && ant dist"
        '';
      };
    };
}
