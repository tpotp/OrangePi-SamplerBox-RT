# SamplerBox RT — Orange Pi Zero (H3, 512 MB, 2017)

Imagen **Armbian-based** con kernel **PREEMPT_RT** compilado desde fuentes para la **Orange Pi Zero (Allwinner H3)**. Incluye SamplerBox con configuración optimizada para **mínima latencia de audio**.

> **Estado del build**: [![Build Status](https://github.com/tpotp/OrangePi-SamplerBox-RT/actions/workflows/build-armbian-rt.yml/badge.svg)](https://github.com/tpotp/OrangePi-SamplerBox-RT/actions/workflows/build-armbian-rt.yml)

---

## 📋 Resumen de la imagen

| Componente | Versión |
|---|---|
| Board | Orange Pi Zero (H3, ARMv7, 512 MB) |
| OS base | Debian 12 (Bookworm) |
| Kernel | 6.6.147 + RT patch 6.6.147-rt77 |
| RT | `CONFIG_PREEMPT_RT=y` (Full RT) |
| Audio | ALSA puro (sin PulseAudio/PipeWire) |
| SamplerBox | Último desde [SamplerBox/SamplerBox](https://github.com/SamplerBox/SamplerBox) |
| Governor | performance |
| Swappiness | 10 |

## 🔧 Optimizaciones aplicadas

### Kernel (lib.config → `post_kernel_config`)
- `CONFIG_PREEMPT_RT=y` — kernel de tiempo real completo
- `CONFIG_EXPERT=y`
- `CONFIG_HIGH_RES_TIMERS=y`
- `CONFIG_CPU_FREQ_DEFAULT_GOV=performance`
- Debug options deshabilitados: `LOCKDEP`, `FTRACE`, `KPROBES`, `FUNCTION_TRACER`, etc.
- Línea de comandos: `threadirqs isolcpus=3`

### Sistema (customize-image.sh)
- **Governor**: `performance` via servicio systemd
- **Servicios deshabilitados**: avahi-daemon, bluetooth, CUPS, ModemManager, NetworkManager
- **Audio**: ALSA puro, PulseAudio y PipeWire *masked*
- **Swap**: 256 MB en `/swapfile`, `vm.swappiness=10`
- **SD card**: root montado con `noatime`, tmpfs en `/tmp`/`/var/log`
- **Udev**: autosuspend USB deshabilitado para dispositivos de audio

### SamplerBox
- **blocksize=0** en `sounddevice.Stream(...)` — auto-ajuste del driver ALSA
- `BUFFERSIZE=128`, `MAX_POLYPHONY=40`, `LATENCY=low`
- Servicio systemd con: `Nice=-15`, `IOSchedulingClass=realtime`, `CPUAffinity=3`, `LimitRTPRIO=99`, `LimitMEMLOCK=infinity`
- Auto-reinicio en fallo (`Restart=on-failure`)
- Espera a dispositivo de audio antes de iniciar

## 🎧 Dispositivo de audio recomendado

| Opción | Ventajas | Conectores |
|---|---|---|
| **DAC I2S PCM5102A** (recomendado) | Baja latencia (I2S directo), 24-bit/96kHz | 5 pines GPIO |
| **Códec analógico H3** (LINEOUT) | Integrado, sin hardware adicional | Jack 3.5 mm |
| **Audio USB** | Plug-and-play | Puerto micro-USB (OTG) |

**Recomendación**: DAC I2S PCM5102A para la menor latencia posible. El códec H3 es una buena alternativa sin hardware adicional.

## 📥 Uso

### Opción 1: GitHub Actions (automático)
1. Haz push a `main` o dispara el workflow manualmente
2. Descarga el artefacto **`SamplerBox-RT-Image-Orangepizero`**
3. Descomprime el `.img.xz`
4. Graba con [Rufus](https://rufus.ie/) o `dd`/`balenaEtcher` en microSD (≥4 GB)

### Opción 2: Build local (WSL2)
```bash
# Clonar dependencias
git clone --depth=1 https://github.com/armbian/build
cp -r userpatches build/

# Descargar RT patch
mkdir -p build/userpatches/kernel/archive/sunxi-6.6
wget -q https://cdn.kernel.org/pub/linux/kernel/projects/rt/6.6/patch-6.6.147-rt77.patch.xz
unxz patch-6.6.147-rt77.patch.xz
mv patch-6.6.147-rt77.patch build/userpatches/kernel/archive/sunxi-6.6/000_rt_patch.patch

# Compilar
cd build
sudo ./compile.sh \
  BOARD=orangepizero \
  BRANCH=current \
  KERNELBRANCH=tag:v6.6.147 \
  RELEASE=bookworm \
  BUILD_DESKTOP=no \
  BUILD_MINIMAL=yes \
  KERNEL_CONFIGURE=no \
  EXPERT=yes \
  CLEAN_LEVEL=make,debs,oldcache
```

## 🛠️ Comandos útiles (en la Pi)

```bash
samplerbox-test      # Diagnóstico completo
samplerbox-validate  # Suite de validación RT
systemctl status samplerbox    # Estado del servicio
journalctl -u samplerbox -f    # Logs en tiempo real
```

## 🧪 Validación incluida

El script `samplerbox-validate` verifica:
1. Kernel PREEMPT_RT activo
2. CPU governor = performance
3. Dispositivo de audio detectado
4. Swap activo y swappiness bajo
5. `cyclictest` — latencia máxima < 200 µs
6. Servicio SamplerBox activo

## 📁 Estructura del repositorio

```
├── .github/workflows/build-armbian-rt.yml   # CI/CD — build completo
├── userpatches/
│   ├── customize-image.sh                   # Optimizaciones + SamplerBox
│   └── lib.config                           # Hooks de kernel RT
├── README.md
└── (imagen descargable generada por CI)
```

## 📝 Notas

- El kernel se compila **desde fuentes** en GitHub Actions (tiempo estimado: ~3-4 horas)
- El RT patch se aplica a kernel 6.6.147 desde [kernel.org](https://www.kernel.org/pub/linux/kernel/projects/rt/)
- La imagen resultante es un `.img.xz` listo para flashear con Rufus
- Para cambiar el dispositivo de audio: editar `/opt/SamplerBox/config.ini`
- Para cargar bancos de samples: colocar archivos `.txt` + samples en `/SamplerBox/presets/`
