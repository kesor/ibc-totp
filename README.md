# IBKR TWS Docker Setup

NixOS-based Docker container for Interactive Brokers TWS with:
- Temurin JRE 21
- Xvfb (headless X server)
- x11vnc (VNC access)
- xfce (window manager)
- IBC (auto-login)

## Setup

1. Edit `docker/tws.secrets` with your IBKR credentials:
   ```
   TWS_USERNAME=your_username
   TWS_PASSWORD=your_password
   ```

2. Build and run:
   ```bash
   docker-compose up -d
   ```

3. Access via VNC:
   ```
   vncviewer localhost:5901
   ```

## Ports

- 5901: VNC server
