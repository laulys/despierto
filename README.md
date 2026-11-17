<p align="center">
  <img src="docs/icono.png" width="128" alt="Icono de Despierto">
</p>

<h1 align="center">Despierto ☕</h1>

<p align="center">
  <b>Vete a por un café. Tu Mac (y tu IA) siguen trabajando.</b><br>
  Una mini app para la barra de menú de macOS que mantiene tu Mac encendido aunque cierres la tapa.
</p>

<p align="center">
  <a href="https://github.com/laulys/despierto/releases/latest/download/Despierto.zip"><img src="https://img.shields.io/badge/Descargar_para_macOS-141413?style=for-the-badge&logo=apple&logoColor=ECEAE6" alt="Descargar para macOS" height="40"></a>
  <br><sub>macOS 13 o posterior · Apple Silicon e Intel · <a href="#instalación">cómo instalarla</a></sub>
</p>

<p align="center">
  <img src="docs/demo.gif" width="376" alt="Animación: el panel pasa de modo normal a pausa café; la taza se llena, sale vapor, el cristal se ahúma y empieza la cuenta atrás">
  <br><sub>Animación dibujada por la propia app (el fondo de escritorio es simulado).</sub>
</p>

## ¿Para qué?

Estás vibecodeando con **Claude Code**, **Cursor**, **Codex** o **Antigravity**, te apetece un café y cierras el portátil… y la sesión se corta. 😩

Con Despierto eliges cuánto tiempo te vas, cierras la tapa y todo sigue funcionando. Y si quieres, **continúas el chat desde el móvil**.

## Qué hace

- **☕ Pausa café**: elige 15 min, 30 min, 1 h, 2 h o sin límite. Cuando se acaba el tiempo, el Mac vuelve solo a lo normal, aunque la tapa siga cerrada.
- **⏱ Cuenta atrás en la barra de menú**, para que sepas cuánto te queda.
- **🤖 Vigila tus agentes**: si tienes abierto Claude Code, Cursor, Codex o Antigravity (`agy`) y no has activado Despierto, te avisa de que se pararán si cierras la tapa.
- **📱 Sigue en el móvil**: elige Claude, Cursor o Codex y escanea el QR (o copia el comando de Remote Control) para continuar desde el teléfono.
- **⏻ Apagar desde el móvil**: con Despierto activo, un QR en la misma Wi‑Fi vuelve el Mac a lo normal cuando termines (sin abrir el portátil).
- **🔅 Brillo a 0 con la tapa cerrada**: con Despierto activo, al cerrar la tapa apaga el brillo de la pantalla integrada (ahorro de batería/pantalla; no reduce la RAM). Al abrirla, lo restaura.
- **🔋 Batería a la vista**, con aviso si vas con poca y sin cargador. Y si baja del **10 %** sin cargador, Despierto vuelve solo a lo normal para que el Mac pueda dormirse y no se apague de golpe.
- **🪟 Cristal transparente**: claro en modo normal y ahumado en negro ceniza cuando está activado. Funciona en modo claro y oscuro.
- **✨ Animado con calma**: al activarlo, la taza se llena y el vapor se dibuja y sube en bucle. Respeta «Reducir movimiento» de macOS.
- Opción de **abrirse al iniciar sesión**.

<p align="center">
  <img src="docs/barra.png" width="720" alt="Capturas reales de la barra de menú: a la izquierda, el panel en modo normal con el cristal claro; a la derecha, despierto, con el cristal ahumado en negro ceniza y la taza humeante resaltada arriba">
</p>

| Icono arriba | Qué significa |
|---|---|
| Taza vacía | Normal: el Mac se duerme al cerrar la tapa |
| Taza humeante | Despierto: puedes cerrar la tapa |
| Taza humeante + 18:24 | Pausa café: tiempo que queda |

## Instalación

Funciona en macOS 13 o posterior, en Mac con Apple Silicon o Intel.

### Opción 1 · Una línea en la terminal (recomendada)

```bash
curl -fsSL https://raw.githubusercontent.com/laulys/despierto/main/install.sh | bash
```

Descarga la última versión, la copia a **Aplicaciones** y la abre. Así macOS no muestra el aviso de app sin verificar. Si quieres, [lee el script](install.sh) antes: es corto.

### Opción 2 · Descargar

1. Pulsa **[Descargar para macOS](https://github.com/laulys/despierto/releases/latest/download/Despierto.zip)** y descomprime el zip.
2. Arrastra **Despierto** a tu carpeta **Aplicaciones**.
3. Ábrela. La app no está firmada por Apple, así que la primera vez macOS dirá que no puede verificarla. Pulsa **Hecho**, ve a **Ajustes del Sistema → Privacidad y seguridad**, baja hasta el aviso de Despierto y pulsa **Abrir igualmente**. Solo hace falta una vez.

### Opción 3 · Compilarla tú

Necesitas las herramientas de Xcode (`xcode-select --install`).

```bash
git clone https://github.com/laulys/despierto.git
cd despierto
./build.sh
open build/Despierto.app
```

Si la vas a usar a diario, marca **«Abrir al iniciar»** en el panel.

## Seguir el chat en el móvil 📱

En el panel elige **Claude**, **Cursor** o **Codex**. El QR y el botón de copiar cambian con el destino. El Mac tiene que seguir encendido: para eso está Despierto. 😉

### Claude Code

Usa **Remote Control** de Claude Code: tus sesiones del Mac aparecen en la app de Claude del móvil (o en [claude.ai/code](https://claude.ai/code)).

- **En la app de escritorio de Claude**: activa *Settings → Claude Code → Connect new sessions to Remote Control*.
- **En la terminal**: escribe `/remote-control` dentro de una sesión (el panel tiene un botón para copiarlo) o empieza con `claude --remote-control`.

El QR lleva al chat que está trabajando (o al más reciente). Si tienes varios conectados, pulsa su nombre para elegir otro.

> **Si el móvil solo abre la app de Claude:** es un fallo conocido de la app con los enlaces de Remote Control (también pasa con el QR oficial de Claude Code). Entra en la pestaña **Code** y elige el chat con el nombre que muestra Despierto.

### Cursor

El QR abre [cursor.com/agents](https://cursor.com/agents). En el iPhone usa la [app de Cursor](https://cursor.com/mobile), inicia sesión con la misma cuenta, empareja este Mac y elige el agente local.

- Activa *Settings → Agents → Remote Control* en el escritorio.
- En el Agents Window puedes escribir `/remote-control` (también se copia desde el panel).

### Codex

El QR abre [chatgpt.com/codex](https://chatgpt.com/codex). En el móvil usa la app de ChatGPT → **Codex** (o **Remote** en versiones anteriores).

- En el Mac: app de ChatGPT → *Settings → Connections → Control this Mac* y empareja el teléfono con el QR de ChatGPT.
- En la terminal: `codex remote-control start` (el panel lo copia). La configuración oficial del móvil arranca desde la app de escritorio de ChatGPT.

### Apagar Despierto desde el móvil (Mac cerrado / en la mochila)

En la Wi‑Fi local Despierto publica el dominio Bonjour:

**[http://despierto.local:8787/](http://despierto.local:8787/)**

En el celular ves el **tiempo restante**, si **Claude / Cursor / Codex / Antigravity** están ejecutándose, podés **extender** (+15 / +30 / +1 h) y **volver a lo normal**.

1. Activá Despierto. Abrí la URL (AirDrop, Copiar, `despierto.local:8787` o QR).
2. Favoritos / «Añadir a Inicio».
3. Cerrá la tapa y seguí trabajando desde el móvil.
4. Cuando termines, extendé o apagá desde esa página.

Es **http** en la LAN (misma Wi‑Fi). Solo mientras Despierto esté activo.

## Cómo funciona

Por debajo usa el comando de macOS:

```bash
sudo pmset -a disablesleep 1   # no dormir al cerrar la tapa
sudo pmset -a disablesleep 0   # volver a lo normal
```

Como es un ajuste del sistema, **la primera vez** macOS te pide tu contraseña. Con ella, Despierto instala un permiso que **solo** sirve para esos dos comandos (`pmset -a disablesleep 0` y `1`) y lo comprueba con `visudo` antes de guardarlo. Después ya no te la vuelve a pedir, ni siquiera para el temporizador. La app nunca ve ni guarda tu contraseña: la pide el propio sistema.

¿Prefieres que te la pida siempre? Borra el permiso:

```bash
sudo rm /etc/sudoers.d/despierto
```

El temporizador de la pausa café lo lleva un pequeño proceso del sistema. Por eso funciona aunque cierres la tapa o salgas de la app.

Todo el código está en [`main.swift`](main.swift), con comentarios en español. El icono se dibuja con [`icon.swift`](icon.swift).

## ⚠️ Ojo

- Con el modo despierto en la mochila el Mac **sigue encendido** y puede calentarse: mejor poco rato y, si podés, ventilado. Cuando termines, apagalo desde el móvil.
- Con la tapa cerrada sigue gastando batería, así que mejor enchufado. Si baja del 10 % sin cargador, vuelve solo a lo normal (siempre que la app esté abierta).
- Apagar el brillo al cerrar la tapa **no reduce la RAM**: solo baja el gasto de pantalla/batería. Los agentes siguen usando memoria mientras trabajan.
- Si eliges **∞ (sin límite)**, acuérdate de volver a lo normal.

## Publicar una versión nueva

```bash
./release.sh
gh release create vX.Y.Z build/release/Despierto.zip --title "Despierto X.Y.Z"
```

`release.sh` compila la app para Apple Silicon e Intel y la empaqueta en un zip. El botón de descarga y el instalador siempre bajan la última versión publicada.
