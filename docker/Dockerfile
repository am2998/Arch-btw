FROM archlinux:latest

# Initialize pacman keyring and update
RUN pacman-key --init && \
    pacman-key --populate archlinux && \
    pacman -Sy --noconfirm archlinux-keyring && \
    pacman -Syu --noconfirm

# Install base packages
RUN pacman -S --noconfirm sudo git man \
    && pacman -Scc --noconfirm

# Install Python
RUN pacman -S --noconfirm \
    python \
    python-pip \
    && pacman -Scc --noconfirm

# Install supervisor via pip
RUN pip install --break-system-packages supervisor

# Install X11, XFCE, and VNC
RUN pacman -S --noconfirm \
    tigervnc \
    xorg-server \
    xorg-xinit \
    xorg-xdpyinfo \
    dbus \
    thunar \
    adwaita-icon-theme \
    xorg-fonts-base \
    && pacman -Scc --noconfirm

# Install noVNC
RUN git clone https://github.com/novnc/noVNC.git /usr/share/novnc && \
    git clone https://github.com/novnc/websockify /usr/share/novnc/utils/websockify && \
    ln -s /usr/share/novnc/vnc.html /usr/share/novnc/index.html

# Create regular user
RUN useradd -m -G wheel -s /bin/bash archuser && \
    echo "archuser:archuser" | chpasswd && \
    echo "archuser ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

USER root

# Setup directories
RUN mkdir -p /etc/supervisor/conf.d /var/log/supervisor

# Create supervisord configuration
RUN cat > /etc/supervisor/supervisord.conf << 'SUPERVISOR_EOF'
[supervisord]
nodaemon=true
user=root
logfile=/var/log/supervisor/supervisord.log
pidfile=/var/run/supervisord.pid

[program:vnc]
command=/usr/local/bin/start-vnc.sh
autostart=true
autorestart=true
stderr_logfile=/var/log/supervisor/vnc.err.log
stdout_logfile=/var/log/supervisor/vnc.out.log
user=archuser
environment=HOME="/home/archuser",USER="archuser",XDG_RUNTIME_DIR="/run/user/1000",DESKTOP_SESSION="xfce",XDG_SESSION_TYPE="x11"
stopwaitsecs=10
stopsignal=TERM

[program:novnc]
command=/usr/share/novnc/utils/websockify/run --web /usr/share/novnc 6080 localhost:5900
autostart=true
autorestart=true
stderr_logfile=/var/log/supervisor/novnc.err.log
stdout_logfile=/var/log/supervisor/novnc.out.log
stopwaitsecs=10
SUPERVISOR_EOF

# Create startup script with minimal X11 terminal
RUN cat > /usr/local/bin/start-vnc.sh << 'VNC_EOF'
#!/bin/bash
set -e

export XDG_RUNTIME_DIR=/run/user/1000

echo "Starting Xvnc server with terminal..."
Xvnc :0 -geometry 1920x1080 -depth 24 -rfbport 5900 -rfbauth /dev/null -SecurityTypes None &
VNC_PID=$!

# Wait for X server
export DISPLAY=:0
for i in {1..30}; do
    if xdpyinfo -display :0 >/dev/null 2>&1; then
        echo "X server ready!"
        break
    fi
    if ! kill -0 $VNC_PID 2>/dev/null; then
        echo "ERROR: Xvnc crashed"
        exit 1
    fi
    sleep 1
done

sleep 2

# Start XFCE
echo "Starting XFCE..."
export DESKTOP_SESSION=xfce
export XDG_SESSION_TYPE=x11

xfce4-session &

echo "XFCE is running. VNC server on port 5900."

wait $VNC_PID
VNC_EOF

RUN chmod +x /usr/local/bin/start-vnc.sh

# Main startup script
RUN cat > /usr/local/bin/start.sh << 'START_EOF'
#!/bin/bash
set -e

echo "Initializing Arch Linux Terminal Container..."

# Create runtime directory
mkdir -p /run/user/1000
chown archuser:archuser /run/user/1000
chmod 700 /run/user/1000

# Create log directory
mkdir -p /var/log/supervisor
chown -R root:root /var/log/supervisor

chown -R archuser:archuser  /home/archuser

echo "Starting supervisord..."
if command -v supervisord &> /dev/null; then
    exec supervisord -c /etc/supervisor/supervisord.conf
else
    echo "ERROR: supervisord not found"
    exit 1
fi
START_EOF

RUN chmod +x /usr/local/bin/start.sh

# Expose noVNC port
EXPOSE 6080

CMD ["/usr/local/bin/start.sh"]
