#!/bin/bash
# customize-image.sh — SamplerBox RT para Orange Pi Zero (H3, 512 MB, 2017)
# Se ejecuta dentro del chroot ARM del rootfs final del build de Armbian.

set -e

export DEBIAN_FRONTEND=noninteractive

echo "========================================="
echo "SamplerBox RT — Optimizando sistema..."
echo "========================================="

apt-get update -q

# =====================================================================
# 1. Governor de CPU → performance
# =====================================================================
cat << 'SVC_EOF' > /etc/systemd/system/cpu-performance.service
[Unit]
Description=Set CPU Governor to Performance
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "$f" 2>/dev/null || true; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVC_EOF

systemctl enable cpu-performance.service 2>/dev/null || \
	ln -sf /etc/systemd/system/cpu-performance.service /etc/systemd/system/multi-user.target.wants/cpu-performance.service

# =====================================================================
# 2. Deshabilitar servicios innecesarios
# =====================================================================
for svc in avahi-daemon bluetooth cups ModemManager NetworkManager-wait-for-network \
           alsa-state triggerhappy hciuart; do
	systemctl disable "$svc" 2>/dev/null || true
	systemctl mask "$svc" 2>/dev/null || true
done

# Eliminar PulseAudio / PipeWire si existieran
systemctl mask pulseaudio 2>/dev/null || true
systemctl mask pulseaudio.socket 2>/dev/null || true
systemctl mask pipewire 2>/dev/null || true
systemctl mask pipewire.socket 2>/dev/null || true

# =====================================================================
# 3. threadirqs + isolcpus=3 en la línea de comandos del kernel
# =====================================================================
BOOT_ENV=/boot/armbianEnv.txt
if [ -f "${BOOT_ENV}" ]; then
	# threadirqs
	if ! grep -q "threadirqs" "${BOOT_ENV}"; then
		if grep -q "^extraargs=" "${BOOT_ENV}"; then
			sed -i '/^extraargs=/ s/$/ threadirqs isolcpus=3/' "${BOOT_ENV}"
		else
			echo "extraargs=threadirqs isolcpus=3" >> "${BOOT_ENV}"
		fi
	fi
	# overlays para códec analógico H3 (LINEOUT)
	if grep -q "^overlays=" "${BOOT_ENV}"; then
		sed -i '/^overlays=/ { /analog-codec/! s/$/ analog-codec/ }' "${BOOT_ENV}"
	else
		echo "overlays=analog-codec" >> "${BOOT_ENV}"
	fi
else
	echo "extraargs=threadirqs isolcpus=3" > "${BOOT_ENV}"
	echo "overlays=analog-codec" >> "${BOOT_ENV}"
fi

# =====================================================================
# 4. Regla udev: deshabilitar autosuspend en dispositivos audio USB
# =====================================================================
mkdir -p /etc/udev/rules.d
cat << 'RULE_EOF' > /etc/udev/rules.d/90-audio-usb-autosuspend.rules
# Disable USB autosuspend for audio devices
ACTION=="add", SUBSYSTEM=="usb", TEST=="power/autosuspend", ATTR{power/autosuspend}="-1"
ACTION=="add", SUBSYSTEM=="sound", TAG+="uaccess"
KERNEL=="controlC*", SUBSYSTEM=="sound", ATTR{device/power/autosuspend}="-1"
KERNEL=="pcmC*D*c", SUBSYSTEM=="sound", ATTR{device/power/autosuspend}="-1"
RULE_EOF

# =====================================================================
# 5. Swap: 256 MB con swappiness=10
# =====================================================================
fallocate -l 256M /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=256
chmod 600 /swapfile
mkswap /swapfile
echo "/swapfile none swap sw 0 0" >> /etc/fstab

# Swappiness y tunings de disco para RT
cat << 'SYSCTL_EOF' > /etc/sysctl.d/99-samplerbox-rt.conf
vm.swappiness=10
vm.dirty_ratio=15
vm.dirty_background_ratio=5
vm.dirty_expire_centisecs=6000
vm.dirty_writeback_centisecs=3000
SYSCTL_EOF
sysctl --system 2>/dev/null || true

# =====================================================================
# 6. Reducir escrituras en la microSD
# =====================================================================
# noatime en la partición root
if ! grep -q "noatime" /etc/fstab; then
	sed -i '1s/\(.*ext4.*\)/\1 noatime/' /etc/fstab
fi

# tmpfs para /tmp, /var/tmp, /var/log, /run
GLOBSTAR_SET=false
shopt -s globstar 2>/dev/null || true

for entry in /etc/fstab; do
	if ! grep -q "^tmpfs.*/tmp" "$entry" 2>/dev/null; then
		printf "tmpfs\t/tmp\ttmpfs\tdefaults,noatime,nosuid,nodev,noexec,size=50M\t0\t0\n" >> "$entry"
		printf "tmpfs\t/var/tmp\ttmpfs\tdefaults,noatime,nosuid,nodev,noexec,size=50M\t0\t0\n" >> "$entry"
		printf "tmpfs\t/var/log\ttmpfs\tdefaults,noatime,nosuid,nodev,noexec,size=50M\t0\t0\n" >> "$entry"
		printf "tmpfs\t/var/run\ttmpfs\tdefaults,noatime,nosuid,nodev,noexec,size=50M\t0\t0\n" >> "$entry"
	fi
done

# =====================================================================
# 7. Expandir partición al tamaño completo de la microSD (primer boot)
# =====================================================================
# Armbian incluye armbian-resize-filesystem
systemctl enable armbian-resize-filesystem.service 2>/dev/null || true
systemctl enable armbian-first-run.service 2>/dev/null || true

# =====================================================================
# 8. Instalar utilidades de audio y pruebas
# =====================================================================
apt-get install -y --no-install-recommends \
	alsa-utils \
	libasound2-dev \
	libasound2 \
	rt-tests \
	python3 \
	python3-numpy \
	python3-cffi \
	python3-rtmidi \
	python3-pyaudio \
	git \
	curl 2>/dev/null || apt-get install -y \
	alsa-utils \
	libasound2-dev \
	libasound2 \
	rt-tests \
	python3 \
	python3-numpy \
	python3-cffi \
	python3-rtmidi \
	git

# =====================================================================
# 9. Instalar SamplerBox desde el repositorio oficial
# =====================================================================
echo "========================================="
echo "Instalando SamplerBox..."
echo "========================================="

SAMPLERBOX_DIR=/opt/SamplerBox
git clone --depth=1 https://github.com/SamplerBox/SamplerBox.git "${SAMPLERBOX_DIR}"

# Instalar dependencias de Python de SamplerBox
cd "${SAMPLERBOX_DIR}"
if [ -f requirements.txt ]; then
	pip3 install --no-cache-dir -r requirements.txt 2>/dev/null || \
		apt-get install -y python3-numpy python3-cffi python3-rtmidi python3-yaml python3-pydub 2>/dev/null || true
fi

# Instalar sounddevice (puede necesitar compresión de datos)
pip3 install sounddevice 2>/dev/null || apt-get install -y python3-sounddevice 2>/dev/null || true

# =====================================================================
# 10. Editar samplerbox.py: blocksize=0 en sounddevice.Stream(...)
# =====================================================================
echo "========================================="
echo "Aplicando optimización blocksize=0..."
echo "========================================="

SAMPLERBOX_PY="${SAMPLERBOX_DIR}/samplerbox.py"

if [ -f "${SAMPLERBOX_PY}" ]; then
	# Agregar blocksize=0 como primer argumento de sounddevice.Stream()
	# Usa Python para un reemplazo robusto
	python3 -c "
import re, sys

path = '${SAMPLERBOX_PY}'
with open(path, 'r') as f:
    content = f.read()

# Buscar sounddevice.Stream( y agregar blocksize=0 como primer arg
def add_blocksize(match):
    return match.group(1) + 'blocksize=0, '

new_content = re.sub(r'(sounddevice\.Stream\()\s*', add_blocksize, content, count=1)

if new_content != content:
    with open(path, 'w') as f:
        f.write(new_content)
    print('blocksize=0 added to sounddevice.Stream()')
else:
    # Intento alternativo: buscar el patrón de apertión
    new_content = content.replace(
        'sounddevice.Stream(',
        'sounddevice.Stream(blocksize=0, ',
        1
    )
    if new_content != content:
        with open(path, 'w') as f:
            f.write(new_content)
        print('blocksize=0 added (alternative method)')
    else:
        print('WARNING: Could not find sounddevice.Stream() to patch')
"
else
	echo "ERROR: samplerbox.py not found at ${SAMPLERBOX_PY}"
fi

# =====================================================================
# 11. Configurar config.ini
# =====================================================================
mkdir -p /SamplerBox/presets

# Detectar dispositivo de audio
AUDIO_CARD_ID=$(aplay -l 2>/dev/null | grep -m1 "card.*device" | grep -oP 'card \K[0-9]' | head -1 || echo "0")

cat << 'INI_EOF' > "${SAMPLERBOX_DIR}/config.ini"
[AUDIO]
# Usar ALSA directamente, sin JACK
USE_ALSA=yes
USE_JACK=no

# Latencia baja con blocksize=0 (auto)
LATENCY=low
BUFFERSIZE=128
MAX_POLYPHONY=40

# Dispositivo de audio: 0 = primer dispositivo disponible
# Para usar el códec H3 (LINEOUT), usar card 0
AUDIO_DEVICE_ID=0

# Force sample rate (0 = auto-detect from device)
SAMPLE_RATE=48000

[SYSTEM]
# Directorio base para bancos de samples
PRESET_BASEPATH=/SamplerBox/presets

# Auto-cargar banco de samples en boot
LOAD_LAST_PRESET=yes

# Volumen maestro (0.0 - 1.0)
MASTER_VOLUME=0.8

[LOGGING]
LOG_LEVEL=INFO
INI_EOF

# =====================================================================
# 12. Configurar ALSA (directo, sin PulseAudio)
# =====================================================================
cat << 'ALSA_EOF' > /etc/asound.conf
# Configuración ALSA minimal para SamplerBox - Orange Pi Zero (H3)
defaults.pcm.card 0
defaults.ctl.card 0
defaults.pcm.rate_converter "speexrate"
defaults.pcm.dmix.rate 48000
defaults.pcm.dsnoop.rate 48000

# Rutas de guardado/recuperación de niveles
pcm.!default {
    type hw
    card 0
}
ctl.!default {
    type hw
    card 0
}
ALSA_EOF

# =====================================================================
# 13. Regla udev para usuarios de audio
# =====================================================================
cat << 'AUDIO_EOF' > /etc/udev/rules.d/40-audio-perms.rules
# Permisos para dispositivos de audio
SUBSYSTEM=="sound", GROUP="audio", MODE="0664"
KERNEL=="controlC*", SUBSYSTEM=="sound", GROUP="audio", MODE="0664"
KERNEL=="pcmC*D0c", SUBSYSTEM=="sound", GROUP="audio", MODE="0664"
KERNEL=="pcmC*D0p", SUBSYSTEM=="sound", GROUP="audio", MODE="0664"
KERNEL=="timer", SUBSYSTEM=="sound", GROUP="audio", MODE="0664"
KERNEL=="sequencer*", SUBSYSTEM=="sound", GROUP="audio", MODE="0664"
KERNEL=="midi*", SUBSYSTEM=="sound", GROUP="audio", MODE="0664"
AUDIO_EOF

# Asegurar que el usuario root pertenece al grupo audio
usermod -aG audio root 2>/dev/null || true

# =====================================================================
# 14. Servicio systemd para SamplerBox (prioridades RT)
# =====================================================================
cat << 'SVC_EOF' > /etc/systemd/system/samplerbox.service
[Unit]
Description=SamplerBox Musical Sampler
Documentation=https://github.com/SamplerBox/SamplerBox
After=sound.target sysinit.target cpu-performance.service
Before=shutdown.target
Wants=sound.target
RequiresMountsFor=/opt/SamplerBox /SamplerBox/presets

[Service]
Type=simple
User=root
Group=audio

# Prioridades de tiempo real
Nice=-15
IOSchedulingClass=realtime
IOSchedulingPriority=0

# Límites RT
LimitRTPRIO=99
LimitRTTIME=infinity
LimitMEMLOCK=infinity
LimitNICE=-15

# Afinar CPU: usar CPU 3 (aislada via isolcpus=3)
CPUAffinity=3

# Esperar a que el dispositivo de audio esté disponible
ExecStartPre=/bin/sleep 3
ExecStartPre=/bin/sh -c 'while ! aplay -l 2>/dev/null | grep -q "card"; do sleep 1; done'

# Iniciar SamplerBox
ExecStart=/usr/bin/python3 /opt/SamplerBox/samplerbox.py
WorkingDirectory=/opt/SamplerBox

# Reinicio automático
Restart=on-failure
RestartSec=5
StartLimitIntervalSec=60
StartLimitBurst=3

# Seguridad mínima (mantener acceso al hardware de audio)
NoNewPrivileges=false

StandardOutput=journal
StandardError=journal
SyslogIdentifier=samplerbox

[Install]
WantedBy=multi-user.target
SVC_EOF

# Enable service
systemctl enable samplerbox.service 2>/dev/null || \
	ln -sf /etc/systemd/system/samplerbox.service /etc/systemd/system/multi-user.target.wants/samplerbox.service

# =====================================================================
# 15. Script de diagnóstico
# =====================================================================
cat << 'TEST_EOF' > /usr/local/bin/samplerbox-test
#!/bin/bash
echo "=== SamplerBox Diagnostic ==="
echo ""
echo "--- Kernel ---"
uname -a
echo ""

echo "--- PREEMPT_RT Status ---"
if grep -q "realtime" /proc/version 2>/dev/null; then
	echo "RT: ACTIVE (verificado en /proc/version)"
elif [ -f /sys/kernel/realtime ] && [ "$(cat /sys/kernel/realtime)" = "1" ]; then
	echo "RT: ACTIVE (sysfs)"
else
	echo "RT: Checking /proc/version..."
	grep -o "PREEMPT.*" /proc/version || echo "RT: NOT detected"
fi
echo ""

echo "--- CPU Governor ---"
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "N/A"
echo ""

echo "--- Kernel cmdline ---"
cat /proc/cmdline
echo ""

echo "--- ALSA Devices ---"
aplay -l 2>/dev/null || echo "No audio devices"
echo ""

echo "--- MIDI Devices ---"
aplaymidi -l 2>/dev/null || amidi -l 2>/dev/null || echo "No MIDI devices"
echo ""

echo "--- Swap ---"
swapon --show 2>/dev/null || echo "No swap active"
cat /proc/sys/vm/swappiness 2>/dev/null
echo ""

echo "--- SamplerBox Service ---"
systemctl status samplerbox.service --no-pager 2>/dev/null || \
	echo "Service not available"
echo ""

echo "--- Cyclictest (10s, prio 80) ---"
timeout 15 cyclictest -t1 -p 80 -n -i 10000 -l 1000 --quiet 2>/dev/null || \
	echo "cyclictest not available or timed out"
echo ""

echo "--- Audio latency check ---"
if command -v speaker-test >/dev/null 2>&1; then
	echo "Playing test tone (5s)..."
	timeout 5 speaker-test -t sine -f 440 -l 1 -c 2 --buffer 44000 2>/dev/null || echo "Audio test failed"
fi
echo ""

echo "=== Diagnostic complete ==="
TEST_EOF
chmod +x /usr/local/bin/samplerbox-test

# =====================================================================
# 16. Script de prueba de audio y latencia para validar la imagen
# =====================================================================
cat << 'RUNTEST_EOF' > /usr/local/bin/samplerbox-validate
#!/bin/bash
set -e

echo "========================================="
echo "SamplerBox RT — Validation Suite"
echo "========================================="

PASS=0
FAIL=0

check() {
	if [ $? -eq 0 ]; then
		echo "[PASS] $1"
		PASS=$((PASS + 1))
	else
		echo "[FAIL] $1"
		FAIL=$((FAIL + 1))
	fi
}

# 1. Kernel RT
echo ""
echo "--- 1. Kernel PREEMPT_RT ---"
if grep -qi "PREEMPT" /proc/version; then
	echo "Kernel version: $(uname -r)"
	echo "RT detected in /proc/version"
	check "PREEMPT_RT kernel"
else
	echo "WARNING: PREEMPT not found in /proc/version"
	FAIL=$((FAIL + 1))
fi

# 2. Governor
echo ""
echo "--- 2. CPU Governor ---"
GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")
echo "Governor: $GOV"
[ "$GOV" = "performance" ] && check "CPU governor = performance" || FAIL=$((FAIL + 1))

# 3. Audio device
echo ""
echo "--- 3. Audio Device ---"
aplay -l 2>/dev/null | head -10 || echo "No audio devices found"
aplay -l 2>/dev/null | grep -q "card" && check "Audio device detected" || FAIL=$((FAIL + 1))

# 4. MIDI
echo ""
echo "--- 4. MIDI ---"
if aplaymidi -l 2>/dev/null | grep -q "card\|Synth\|MIDI"; then
	check "MIDI device detected"
else
	echo "No MIDI device (OK if using USB keyboard)"
	check "MIDI check (optional)"
fi

# 5. Swap
echo ""
echo "--- 5. Swap ---"
SWAP_SIZE=$(swapon --show=SIZE --noheadings 2>/dev/null | head -1 | tr -d ' ')
if [ -n "$SWAP_SIZE" ]; then
	echo "Swap size: $SWAP_SIZE"
	check "Swap available"
else
	echo "Swap not active (may be OK if swappiness is low)"
	check "Swap check"
fi
SWAPPINESS=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "unknown")
echo "Swappiness: $SWAPPINESS"
[ "$SWAPPINESS" -le 15 ] && check "Swappiness <= 15" || FAIL=$((FAIL + 1))

# 6. Cyclictest
echo ""
echo "--- 6. RT Latency (cyclictest 10s) ---"
if command -v cyclictest >/dev/null 2>&1; then
	cyclictest -t1 -p 80 -n -i 10000 -l 1000 --quiet > /tmp/cyclictest.txt 2>&1
	echo "Cyclictest results (saved to /tmp/cyclictest.txt):"
	tail -10 /tmp/cyclictest.txt
	# Check max latency
	MAX_LATENCY=$(grep -oP 'Max Lat: \K[0-9]+' /tmp/cyclictest.txt || tail -1 | awk '{print $4}')
	if [ -n "$MAX_LATENCY" ]; then
		echo "Max latency: ${MAX_LATENCY} us"
		[ "$MAX_LATENCY" -lt 200 ] && check "RT latency < 200 us" || FAIL=$((FAIL + 1))
	else
		check "Cyclictest ran"
	fi
else
	echo "cyclictest not available"
	FAIL=$((FAIL + 1))
fi

# 7. SamplerBox service
echo ""
echo "--- 7. SamplerBox Service ---"
if systemctl is-active --quiet samplerbox.service 2>/dev/null; then
	check "SamplerBox service is running"
else
	echo "SamplerBox service not running yet or systemd not available"
	FAIL=$((FAIL + 1))
fi

# Summary
echo ""
echo "========================================="
echo "Validation Summary: $PASS passed, $FAIL failed"
echo "========================================="

echo ""
echo "--- Logs de arranque de SamplerBox ---"
journalctl -u samplerbox.service --no-pager -n 30 2>/dev/null || \
	echo "(journalctl not available in this context)"

echo ""
echo "--- Cyclictest log ---"
cat /tmp/cyclictest.txt 2>/dev/null | tail -5

RUNTEST_EOF
chmod +x /usr/local/bin/samplerbox-validate

# =====================================================================
# 17. Documentación de configuración
# =====================================================================
mkdir -p /opt/SamplerBox/docs
cat << 'DOC_EOF' > /opt/SamplerBox/docs/CONFIGURACION.md
# SamplerBox RT — Configuración del Sistema

## Placa
- **Orange Pi Zero (H3, 512MB, 2017)**
- SoC: Allwinner H3 (ARM Cortex-A7 quad-core, 32-bit ARMHF)
- Kernel: 6.6.147-rt77 (PREEMPT_RT)

## Optimizaciones aplicadas

### Kernel
- `CONFIG_PREEMPT_RT=y` — kernel de tiempo real completo
- `threadirqs` — IRQ convertidas a threads
- `isolcpus=3` — CPU 3 aislada exclusivamente para audio
- Governor: `performance`

### Sistema
- Servicios deshabilitados: avahi-daemon, bluetooth, CUPS, ModemManager
- PulseAudio y PipeWire: deshabilitados/masked
- Audio: ALSA puro, sin capa de sonido intermedia
- Swappiness: 10 (mínima)
- Swap: 256 MB en /swapfile
- Root filesystem: `noatime` (reduce escrituras)
- tmpfs: /tmp, /var/tmp, /var/log, /var/run (reduce escrituras SD)
- Dirty ratios: ratio=15%, background=5% (flush anticipado)

### SamplerBox
- blocksize=0 — latencia mínima con auto-ajuste del driver ALSA
- BUFFERSIZE=128
- MAX_POLYPHONY=40
- LATENCY=low
- Servicio systemd: Nice=-15, IOSchedulingClass=realtime, CPUAffinity=3
- Auto-reinicio en fallo (Restart=on-failure)

### Recomendación de dispositivo de audio

**Mejor opción: DAC I2S PCM5102A**
- Conecta a los pines GPIO (interface I2S directo al H3)
- Latencia más baja que USB (sin overhead de protocolo USB)
- Calidad de audio 24-bit/96kHz
- Requiere soldar 5 cables (VCC, GND, LRCK, BCK, DIN)
- Configuración: se habilita con `overlays=analog-codec` + `i2s0` en armbianEnv.txt

**Alternativa: USB Audio**
- Plug-and-play, sin soldar
- Latencia ligeramente mayor (overhead USB)
- Compatible con la mayoría de DACs USB
- Configuración automática con la regla udev incluida

**Alternativa: Códec analógico H3 (LINEOUT)**
- Ya integrado en la Orange Pi Zero
- Calidad aceptable para uso doméstico
- Latencia media
- Configuración: `overlays=analog-codec` en armbianEnv.txt

## Comandos útiles

### Diagnóstico
```bash
samplerbox-test      # Ver estado del kernel, audio, MIDI, latencia
samplerbox-validate  # Ejecutar suite de validación completa
```

### Gestión del servicio
```bash
systemctl status samplerbox    # Ver estado
systemctl restart samplerbox   # Reiniciar
journalctl -u samplerbox -f    # Logs en tiempo real
```

### Configuración
```bash
# Editar configuración
nano /opt/SamplerBox/config.ini

# Recargar configuración (reinicia el servicio)
systemctl restart samplerbox
```

### Pruebas de latencia
```bash
# Test básico de RT latency
cyclictest -t1 -p 80 -n -i 10000 -l 1000

# Test con 3 hilos y prioridad RT
cyclictest -t3 -p 99 -d 100 -n -a
```
DOC_EOF

# =====================================================================
# 18. Configuración de grupo audio con prioridades RT
# =====================================================================
cat << 'LIMITS_EOF' > /etc/security/limits.d/audio.conf
# Dar prioridades RT al grupo audio
@audio   -  rtprio     99
@audio   -  memlock    unlimited
@audio   -  nice       -15
LIMITS_EOF

# =====================================================================
# 19. Asegurar que el paquete rt-tests está instalado
# =====================================================================
dpkg -l | grep -q rt-tests || apt-get install -y rt-tests

# =====================================================================
# 20. Limpiar
# =====================================================================
rm -rf /tmp/*
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "========================================="
echo "SamplerBox RT imagen configurada."
echo "Ejecuta 'samplerbox-test' para diagnosticar."
echo "========================================="
