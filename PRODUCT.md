# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos

## Users
Personas que programan con IA en un MacBook (Claude Code, Cursor, Codex, Antigravity) y quieren alejarse un rato, por ejemplo a por un café, cerrando la tapa sin que la sesión se corte.

## Product Purpose
Despierto mantiene el Mac encendido con la tapa cerrada durante el tiempo que elijas y luego lo devuelve solo a lo normal. Éxito: vuelves del café y la sesión de IA ha seguido trabajando, o la has seguido desde el móvil.

## Positioning
No es un «caffeinate» genérico: está pensado para la pausa con la tapa cerrada mientras una IA trabaja. Avisa si hay agentes abiertos y enlaza con Remote Control (Claude, Cursor o Codex) para continuar desde el móvil.

## Operating Context
App de barra de menú de macOS. Se usa en segundos, justo antes de levantarse. Cambiar el ajuste (`pmset disablesleep`) pide la contraseña del Mac solo la primera vez: instala un permiso limitado a ese comando.

## Capabilities and Constraints
- Duraciones: 15 min, 30 min, 1 h, 2 h o sin límite. El temporizador lo lleva un proceso del sistema y funciona con la tapa cerrada.
- Detecta Claude Code, Cursor, Codex y Antigravity (`agy`) si están abiertos. Un proceso abierto no significa que esté trabajando.
- Seguir en el móvil: selector Claude / Cursor / Codex con QR y comando copiable. Claude sigue usando sesiones con bridge; Cursor y Codex usan sus portales oficiales.
- Apagar desde el móvil: con el modo activo, un QR en la LAN local (misma Wi‑Fi, token) llama a «volver a lo normal».
- Con Despierto activo y tapa cerrada, pone el brillo del panel a 0 y lo restaura al abrir (ahorro de pantalla/batería, no de RAM).
- macOS 13 o posterior.

## Brand Commitments
- Nombre: Despierto. Interfaz y textos en español, tono cercano.
- Color elegido para el diseño: negro ceniza. Panel con transparencia.

## Product Principles
- Se entiende en un vistazo: el estado se ve antes que cualquier botón.
- Nunca deja el Mac despierto sin que lo sepas.
- Seguridad primero: avisar de batería y calor, nunca guardar la contraseña. Con la batería al 10 % o menos y sin cargador, vuelve solo a lo normal.
