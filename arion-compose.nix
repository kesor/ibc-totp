{ pkgs, ... }:
{
  project.name = "ibkr";
  
  services.tws = {
    nixos.useSystemd = true;
    nixos.configuration = { config, pkgs, ... }: {
      
      # Install packages
      environment.systemPackages = with pkgs; [
        openjdk21
        javaPackages.openjfx21
        curl
        unzip
        xorg.xorgserver
        xorg.xauth
        xvfb-run
        x11vnc
        openbox
        tint2
        bash
        coreutils
        findutils
        gnused
        gnugrep
        util-linux
      ];
      
      # Create tws user
      users.users.tws = {
        isNormalUser = true;
        uid = 1000;
        home = "/home/tws";
      };
      
      # Environment
      environment.variables = {
        DISPLAY = ":0";
        TZ = "Asia/Jerusalem";
        FONTCONFIG_FILE = "/etc/fonts/fonts.conf";
      };
      
      # TWS service
      systemd.services.ibkr-tws = {
        description = "IBKR TWS with IBC";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        
        serviceConfig = {
          Type = "simple";
          User = "tws";
          WorkingDirectory = "/home/tws";
          Restart = "always";
          RestartSec = "10s";
        };
        
        script = ''
          # Will add the full startup script here
          sleep infinity
        '';
      };
    };
    
    service.useHostStore = true;
    service.ports = [ "5901:5900" ];
    service.volumes = [
      "tws-data:/home/tws/jts"
    ];
  };
}
