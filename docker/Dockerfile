FROM archlinux:latest

# Initialize pacman keyring and update
RUN pacman-key --init && \
    pacman-key --populate archlinux && \
    pacman -Sy --noconfirm archlinux-keyring && \
    pacman -Syu --noconfirm

# Install base packages, Python, and supervisor
RUN pacman -S --noconfirm sudo git man python python-pip && \
    pacman -Scc --noconfirm && \
    pip install --break-system-packages supervisor

# Install X11, Cinnamon, and VNC
RUN pacman -S --noconfirm \
    tigervnc \
    xorg-server \
    xorg-xinit \
    xorg-xdpyinfo \
    xorg-xrandr \
    dbus \
    cinnamon \
    nemo \
    ghostty \
    eza \
    fzf \
    adwaita-icon-theme \
    ttf-meslo-nerd \
    mesa \
    mesa-utils \
    xf86-video-dummy \
    && pacman -Scc --noconfirm

# Install noVNC and create custom index
RUN git clone https://github.com/novnc/noVNC.git /usr/share/novnc && \
    git clone https://github.com/novnc/websockify /usr/share/novnc/utils/websockify && \
    printf '<!DOCTYPE html>\n<html>\n<head>\n    <meta http-equiv="refresh" content="0; url=vnc.html?resize=remote" />\n</head>\n<body>\n    <p>Redirecting to VNC...</p>\n</body>\n</html>\n' > /usr/share/novnc/index.html

# Create user and configure bashrc
RUN useradd -m -G wheel -s /bin/bash archuser && \
    echo "archuser:archuser" | chpasswd && \
    echo "archuser ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers && \
    printf '# .bashrc\n\n[[ $- != *i* ]] && return\n\nalias ls="eza -lha --icons --group-directories-first"\n\nsource /usr/share/fzf/key-bindings.bash\nsource /usr/share/fzf/completion.bash\n\nPS1="\\[\\e[1;32m\\]\\u@\\h\\[\\e[0m\\]:\\[\\e[1;34m\\]\\w\\[\\e[0m\\]\\$ "\n' > /home/archuser/.bashrc && \
    chown archuser:archuser /home/archuser/.bashrc

USER root

# Setup supervisor directories and configuration
RUN mkdir -p /etc/supervisor/conf.d /var/log/supervisor && \
    cat > /etc/supervisor/supervisord.conf << 'SUPERVISOR_EOF'
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
environment=HOME="/home/archuser",USER="archuser",XDG_RUNTIME_DIR="/run/user/1000",DESKTOP_SESSION="cinnamon",XDG_SESSION_TYPE="x11",LIBGL_ALWAYS_SOFTWARE="1",MUTTER_DEBUG_FORCE_KMS_MODE="simple"
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

# Create startup script with dynamic resolution
RUN printf '#!/bin/bash\n\
set -e\n\
\n\
export XDG_RUNTIME_DIR=/run/user/1000\n\
\n\
echo "Setting up VNC password..."\n\
mkdir -p /home/archuser/.vnc\n\
echo "archuser" | vncpasswd -f > /home/archuser/.vnc/passwd\n\
chmod 600 /home/archuser/.vnc/passwd\n\
chown -R archuser:archuser /home/archuser/.vnc\n\
\n\
echo "Starting Xvnc server..."\n\
Xvnc :0 -geometry 1920x1080 -depth 24 -rfbport 5900 -rfbauth /home/archuser/.vnc/passwd \\\n\
  -SecurityTypes VncAuth -AcceptSetDesktopSize=1 -SendCutText=0 -AcceptCutText=0 &\n\
VNC_PID=$!\n\
\n\
export DISPLAY=:0\n\
for i in {1..30}; do\n\
    if xdpyinfo -display :0 >/dev/null 2>&1; then\n\
        echo "X server ready!"\n\
        break\n\
    fi\n\
    if ! kill -0 $VNC_PID 2>/dev/null; then\n\
        echo "ERROR: Xvnc crashed"\n\
        exit 1\n\
    fi\n\
    sleep 1\n\
done\n\
\n\
sleep 2\n\
\n\
echo "Starting D-Bus session..."\n\
eval $(dbus-launch --sh-syntax)\n\
export DBUS_SESSION_BUS_ADDRESS\n\
export DBUS_SESSION_BUS_PID\n\
\n\
echo "Starting Cinnamon..."\n\
export DESKTOP_SESSION=cinnamon\n\
export XDG_SESSION_TYPE=x11\n\
export HOME=/home/archuser\n\
export LIBGL_ALWAYS_SOFTWARE=1\n\
export MUTTER_DEBUG_FORCE_KMS_MODE=simple\n\
cd /home/archuser\n\
\n\
# Disable hardware acceleration for Cinnamon\n\
mkdir -p /home/archuser/.config/cinnamon\n\
echo "[Settings]" > /home/archuser/.config/cinnamon/cinnamon-settings.ini\n\
echo "disable-all-effects=true" >> /home/archuser/.config/cinnamon/cinnamon-settings.ini\n\
\n\
cinnamon-session &\n\
\n\
echo "Cinnamon is running. VNC server on port 5900."\n\
\n\
wait $VNC_PID\n' > /usr/local/bin/start-vnc.sh && chmod +x /usr/local/bin/start-vnc.sh

# Main startup script
RUN printf '#!/bin/bash\n\
set -e\n\
\n\
echo "Initializing Arch Linux Terminal Container..."\n\
\n\
mkdir -p /run/user/1000\n\
chown archuser:archuser /run/user/1000\n\
chmod 700 /run/user/1000\n\
\n\
mkdir -p /var/log/supervisor\n\
chown -R root:root /var/log/supervisor\n\
\n\
chown -R archuser:archuser /home/archuser\n\
\n\
echo "Starting system D-Bus..."\n\
mkdir -p /run/dbus\n\
dbus-daemon --system --fork\n\
\n\
echo "Starting supervisord..."\n\
if command -v supervisord &> /dev/null; then\n\
    exec supervisord -c /etc/supervisor/supervisord.conf\n\
else\n\
    echo "ERROR: supervisord not found"\n\
    exit 1\n\
fi\n' > /usr/local/bin/start.sh && chmod +x /usr/local/bin/start.sh

# Expose noVNC port
EXPOSE 6080

CMD ["/usr/local/bin/start.sh"]
