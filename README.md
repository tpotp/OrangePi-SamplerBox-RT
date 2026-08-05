# Orange Pi Zero SamplerBox RT

Imagen reproducible para Orange Pi Zero con H2+ (ARMv7, 512 MB), salida analógica por los pines del códec integrado y SamplerBox iniciado por `systemd`.

La combinación fijada es Armbian `current` sunxi, Linux `6.18.37` y el parche oficial `6.18.37-rt6` de kernel.org. El workflow no publica una imagen si el parche no aplica, si `CONFIG_PREEMPT_RT=y` no queda en el kernel, o si el kernel resultante no completa un arranque RT de 30 segundos en QEMU sobre el SoC Allwinner H3 de la familia H2+/H3.

El artefacto `OrangePiZero-SamplerBox-RT-6.18.37-rt6` es una imagen `.img.xz` lista para grabar en una microSD de al menos 4 GB. Junto a ella se publica la evidencia de configuración y del arranque QEMU.

En el primer arranque, `samplerbox.service` exige que `/sys/kernel/realtime` sea `1`, que `threadirqs` esté activo y que aparezca el códec H3/H2+ analógico. Así no inicia un sampler sin RT o con una salida de audio equivocada.

El SamplerBox oficial mantenido usa `config.py`, no `config.ini`; por ello la imagen configura ese archivo directamente y modifica su `sounddevice.OutputStream` a `blocksize=0` y `latency='low'`. La polifonía inicial se limita a 24 voces para los 512 MB de RAM y los bancos incluidos se cargan desde `/SamplerBox/presets`.

Después de grabar la tarjeta y arrancar la placa, la verificación final de hardware se ejecuta con:

```sh
samplerbox-validate
```
