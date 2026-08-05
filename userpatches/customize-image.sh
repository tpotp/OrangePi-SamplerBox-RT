#!/bin/bash
# Runs in Armbian's target rootfs during image creation.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

SAMPLERBOX_DIR=/opt/SamplerBox
PRESET_DIR=/SamplerBox/presets
SAMPLERBOX_COMMIT=6161ddd0ea8fbc7b3ac788622a41cc5ee28326bb

apt-get update
apt-get install -y --no-install-recommends \
  alsa-utils libasound2 libasound2-dev libportaudio2 portaudio19-dev \
  python3 python3-dev python3-numpy python3-pip cython3 \
  build-essential git rt-tests
apt-get purge -y --auto-remove pulseaudio pipewire pipewire-pulse avahi-daemon bluez cups 2>/dev/null || true
systemctl mask avahi-daemon.service bluetooth.service cups.service armbian-zram-config.service 2>/dev/null || true

git clone https://github.com/josephernest/SamplerBox.git "$SAMPLERBOX_DIR"
git -C "$SAMPLERBOX_DIR" checkout --detach "$SAMPLERBOX_COMMIT"
python3 -m pip install --break-system-packages --no-cache-dir \
  cython cffi sounddevice pyserial \
  'git+https://github.com/SamplerBox/rtmidi-python.git@f7b95708eb6a9fd2277518930aab41a43287fd91'
(cd "$SAMPLERBOX_DIR" && python3 setup.py build_ext --inplace)

# The maintained upstream has config.py (not config.ini).  Patch its one
# OutputStream creation to request ALSA's adaptive block size and low latency.
python3 - <<'PY'
from pathlib import Path

root = Path('/opt/SamplerBox')
config = root / 'config.py'
code = root / 'samplerbox.py'
text = config.read_text()
for old, new in {
    'AUDIO_DEVICE_ID = 2': 'AUDIO_DEVICE_ID = 0',
    'SAMPLES_DIR = "."': 'SAMPLES_DIR = "/SamplerBox/presets"',
    'MAX_POLYPHONY = 80': 'MAX_POLYPHONY = 24',
}.items():
    if old not in text:
        raise SystemExit(f'missing expected upstream setting: {old}')
    text = text.replace(old, new, 1)
config.write_text(text)

text = code.read_text()
old = "sounddevice.OutputStream(device=AUDIO_DEVICE_ID, blocksize=512, samplerate=44100, channels=2, dtype='int16', callback=AudioCallback)"
new = "sounddevice.OutputStream(device=AUDIO_DEVICE_ID, blocksize=0, latency='low', samplerate=44100, channels=2, dtype='int16', callback=AudioCallback)"
if old not in text:
    raise SystemExit('expected sounddevice.OutputStream call not found')
code.write_text(text.replace(old, new, 1))
PY

mkdir -p "$PRESET_DIR"
cp -a "$SAMPLERBOX_DIR/media/." "$PRESET_DIR/"

cat > /etc/asound.conf <<'EOF'
# The Orange Pi Zero's H2+/H3 analog codec is the only default audio path.
pcm.!default { type hw; card Codec; device 0; }
ctl.!default { type hw; card Codec; }
EOF

cat > /etc/udev/rules.d/90-usb-audio-no-autosuspend.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="usb", ATTR{bInterfaceClass}=="01", TEST=="power/control", ATTR{power/control}="on"
EOF

cat > /etc/sysctl.d/99-samplerbox-rt.conf <<'EOF'
vm.swappiness=5
EOF
dd if=/dev/zero of=/swapfile bs=1M count=128 status=none
chmod 600 /swapfile
mkswap /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

BOOT_ENV=/boot/armbianEnv.txt
if [ -f "$BOOT_ENV" ]; then
  if grep -q '^extraargs=' "$BOOT_ENV"; then
    grep -q '^extraargs=.*threadirqs' "$BOOT_ENV" || sed -i '/^extraargs=/ s/$/ threadirqs/' "$BOOT_ENV"
    grep -q '^extraargs=.*isolcpus=3' "$BOOT_ENV" || sed -i '/^extraargs=/ s/$/ isolcpus=3/' "$BOOT_ENV"
  else
    echo 'extraargs=threadirqs isolcpus=3' >> "$BOOT_ENV"
  fi
  if grep -q '^overlays=' "$BOOT_ENV"; then
    grep -q '^overlays=.*analog-codec' "$BOOT_ENV" || sed -i '/^overlays=/ s/$/ analog-codec/' "$BOOT_ENV"
  else
    echo 'overlays=analog-codec' >> "$BOOT_ENV"
  fi
else
  printf '%s\n' 'extraargs=threadirqs isolcpus=3' 'overlays=analog-codec' > "$BOOT_ENV"
fi

install -d /usr/local/libexec
cat > /usr/local/libexec/samplerbox-preflight <<'EOF'
#!/bin/sh
set -eu
test "$(cat /sys/kernel/realtime)" = 1
grep -qw threadirqs /proc/cmdline
i=0
while ! aplay -l 2>/dev/null | grep -Eq 'H3 Audio Codec|Codec'; do
  i=$((i + 1)); test "$i" -lt 31 || exit 1; sleep 1
done
EOF
chmod 755 /usr/local/libexec/samplerbox-preflight

cat > /usr/local/libexec/samplerbox-select-audio <<'EOF'
#!/usr/bin/python3
import re
from pathlib import Path
import sounddevice

matches = []
for index, device in enumerate(sounddevice.query_devices()):
    name = device['name']
    if device['max_output_channels'] >= 2 and re.search(r'h3 audio|codec|sun8i|analog', name, re.I):
        matches.append(index)
if not matches:
    raise SystemExit('H2+/H3 analog codec is not available through ALSA')
path = Path('/opt/SamplerBox/config.py')
path.write_text(re.sub(r'^AUDIO_DEVICE_ID\s*=\s*\d+.*$', f'AUDIO_DEVICE_ID = {matches[0]}', path.read_text(), flags=re.M))
EOF
chmod 755 /usr/local/libexec/samplerbox-select-audio

cat > /etc/systemd/system/cpu-performance.service <<'EOF'
[Unit]
Description=Set all CPU policies to performance
Before=samplerbox.service
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for f in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do echo performance > $$f; done'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/samplerbox.service <<'EOF'
[Unit]
Description=SamplerBox on the Orange Pi Zero analog codec
After=sound.target cpu-performance.service
Wants=sound.target cpu-performance.service
RequiresMountsFor=/opt/SamplerBox /SamplerBox/presets
[Service]
Type=simple
User=root
Group=audio
Nice=-15
IOSchedulingClass=realtime
IOSchedulingPriority=0
LimitRTPRIO=99
LimitRTTIME=infinity
LimitMEMLOCK=infinity
LimitNICE=-15
CPUAffinity=3
ExecStartPre=/usr/local/libexec/samplerbox-preflight
ExecStartPre=/usr/local/libexec/samplerbox-select-audio
ExecStart=/usr/bin/python3 /opt/SamplerBox/samplerbox.py
WorkingDirectory=/opt/SamplerBox
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF

cat > /usr/local/bin/samplerbox-validate <<'EOF'
#!/bin/sh
set -eu
test "$(cat /sys/kernel/realtime)" = 1
grep -qw threadirqs /proc/cmdline
test "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)" = performance
test "$(cat /proc/sys/vm/swappiness)" -le 10
aplay -l | grep -Eq 'H3 Audio Codec|Codec'
systemctl is-active --quiet samplerbox.service
cyclictest -t1 -p80 -n -i10000 -l3000
EOF
chmod 755 /usr/local/bin/samplerbox-validate

systemctl enable cpu-performance.service samplerbox.service
apt-get clean
rm -rf /var/lib/apt/lists/*
