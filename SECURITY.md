# Seguridad

Si encuentras un fallo de seguridad en Despierto, avisa **en privado** antes de publicarlo: en GitHub, pestaña **Security** → **Report a vulnerability**. Si no ves ese botón, abre un issue pidiendo un contacto privado, **sin contar los detalles**.

Cuenta qué versión usas, cómo se reproduce y qué podría hacer alguien con ello.

Solo recibe arreglos la última versión publicada.

## Qué toca Despierto fuera de la app

| Qué | Dónde | Cómo se quita |
|---|---|---|
| Permiso para `pmset -a disablesleep 0` y `1` | `/etc/sudoers.d/despierto` | «···» → «Volver a lo normal y quitar permisos…» |
| Red de seguridad (LaunchAgent) | dentro de la app | igual, o en Ajustes → Ítems de inicio |
| Marca de «activo» | `~/Library/Application Support/Despierto` | se borra al volver a lo normal |
| Registro de la configuración | `~/Library/Logs/Despierto-setup.log` | a mano |
