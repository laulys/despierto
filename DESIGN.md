# Design — Despierto «Ceniza»

El cristal del panel **es** el estado. En modo normal es claro y casi invisible; al activarlo se ahúma a negro ceniza. No hay color de acento: el único color con significado es verde (todo bien) y ámbar (ojo).

## Superficie

| Pieza | Valor |
|---|---|
| Panel | `NSPanel` sin bordes, 320 pt de ancho, radio 20 (16 antes de macOS 26), sombra del sistema |
| Cristal | `NSGlassEffectView` estilo `.clear` en macOS 26; `NSVisualEffectView` `.popover` antes |
| Humo activado | capa SwiftUI ceniza 950 al 74 %, esquema oscuro forzado |
| Humo normal | blanco al 50 % (sistema claro) · ceniza 900 al 30 % (sistema oscuro) |
| Cambio de estado | el humo se anima en 450 ms con la curva firma |

## Color

Escala ceniza (grises cálidos):

| Token | Hex |
|---|---|
| `ash950` | `#141413` |
| `ash900` | `#1C1B1A` |
| `ash800` | `#2A2927` |
| `ash600` | `#4A4845` |
| `ash200` | `#D9D6D1` |
| `ash100` | `#ECEAE6` |

Semántica (solo estados): ok `#15803D` claro / `#6EE7A0` oscuro · aviso `#B45309` claro / `#FBBF57` oscuro.
Textos: `primary` y `secondary` del sistema (vibrancia sobre el cristal). Superficies internas: `primary` al 7–9 %; líneas al 10 %.

## Tipografía

SF del sistema. SF Rounded solo en el título de estado (17 semibold) y la cuenta atrás (40 semibold, cifras tabulares). Etiquetas 12, filas 13 semibold + 12, pie 11. `/remote-control` en monoespaciada porque es código.

## Componentes

- **Estado**: taza en círculo de 40 pt. Normal: taza vacía (`cup.and.saucer`), círculo `primary` 9 %. Activado: taza llena (`cup.and.saucer.fill`) con tres hilos de vapor dibujados, círculo `ash100`, icono `ash950`.
- **Duración**: un solo control segmentado (pista `primary` 7 %, radio 10; segmentos 28 pt, radio 7). Seleccionado = relleno `primary` con texto invertido. Hover `primary` 8 %.
- **Volver a lo normal**: botón de contorno, 30 pt, radio 9, borde `primary` 20 %.
- **Filas** (agentes abiertos, móvil): sin tarjetas; columna de icono de 20 pt, título + descripción, separadas 16 pt. Selector Claude/Cursor/Codex (pista 6 %, radio 8; chips 24 pt). QR 58 pt sobre blanco, radio 9.
- **Pie**: batería, «Abrir al iniciar», salir (círculo 24 pt).
- **Aviso tranquilo** (p. ej. «volvió solo a lo normal» por batería baja): 11 pt, `secondary`, con icono de batería; no es un error, así que nada de rojo.
- Pulsación: ver «Movimiento».

## Barra de menú

Taza vacía `cup.and.saucer` en modo normal; café humeante `cup.and.heat.waves.fill` activado, con la cuenta atrás en cifras tabulares si hay temporizador. El icono se transforma con el efecto «replace» de SF Symbols y, al activarlo, da un saltito (`bounce.up`) 300 ms después. Queda resaltado mientras el panel está abierto.

## Icono de la app

Squircle con degradado ceniza (`#5A5753` → `#2A2927` → `#141413`), brillo superior blanco 16 %, taza `#ECEAE6`. Se dibuja con `icon.swift`.

## Movimiento

Personalidad tranquila, de café. Una curva firma `cubic-bezier(0.2, 0, 0, 1)` y tres duraciones: 150 ms (rápida), 250 ms (estándar), 450 ms (lenta).

| Momento | Animación |
|---|---|
| Activar (momento estrella) | la taza se hunde 90 ms (anticipación) y se llena con un muelle (respuesta 0,42, amortiguación 0,62). El vapor se dibuja de abajo arriba en 450 ms, escalonado 70 ms, y el cristal se ahúma en 450 ms. La cuenta atrás entra 80 ms después, bajando 6 pt |
| Vapor en reposo | bucle de 2,4 s por hilo, desfasados 0,8 s: sube 2,5 pt, se balancea ±0,6 pt y se desvanece (empieza y acaba invisible, sin saltos). 30 fps, solo con el panel visible |
| Desactivar | el vapor se escapa 3 pt hacia arriba (150 ms, acelera) y la taza se vacía |
| Abrir / cerrar panel | baja 8 pt y aparece en 220 ms / sube 4 pt y se desvanece en 140 ms (la salida es más corta que la entrada) |
| Selector de tiempo | la selección se desliza entre segmentos con un muelle (0,32 / 0,86) |
| Cuenta atrás | las cifras ruedan hacia abajo; la barra de progreso avanza lineal |
| Botones | se hunden al 96 % y 75 % de opacidad; al soltar, muelle suave. Hover en 100 ms |
| Háptica | toque `levelChange` en el trackpad al activar o volver a lo normal |
| Reducir movimiento | sin desplazamientos, escalas ni bucle: solo fundidos de 150 ms y vapor quieto |
