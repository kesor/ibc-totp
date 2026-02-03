{ pkgs, ... }:
{
  project.name = "ibkr";
  
  services.tws = {
    service.build.context = "./docker";
    service.ports = [ "5901:5900" ];
    service.volumes = [
      "tws-data:/home/tws/jts"
    ];
    service.secrets = [{
      source = "tws";
      target = "/run/secrets/tws";
    }];
    service.restart = "unless-stopped";
    service.environment = {
      DISPLAY = ":0";
      TZ = "Asia/Jerusalem";
    };
  };
  
  docker-compose.raw.secrets = {
    tws.file = "./docker/tws.secrets";
  };
  
  docker-compose.raw.volumes = {
    tws-data = {};
  };
}
