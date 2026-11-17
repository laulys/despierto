// Despierto — mantén tu Mac encendido aunque cierres la tapa.
// Pensado para irte a por un café mientras Claude Code sigue trabajando.
//
// Por debajo usa `pmset -a disablesleep 1/0`, que necesita tu contraseña.
// Los temporizadores los lleva un pequeño proceso del sistema, así que funcionan
// aunque cierres la tapa o salgas de la app.
//
// Diseño «ceniza»: el cristal del panel ES el estado. En modo normal es claro y
// casi invisible; al activarlo se ahúma a negro ceniza.

import SwiftUI
import AppKit
import Combine
import ServiceManagement
import CoreImage
import CoreImage.CIFilterBuiltins
import IOKit
import CoreGraphics
import Darwin

// DisplayServices: API privada del brillo del panel integrado (sin IOKit.graphics).
@_silgen_name("DisplayServicesGetBrightness")
func DisplayServicesGetBrightness(_ display: CGDirectDisplayID, _ brightness: UnsafeMutablePointer<Float>) -> Int32
@_silgen_name("DisplayServicesSetBrightness")
func DisplayServicesSetBrightness(_ display: CGDirectDisplayID, _ brightness: Float) -> Int32

// MARK: - Punto de entrada

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        // `Despierto --snapshot foto.png [--state normal|timer|awake] [--dark]`
        // dibuja el panel en una imagen (para el README).
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            MainActor.assumeIsolated { Snapshot.render(to: args[i + 1], args: args) }
            return
        }
        // `Despierto --list-sessions`: muestra los chats que se pueden abrir en el móvil.
        if args.contains("--list-sessions") {
            let agents = System.detectAgents()
            print("Agentes abiertos: \(agents.isEmpty ? "ninguno" : agents.map(\.title).joined(separator: ", "))")
            let sessions = System.claudeSessions()
            print("Claude Code · chats abiertos: \(sessions.open) · conectados al móvil: \(sessions.connected.count)")
            for s in sessions.connected { print("  \(s.busy ? "●" : "○") \(s.name) → \(s.url)") }
            return
        }
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.accessory) // sin icono en el Dock
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = Despierto()
    private var controller: PanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = PanelController(model: model)
        // `--open`: abre el panel al arrancar (cuando el icono ya está colocado en la barra)
        if CommandLine.arguments.contains("--open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.controller?.show() }
        }
    }
}

// MARK: - Icono de la barra y panel de cristal

/// Panel que puede recibir teclado (para cerrar con Esc).
final class GlassPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let model: Despierto
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel: GlassPanel
    private let hosting: NSHostingView<AnyView>
    private var icon: StatusIcon!
    private var lastHide = Date.distantPast
    private var opening = false
    private var closing = false
    /// Esquina superior izquierda fija mientras el panel está abierto.
    private var anchor: NSPoint?
    private var cancellables = Set<AnyCancellable>()

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init(model: Despierto) {
        self.model = model
        hosting = NSHostingView(rootView: AnyView(PanelRoot().environmentObject(model)))
        panel = GlassPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 420),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentView = Glass.make(content: hosting)
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.hide() }

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel)
        }
        icon = StatusIcon(item: statusItem)

        // Tras escribir la contraseña, el panel vuelve al frente para que veas el cambio.
        model.onAuthorizationEnd = { [weak self] in self?.refocus() }
        model.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.update() } }
            .store(in: &cancellables)
        update()
    }

    @objc private func togglePanel() {
        if panel.isVisible && !closing { hide() }
        else if Date().timeIntervalSince(lastHide) > 0.25 { show() } // evita reabrir al pulsar el icono para cerrar
    }

    /// Entrada: baja 4 pt desde la barra y aparece (220 ms, decelera).
    func show() {
        model.refresh()
        closing = false
        // Esperamos un instante a que SwiftUI pinte el estado nuevo; si no, el panel
        // se abre con el tamaño viejo y luego «se recoloca».
        DispatchQueue.main.async { [weak self] in self?.present() }
    }

    private func present() {
        update()
        hosting.layoutSubtreeIfNeeded()
        let final = targetFrame()
        anchor = NSPoint(x: final.minX, y: final.maxY)
        if CommandLine.arguments.contains("--debug") { fputs("panel: \(final)\n", stderr) }
        NSApp.activate(ignoringOtherApps: true)
        panel.alphaValue = 0
        panel.setFrame(reduceMotion ? final : final.offsetBy(dx: 0, dy: 4), display: true)
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)
        opening = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduceMotion ? Motion.quick : 0.22
            context.timingFunction = Motion.decelerate
            panel.animator().alphaValue = 1
            panel.animator().setFrame(final, display: true)
        }, completionHandler: { [weak self] in
            Task { @MainActor in self?.opening = false }
        })
    }

    /// Salida: más corta que la entrada, acelera y sube 4 pt.
    func hide() {
        guard panel.isVisible, !closing else { return }
        closing = true
        lastHide = Date()
        statusItem.button?.highlight(false)
        let frame = panel.frame
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            context.timingFunction = Motion.accelerate
            panel.animator().alphaValue = 0
            if !reduceMotion { panel.animator().setFrame(frame.offsetBy(dx: 0, dy: 4), display: true) }
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.closing else { return } // si se volvió a abrir, no lo cerramos
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
                self.closing = false
                self.anchor = nil
            }
        })
    }

    private func refocus() {
        guard panel.isVisible, !closing else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    // Se cierra al hacer clic fuera, como un menú (salvo mientras pides la contraseña).
    func windowDidResignKey(_ notification: Notification) {
        guard !model.authorizing else { return }
        hide()
    }

    private func update() {
        // Icono y cuenta atrás en la barra de menú: taza vacía ↔ café humeante
        icon.set(awake: model.isAwake,
                 title: model.remaining.map { Format.countdown($0, fixedWidth: true) } ?? "",
                 description: model.isAwake ? "Despierto: puedes cerrar la tapa" : "Modo normal: se dormirá al cerrar la tapa")
        if panel.isVisible && !opening && !closing {
            resize()
            // Por si SwiftUI termina de colocar el contenido un instante después
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, self.panel.isVisible, !self.opening, !self.closing else { return }
                self.resize()
            }
        }
    }

    /// Debajo del icono, sin salirse de la pantalla.
    private func targetFrame() -> NSRect {
        guard let button = statusItem.button, let buttonWindow = button.window else { return panel.frame }
        let size = measuredSize()
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        // Si el icono aún no está en la barra, arriba a la derecha de la pantalla
        let top = anchor.minY > screen.maxY - 40 ? anchor.minY : screen.maxY
        let midX = anchor.minY > screen.maxY - 40 ? anchor.midX : screen.maxX
        let x = min(max(midX - size.width / 2, screen.minX + 8), screen.maxX - size.width - 8)
        return NSRect(x: x, y: top - size.height - 6, width: size.width, height: size.height)
    }

    private func measuredSize() -> NSSize {
        hosting.layoutSubtreeIfNeeded() // medir con el estado nuevo, no con el de antes
        let size = hosting.fittingSize
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    /// Si el contenido crece o encoge, el panel le acompaña hacia abajo (250 ms, misma curva).
    /// La esquina de arriba se queda quieta: aunque la cuenta atrás ensanche el icono
    /// de la barra, el panel no se desplaza de lado.
    private func resize() {
        guard let anchor else { return }
        let size = measuredSize()
        let frame = NSRect(x: anchor.x, y: anchor.y - size.height, width: size.width, height: size.height)
        guard frame != panel.frame else { return }
        if reduceMotion {
            panel.setFrame(frame, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.standard
                context.timingFunction = Motion.decelerate
                panel.animator().setFrame(frame, display: true)
            }
        }
    }
}

/// Icono de la barra de menú. Al cambiar de estado la taza se transforma
/// (efecto «replace» de SF Symbols) y, al activarlo, da un pequeño salto.
@MainActor
final class StatusIcon {
    private let item: NSStatusItem
    private let imageView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let stack: NSStackView
    private var symbol = ""

    init(item: NSStatusItem) {
        self.item = item
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        imageView.contentTintColor = .labelColor
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        stack = NSStackView(views: [imageView, label])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        if let button = item.button {
            button.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            ])
        }
    }

    func set(awake: Bool, title: String, description: String) {
        let newSymbol = awake ? "cup.and.heat.waves.fill" : "cup.and.saucer"
        if newSymbol != symbol, let image = NSImage(systemSymbolName: newSymbol, accessibilityDescription: description) {
            image.isTemplate = true
            let animate = !symbol.isEmpty && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            if #available(macOS 14.0, *), animate {
                imageView.setSymbolImage(image, contentTransition: .replace.downUp)
                if awake {
                    // Cuando termina de transformarse, un saltito: «¡listo!»
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [imageView] in
                        imageView.addSymbolEffect(.bounce.up, options: .nonRepeating)
                    }
                }
            } else {
                imageView.image = image
            }
            symbol = newSymbol
        }
        if label.stringValue != title {
            label.stringValue = title
            label.isHidden = title.isEmpty
        }
        let width = ceil(stack.fittingSize.width) + 10
        if item.length != width { item.length = width }
        item.button?.toolTip = description
        item.button?.setAccessibilityLabel(description)
    }
}

/// Un toque suave en el trackpad al cambiar de estado.
enum Haptics {
    @MainActor
    static func tap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
}

enum Glass {
    static var radius: CGFloat {
        if #available(macOS 26.0, *) { return 20 }
        return 16
    }

    /// Cristal Liquid Glass transparente en macOS 26; cristal clásico en versiones anteriores.
    /// El «humo» que lo oscurece lo pinta SwiftUI (PanelRoot), así se puede animar.
    /// `NSGlassEffectView` se resuelve en runtime para poder compilar con SDKs anteriores a macOS 26.
    @MainActor
    static func make(content: NSView) -> NSView {
        if #available(macOS 26.0, *), let glass = makeLiquidGlass(content: content) {
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = radius
        effect.layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
        ])
        return effect
    }

    @MainActor
    private static func makeLiquidGlass(content: NSView) -> NSView? {
        guard let glassClass = NSClassFromString("NSGlassEffectView") as? NSView.Type else { return nil }
        let glass = glassClass.init(frame: .zero)
        // style.clear ≈ 0 en AppKit actual; si el KVC falla, seguimos con el cristal clásico.
        glass.setValue(0, forKey: "style")
        glass.setValue(radius, forKey: "cornerRadius")
        glass.setValue(content, forKey: "contentView")
        return glass
    }
}

// MARK: - Estado de la app

struct Battery: Equatable {
    var percent: Int
    var charging: Bool
}

/// Un chat de Claude Code conectado a Remote Control (se puede abrir en el móvil).
struct ClaudeSession: Identifiable, Equatable {
    let id: String          // «session_…»
    let name: String
    let busy: Bool
    let updatedAt: Double
    var url: String { "https://claude.ai/code/\(id)" }
}

/// Agentes de código que Despierto puede vigilar mientras están abiertos.
enum CodingAgent: String, CaseIterable, Identifiable, Equatable {
    case claude, cursor, codex, antigravity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .cursor: return "Cursor"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        }
    }

    /// Nombres de proceso (`ps -axo comm=`, último componente del path).
    var processNames: Set<String> {
        switch self {
        case .claude: return ["claude", "Claude"]
        case .cursor: return ["Cursor", "cursor-agent"]
        // ChatGPT: Remote Control oficial de Codex vive en la app de escritorio.
        case .codex: return ["codex", "Codex", "com.openai.codex", "ChatGPT"]
        case .antigravity: return ["agy", "Antigravity"]
        }
    }

    /// Destino de Remote Control en el móvil (Antigravity aún no tiene portal aquí).
    var phoneTarget: PhoneTarget? {
        switch self {
        case .claude: return .claude
        case .cursor: return .cursor
        case .codex: return .codex
        case .antigravity: return nil
        }
    }

    func matches(_ target: PhoneTarget) -> Bool { phoneTarget == target }
}

/// Destino del QR / instrucciones para seguir el chat en el móvil.
enum PhoneTarget: String, CaseIterable, Identifiable, Equatable {
    case claude, cursor, codex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude"
        case .cursor: return "Cursor"
        case .codex: return "Codex"
        }
    }

    /// Enlace genérico cuando no hay sesión concreta (Cursor / Codex / Claude sin bridge).
    var portalURL: String {
        switch self {
        case .claude: return "https://claude.ai/code"
        case .cursor: return "https://cursor.com/agents"
        case .codex: return "https://chatgpt.com/codex"
        }
    }

    var copyCommand: String {
        switch self {
        case .claude, .cursor: return "/remote-control"
        case .codex: return "codex remote-control start"
        }
    }

    var copyHelp: String {
        switch self {
        case .claude: return "Cópialo y escríbelo en un chat de Claude Code en la terminal"
        case .cursor: return "Cópialo en el Agents Window de Cursor (Settings → Agents → Remote Control)"
        case .codex: return "Cópialo para arrancar Remote Control de Codex en la terminal"
        }
    }
}

@MainActor
final class Despierto: ObservableObject {
    @Published var isAwake = false
    @Published var startDate: Date?
    @Published var endDate: Date?
    @Published var now = Date()
    @Published var battery: Battery?
    @Published var openAgents: [CodingAgent] = []
    @Published var phoneSessions: [ClaudeSession] = []   // chats de Claude que se pueden abrir en el móvil
    @Published var openSessionCount = 0                  // chats de Claude abiertos en total
    @Published var selectedSessionID: String?
    @Published var phoneTarget: PhoneTarget = .claude
    @Published var mobilePane: MobilePane = .follow
    @Published var launchAtLogin = false
    @Published var errorMessage: String?
    @Published var notice: String?               // aviso tranquilo (no es un error), p. ej. tras volver solo a lo normal
    @Published var brewedAt = Date.distantPast   // cuándo se activó (arranca la animación del vapor)
    @Published var authorizing = false           // pidiendo la contraseña
    @Published var needsSetup = false            // aún no se ha dado el permiso de una sola vez
    @Published var lidClosed = false             // tapa cerrada (para apagar brillo)
    @Published var remoteStopURL: String?        // /stop?t=… (acción)
    @Published var remoteControlURL: String?     // página del móvil para guardar/abrir sin mirar el Mac
    var onAuthorizationEnd: (() -> Void)?
    private let remoteStop = RemoteStopServer()

    /// El chat elegido para el QR (por defecto, el que está trabajando o el más reciente).
    var selectedSession: ClaudeSession? {
        phoneSessions.first { $0.id == selectedSessionID } ?? phoneSessions.first
    }

    var agentsOpen: Bool { !openAgents.isEmpty }

    /// Texto corto para el aviso: «Claude Code y Cursor», etc.
    var openAgentsLabel: String {
        Format.joinedList(openAgents.map(\.title))
    }

    // Temporizador «de root» (solo si no se pudo instalar el permiso, o de versiones anteriores)
    private static let rootPidFile = "/var/run/despierto-timer.pid"
    private static let cancelRootTimer =
        "if [ -f \(rootPidFile) ]; then kill $(cat \(rootPidFile)) 2>/dev/null; rm -f \(rootPidFile); fi"
    private static let timerMarker = "despierto-timer"
    private var timerProcess: Process?

    private var ticks = 0
    private var timer: Timer?
    /// Brillo guardado antes de apagarlo al cerrar la tapa (0…1).
    private var savedBrightness: Float?
    private var dimmedForLid = false

    init(preview: Bool = false) {
        guard !preview else { return }
        startDate = UserDefaults.standard.object(forKey: "startDate") as? Date
        endDate = UserDefaults.standard.object(forKey: "endDate") as? Date
        if UserDefaults.standard.object(forKey: "savedBrightness") != nil {
            // Tras un crash con tapa cerrada: hay un brillo pendiente de restaurar.
            savedBrightness = Float(UserDefaults.standard.double(forKey: "savedBrightness"))
            dimmedForLid = true
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Segundos que quedan de la pausa café (nil = sin temporizador).
    var remaining: TimeInterval? {
        endDate.map { max(0, $0.timeIntervalSince(now)) }
    }

    /// Cuánto queda, de 1 (recién empezado) a 0 (terminado).
    var progress: Double {
        guard let startDate, let endDate, endDate > startDate else { return 1 }
        return min(1, max(0, endDate.timeIntervalSince(now) / endDate.timeIntervalSince(startDate)))
    }

    /// Duración elegida en minutos (nil = sin límite).
    var chosenMinutes: Int? {
        guard let startDate, let endDate else { return nil }
        return Int((endDate.timeIntervalSince(startDate) / 60).rounded())
    }

    // MARK: Acciones

    func start(minutes: Int?) {
        // Con la batería casi agotada y sin cargador volvería a lo normal enseguida
        if let battery = System.battery(), Self.batteryTooLow(battery) {
            errorMessage = "Queda un \(battery.percent) % de batería. Enchufa el Mac para activarlo."
            return
        }
        notice = nil
        cancelTimer()
        if System.sudoPmset(1) {
            if let minutes { startTimer(minutes: minutes) }
        } else {
            // Solo la primera vez: una contraseña instala el permiso y activa
            guard runAsAdmin(Self.setupScript(value: 1, rootTimerMinutes: minutes), prompt: Self.setupPrompt) else { return }
            checkSetup()
            if let minutes, System.passwordless { startTimer(minutes: minutes) }
        }
        let start = Date()
        saveDates(start: minutes == nil ? nil : start,
                  end: minutes.map { start.addingTimeInterval(Double($0) * 60) })
        startRemoteStopServer()
        mobilePane = .stop // el enlace ya se copió: mostrar el QR de apagar
        Haptics.tap()
        refresh()
    }

    /// Suma minutos al temporizador (o arranca uno si estaba sin límite). Usado desde el móvil.
    func extend(byMinutes minutes: Int) {
        guard isAwake, minutes > 0 else { return }
        let now = Date()
        let baseEnd = endDate.map { max($0, now) } ?? now
        let newEnd = baseEnd.addingTimeInterval(Double(minutes) * 60)
        let newStart = startDate ?? now
        cancelTimer()
        saveDates(start: newStart, end: newEnd)
        let remainingMins = max(1, Int(ceil(newEnd.timeIntervalSince(now) / 60)))
        if System.passwordless {
            startTimer(minutes: remainingMins)
        }
        publishPhoneStatus()
        notice = "Desde el móvil: +\(minutes) min · quedan \(Format.countdown(newEnd.timeIntervalSince(now)))"
        Haptics.tap()
        refresh()
    }

    func stop() {
        cancelTimer()
        stopRemoteStopServer()
        mobilePane = .follow
        if !System.sudoPmset(0) {
            guard runAsAdmin(Self.setupScript(value: 0, rootTimerMinutes: nil), prompt: Self.setupPrompt) else { return }
            checkSetup()
        }
        saveDates(start: nil, end: nil)
        restoreBrightnessIfNeeded()
        Haptics.tap()
        refresh()
    }

    /// Mini servidor en la Wi‑Fi: el móvil guarda el enlace ANTES de cerrar la tapa y apaga después.
    private func startRemoteStopServer() {
        let token: String = {
            if let existing = UserDefaults.standard.string(forKey: "remoteStopToken"), !existing.isEmpty {
                return existing
            }
            let fresh = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            UserDefaults.standard.set(fresh, forKey: "remoteStopToken")
            return fresh
        }()
        remoteStop.start(
            token: token,
            onStop: { [weak self] in Task { @MainActor in self?.stop() } },
            onExtend: { [weak self] minutes in Task { @MainActor in self?.extend(byMinutes: minutes) } }
        )
        remoteStopURL = remoteStop.stopURL
        remoteControlURL = remoteStop.controlURL
        publishPhoneStatus()
        // Copia el dominio local (Universal Clipboard → iPhone).
        if let link = remoteControlURL {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
            notice = "Copiado · abrilo en el celular antes de cerrar"
        }
    }

    /// Estado que ve la web del móvil (tiempo, agentes).
    private func publishPhoneStatus() {
        let agents = openAgents.isEmpty && isAwake ? System.detectAgents() : openAgents
        remoteStop.updateStatus(PhoneDashboard(
            awake: isAwake,
            remainingSeconds: endDate.map { max(0, Int($0.timeIntervalSince(now))) },
            unlimited: isAwake && endDate == nil,
            claude: agents.contains(.claude),
            cursor: agents.contains(.cursor),
            codex: agents.contains(.codex),
            antigravity: agents.contains(.antigravity)
        ))
    }

    private func stopRemoteStopServer() {
        remoteStop.stop()
        remoteStopURL = nil
        remoteControlURL = nil
    }

    func copyRemoteStopLink() {
        guard let link = remoteControlURL ?? remoteStopURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
        notice = "Copiado · Safari → \(RemoteStopServer.localHost)"
    }

    /// AirDrop / Mensajes / Mail: la forma más simple de dejar el enlace en el celular.
    func shareRemoteStopLink() {
        guard let link = remoteControlURL ?? remoteStopURL, let url = URL(string: link) else { return }
        let items: [Any] = [url, "Despierto — abrí este enlace en Safari (misma Wi‑Fi). Cuando termines, tocá «Volver a lo normal»."]
        let picker = NSSharingServicePicker(items: items)
        if let anchor = NSApp.windows.first(where: { $0.isVisible && $0 is GlassPanel })?.contentView {
            picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } else if let airDrop = NSSharingService(named: .sendViaAirDrop) {
            airDrop.perform(withItems: items)
        }
    }

    private static let setupPrompt = "Despierto necesita tu contraseña una última vez. Después ya no te la volverá a pedir."
    static let setupLogPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Despierto-setup.log").path

    /// Tras la contraseña, comprueba que el permiso quedó guardado; si no, lo dice.
    private func checkSetup() {
        if !System.passwordless {
            errorMessage = "Se cambió, pero no se pudo guardar el permiso para no pedir la contraseña. Detalles en ~/Library/Logs/Despierto-setup.log"
        }
    }

    /// La primera vez: instala un permiso que SOLO sirve para `pmset -a disablesleep 0/1`
    /// (comprobado con visudo antes de guardarlo) y hace el cambio. Si el permiso no se
    /// pudo instalar, el temporizador lo lleva un proceso de root como antes.
    private static func setupScript(value: Int, rootTimerMinutes minutes: Int?) -> String {
        // Cada paso queda apuntado en ~/Library/Logs/Despierto-setup.log por si algo falla
        let log = setupLogPath
        var script = "exec >>'\(log)' 2>&1; echo; date; " + cancelRootTimer
        let user = NSUserName()
        if user.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil {
            let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
            script += "; T=$(/usr/bin/mktemp /tmp/despierto.XXXXXX) && echo \"1 temporal: $T\""
                + " && printf '%s\\n' '# Despierto: activar o desactivar disablesleep sin contrasena' '\(rule)' > \"$T\" && echo '2 regla escrita'"
                + " && /usr/sbin/visudo -cf \"$T\" && echo '3 regla valida'"
                + " && /usr/bin/install -m 0440 -o root -g wheel \"$T\" \(System.sudoersFile) && echo '4 permiso guardado'"
                + "; rm -f \"$T\""
        } else {
            script += "; echo 'nombre de usuario raro: no se instala el permiso'"
        }
        script += "; /usr/bin/pmset -a disablesleep \(value) && echo '5 pmset \(value) ok'; /bin/chmod 644 '\(log)'"
        if let minutes {
            script += "; if [ ! -f \(System.sudoersFile) ]; then"
                + " /bin/sh -c 'sleep \(minutes * 60); /usr/bin/pmset -a disablesleep 0; rm -f \(rootPidFile)' >/dev/null 2>&1 &"
                + " echo $! > \(rootPidFile); fi"
        }
        return script
    }

    /// Temporizador sin contraseña: un proceso pequeño que sigue aunque cierres la tapa o salgas de la app.
    private func startTimer(minutes: Int) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Si se cancela (TERM), sale sin tocar nada; si llega al final, vuelve a lo normal.
        let script = "trap 'kill $! 2>/dev/null; exit 0' TERM; sleep \(minutes * 60) & wait $!; "
            + "/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0"
        process.arguments = ["-c", script, Self.timerMarker]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            timerProcess = process
            UserDefaults.standard.set(Int(process.processIdentifier), forKey: "timerPID")
        } catch {
            errorMessage = "No se pudo poner el temporizador: \(error.localizedDescription)"
        }
    }

    // MARK: Batería baja

    /// Con la batería a este nivel o menos, y sin cargador, vuelve solo a lo normal.
    static let lowBatteryLimit = 10

    static func batteryTooLow(_ battery: Battery) -> Bool {
        !battery.charging && battery.percent <= lowBatteryLimit
    }

    static func lowBatteryNotice(percent: Int, at date: Date) -> String {
        "A las \(date.formatted(date: .omitted, time: .shortened)), con la batería al \(percent) %, "
            + "volvió solo a lo normal para que el Mac pudiera dormirse."
    }

    /// Batería casi agotada y sin cargador: vuelve a lo normal para que el Mac pueda dormirse.
    /// Solo con el permiso sin contraseña: con la tapa cerrada nadie podría escribirla.
    private func returnToNormal(lowBattery battery: Battery) {
        guard System.sudoPmset(0) else { return }
        cancelTimer()
        stopRemoteStopServer()
        isAwake = false
        restoreBrightnessIfNeeded()
        notice = Self.lowBatteryNotice(percent: battery.percent, at: Date())
    }

    /// Con Despierto activo y tapa cerrada: brillo a 0 (ahorro de pantalla/batería, no de RAM).
    /// Al abrir la tapa o volver a lo normal, restaura el brillo anterior.
    /// No enciende el backlight mientras la tapa siga cerrada.
    private func syncLidBrightness() {
        lidClosed = System.lidClosed()
        if isAwake && lidClosed {
            dimBrightnessForLid()
        } else if !lidClosed {
            restoreBrightnessIfNeeded()
        }
    }

    private func dimBrightnessForLid() {
        guard !dimmedForLid else { return }
        let current = System.displayBrightness() ?? savedBrightness ?? 0.5
        // Solo guardamos el brillo si realmente pudimos apagarlo.
        guard System.setDisplayBrightness(0) else { return }
        savedBrightness = current
        UserDefaults.standard.set(Double(current), forKey: "savedBrightness")
        dimmedForLid = true
    }

    private func restoreBrightnessIfNeeded() {
        guard dimmedForLid || savedBrightness != nil else { return }
        // Con la tapa cerrada no subimos el brillo (evita encender el panel a ciegas).
        if System.lidClosed() { return }
        let stored = Float(UserDefaults.standard.double(forKey: "savedBrightness"))
        let level = max(0.01, min(1, savedBrightness ?? (stored > 0 ? stored : 0.5)))
        // Solo olvidamos el nivel guardado si el sistema aceptó el cambio.
        guard System.setDisplayBrightness(level) else { return }
        dimmedForLid = false
        savedBrightness = nil
        UserDefaults.standard.removeObject(forKey: "savedBrightness")
    }

    func copyRemoteControlCommand(for target: PhoneTarget? = nil) {
        let command = (target ?? phoneTarget).copyCommand
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    /// Para el temporizador anterior (solo si de verdad es el nuestro).
    private func cancelTimer() {
        let pid = Int32(UserDefaults.standard.integer(forKey: "timerPID"))
        UserDefaults.standard.removeObject(forKey: "timerPID")
        timerProcess = nil
        guard pid > 0, System.isDespiertoTimer(pid: pid) else { return }
        kill(pid, SIGTERM) // el propio temporizador para su `sleep` y sale sin ejecutar nada
    }

    func toggleLaunchAtLogin() {
        do {
            if launchAtLogin { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            errorMessage = "No se pudo cambiar el inicio automático: \(error.localizedDescription)"
        }
        refresh()
    }

    // MARK: Lectura del sistema

    func refresh() {
        let wasAwake = isAwake
        isAwake = System.sleepDisabled()
        if isAwake && !wasAwake {
            brewedAt = Date()
            startRemoteStopServer()
        }
        if !isAwake && wasAwake { stopRemoteStopServer() }
        battery = System.battery()
        if isAwake, let battery, Self.batteryTooLow(battery) { returnToNormal(lowBattery: battery) }
        openAgents = System.detectAgents()
        // Solo sugiere un destino al arrancar / si no hay ninguno elegido a mano.
        // No pisa una elección del usuario (p. ej. ver el QR de Codex con Cursor abierto).
        let sessions = System.claudeSessions()
        openSessionCount = sessions.open
        if phoneSessions != sessions.connected { phoneSessions = sessions.connected }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        needsSetup = !FileManager.default.fileExists(atPath: System.sudoersFile)
        syncLidBrightness()
        if isAwake {
            remoteStopURL = remoteStop.stopURL ?? remoteStopURL
            remoteControlURL = remoteStop.controlURL ?? remoteControlURL
            publishPhoneStatus()
        }

        // Si ya no está despierto, o el temporizador se perdió (p. ej. al reiniciar), lo olvidamos.
        let timerLost = endDate.map { $0.timeIntervalSinceNow < -10 } ?? false
        if !isAwake || timerLost { saveDates(start: nil, end: nil) }
    }

    private func tick() {
        now = Date()
        ticks += 1
        // Brillo/tapa cada segundo si hay algo que hacer (incl. recuperación tras crash).
        if isAwake || dimmedForLid || savedBrightness != nil { syncLidBrightness() }
        if isAwake { publishPhoneStatus() }
        let timerJustEnded = endDate.map { $0 <= now } ?? false
        if ticks % 5 == 0 || timerJustEnded { refresh() }
    }

    private func saveDates(start: Date?, end: Date?) {
        startDate = start
        endDate = end
        UserDefaults.standard.set(start, forKey: "startDate")
        UserDefaults.standard.set(end, forKey: "endDate")
    }

    private func runAsAdmin(_ command: String, prompt: String) -> Bool {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let source = "do shell script \"\(escape(command))\" with prompt \"\(escape(prompt))\" with administrator privileges"
        authorizing = true
        defer {
            authorizing = false
            onAuthorizationEnd?()
        }
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            // -128 = has pulsado «Cancelar»: no es un error.
            if (error[NSAppleScript.errorNumber] as? Int) != -128 {
                errorMessage = error[NSAppleScript.errorMessage] as? String ?? "Algo salió mal."
            }
            return false
        }
        errorMessage = nil
        return true
    }
}

enum System {
    /// Permiso de una sola vez para cambiar `disablesleep` sin contraseña.
    static let sudoersFile = "/etc/sudoers.d/despierto"

    /// ¿Ya no hace falta contraseña?
    static var passwordless: Bool {
        FileManager.default.fileExists(atPath: sudoersFile)
            && status("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "1"]) == 0
    }

    /// Cambia el ajuste sin contraseña. Devuelve false si aún no hay permiso.
    static func sudoPmset(_ value: Int) -> Bool {
        guard FileManager.default.fileExists(atPath: sudoersFile) else { return false }
        return status("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", "\(value)"]) == 0
    }

    static func isDespiertoTimer(pid: Int32) -> Bool {
        run("/bin/ps", ["-p", "\(pid)", "-o", "args="]).contains("despierto-timer")
    }

    @discardableResult
    static func status(_ path: String, _ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// `pmset -g` solo muestra «SleepDisabled 1» cuando está activado.
    static func sleepDisabled() -> Bool {
        for line in run("/usr/bin/pmset", ["-g"]).split(separator: "\n") where line.contains("SleepDisabled") {
            return line.split(whereSeparator: \.isWhitespace).last == "1"
        }
        return false
    }

    static func battery() -> Battery? {
        let output = run("/usr/bin/pmset", ["-g", "batt"])
        guard let range = output.range(of: #"\d+(?=%)"#, options: .regularExpression),
              let percent = Int(output[range]) else { return nil }
        return Battery(percent: percent, charging: output.contains("AC Power"))
    }

    /// Procesos en ejecución (solo el nombre del binario).
    static func runningProcessNames() -> Set<String> {
        Set(run("/bin/ps", ["-axo", "comm="])
            .split(separator: "\n")
            .compactMap { line -> String? in
                let name = line.split(separator: "/").last?.trimmingCharacters(in: .whitespaces) ?? ""
                return name.isEmpty ? nil : name
            })
    }

    /// Claude Code lanzado como `claude`, o vía node/bun/tsx, o con sesión viva en ~/.claude.
    static func claudeCodeRunning() -> Bool {
        let names = runningProcessNames()
        if !CodingAgent.claude.processNames.isDisjoint(with: names) { return true }
        if claudeSessions().open > 0 { return true }
        return run("/bin/ps", ["-axo", "args="])
            .split(separator: "\n")
            .contains { line in
                let args = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !args.isEmpty else { return false }
                let tokens = args.split(whereSeparator: \.isWhitespace).map(String.init)
                guard let first = tokens.first else { return false }
                let base = first.split(separator: "/").last.map(String.init) ?? first
                if base == "claude" { return true }
                // node / bun / tsx invocando el CLI de Claude Code
                let runners: Set<String> = ["node", "bun", "tsx", "npm", "npx"]
                guard runners.contains(base) else { return false }
                return tokens.dropFirst().contains { token in
                    let leaf = token.split(separator: "/").last.map(String.init) ?? token
                    return leaf == "claude" || token.hasSuffix("/claude")
                }
            }
    }

    /// Claude Code, Cursor, Codex y Antigravity (`agy`) si están abiertos.
    static func detectAgents() -> [CodingAgent] {
        let names = runningProcessNames()
        return CodingAgent.allCases.filter { agent in
            if agent == .claude { return claudeCodeRunning() }
            return !agent.processNames.isDisjoint(with: names)
        }
    }

    /// ¿Tapa cerrada? (clamshell). En desktop siempre false.
    static func lidClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        guard let raw = IORegistryEntryCreateCFProperty(
            service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else { return false }
        if let flag = raw as? Bool { return flag }
        if let number = raw as? NSNumber { return number.boolValue }
        return false
    }

    /// Displays integrados del Mac (no monitores externos).
    static func builtinDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) != 0 }
    }

    /// Brillo del panel integrado (0…1). Usa DisplayServices.
    static func displayBrightness() -> Float? {
        let targets = builtinDisplayIDs()
        let ids = targets.isEmpty ? [CGMainDisplayID()] : targets
        for id in ids {
            var value: Float = 0
            if DisplayServicesGetBrightness(id, &value) == 0 { return value }
        }
        return nil
    }

    /// Pone el brillo de todos los paneles integrados. Devuelve false si ninguno respondió.
    @discardableResult
    static func setDisplayBrightness(_ value: Float) -> Bool {
        let clamped = max(0, min(1, value))
        let targets = builtinDisplayIDs()
        let ids = targets.isEmpty ? [CGMainDisplayID()] : targets
        var ok = false
        for id in ids where DisplayServicesSetBrightness(id, clamped) == 0 {
            ok = true
        }
        return ok
    }

    /// Lee los chats abiertos de Claude Code (~/.claude/sessions/<pid>.json).
    /// Los que tienen `bridgeSessionId` están conectados a Remote Control.
    static func claudeSessions() -> (open: Int, connected: [ClaudeSession]) {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var open = 0
        var connected: [ClaudeSession] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let pid = (json["pid"] as? NSNumber)?.int32Value,
                  kill(pid, 0) == 0 || errno == EPERM   // ¿sigue abierto?
            else { continue }
            open += 1
            guard let id = json["bridgeSessionId"] as? String, id.hasPrefix("session_") else { continue }
            connected.append(ClaudeSession(
                id: id,
                name: (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Chat sin nombre",
                busy: json["status"] as? String == "busy",
                updatedAt: (json["updatedAt"] as? NSNumber)?.doubleValue ?? 0))
        }
        // Primero el que está trabajando, luego el más reciente
        connected.sort { ($0.busy ? 1 : 0, $0.updatedAt) > ($1.busy ? 1 : 0, $1.updatedAt) }
        return (open, connected)
    }

    /// IPv4 de la Wi‑Fi/Ethernet activa (para el QR de apagado remoto).
    static func lanIPv4() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let iface = ptr {
            defer { ptr = iface.pointee.ifa_next }
            guard iface.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: iface.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let saLen = iface.pointee.ifa_addr.pointee.sa_len
            let addrLen = saLen > 0 ? socklen_t(saLen) : socklen_t(MemoryLayout<sockaddr_in>.size)
            let result = getnameinfo(iface.pointee.ifa_addr, addrLen,
                                     &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            guard result == 0 else { continue }
            let ip = String(cString: hostname)
            if ip.hasPrefix("127.") || ip.hasPrefix("169.254.") { continue }
            address = ip
            if name == "en0" { break } // prefer Wi‑Fi
        }
        return address
    }

    private static func run(_ path: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Apagado remoto (misma Wi‑Fi)

/// Snapshot para la web del móvil (se actualiza desde el hilo principal).
struct PhoneDashboard: Sendable {
    var awake = false
    var remainingSeconds: Int? = nil
    var unlimited = false
    var claude = false
    var cursor = false
    var codex = false
    var antigravity = false

    var json: String {
        let rem = remainingSeconds.map(String.init) ?? "null"
        return """
        {"awake":\(awake),"remainingSeconds":\(rem),"unlimited":\(unlimited),\
        "claude":\(claude),"cursor":\(cursor),"codex":\(codex),"antigravity":\(antigravity)}
        """
    }
}

/// HTTP + Bonjour (`despierto.local`) con panel móvil: tiempo, agentes, extender, apagar.
final class RemoteStopServer: @unchecked Sendable {
    static let port: UInt16 = 8787
    /// Dominio mDNS fijo en la red local (misma Wi‑Fi).
    static let localHost = "despierto.local"
    /// Puerto como texto fijo (evitar que SwiftUI formatee 8787 → «8.787»).
    static let portText = "8787"
    static var hostPort: String { "\(localHost):\(portText)" }

    private(set) var stopURL: String?
    /// Página con botón (para bookmark / pestaña abierta). No apaga al abrirla.
    private(set) var controlURL: String?
    private var token = ""
    private var onStop: (() -> Void)?
    private var onExtend: ((Int) -> Void)?
    private var serverFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    /// `dns-sd -P` publica despierto.local → IP actual.
    private var bonjourProcess: Process?
    private let statusLock = NSLock()
    private var dashboard = PhoneDashboard()

    func updateStatus(_ status: PhoneDashboard) {
        statusLock.lock()
        dashboard = status
        statusLock.unlock()
    }

    private func currentStatus() -> PhoneDashboard {
        statusLock.lock()
        defer { statusLock.unlock() }
        return dashboard
    }

    @MainActor
    func start(token: String, onStop: @escaping () -> Void, onExtend: @escaping (Int) -> Void) {
        stop()
        self.token = token
        self.onStop = onStop
        self.onExtend = onExtend
        guard let ip = System.lanIPv4() else {
            stopURL = nil
            controlURL = nil
            return
        }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { stopURL = nil; controlURL = nil; return }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Self.port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)

        let bindOK: Bool = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard bindOK, listen(fd, 4) == 0 else {
            Darwin.close(fd)
            stopURL = nil
            controlURL = nil
            return
        }

        serverFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        acceptSource = source

        controlURL = "http://\(Self.localHost):\(Self.portText)/"
        stopURL = "http://\(Self.localHost):\(Self.portText)/stop?t=\(token)"
        startBonjour(ip: ip)
    }

    @MainActor
    func stop() {
        stopBonjour()
        acceptSource?.cancel()
        acceptSource = nil
        if serverFD >= 0 { serverFD = -1 }
        stopURL = nil
        controlURL = nil
        onStop = nil
        onExtend = nil
    }

    private func startBonjour(ip: String) {
        stopBonjour()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dns-sd")
        process.arguments = [
            "-P", "Despierto", "_http._tcp", "local.",
            Self.portText, "\(Self.localHost).", ip,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            bonjourProcess = process
        } catch {
            bonjourProcess = nil
        }
    }

    private func stopBonjour() {
        guard let process = bonjourProcess else { return }
        bonjourProcess = nil
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
            if process.isRunning { process.interrupt() }
        }
    }

    private func acceptClient() {
        var addr = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let client: Int32 = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                accept(serverFD, $0, &len)
            }
        }
        guard client >= 0 else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.serve(client)
        }
    }

    private func queryValue(_ name: String, in pathAndQuery: String) -> String? {
        guard let q = pathAndQuery.split(separator: "?", maxSplits: 1).dropFirst().first else { return nil }
        for part in q.split(separator: "&") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == name { return String(kv[1]) }
        }
        return nil
    }

    private func authorized(_ path: String, request: String) -> Bool {
        queryValue("t", in: path) == token || request.contains("t=\(token)")
    }

    private func serve(_ client: Int32) {
        defer { Darwin.close(client) }
        var buffer = [UInt8](repeating: 0, count: 8192)
        let n = recv(client, &buffer, buffer.count, 0)
        guard n > 0 else { return }
        let request = String(decoding: buffer.prefix(n), as: UTF8.self)
        let firstLine = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let path = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let pathOnly = String(path.split(separator: "?", maxSplits: 1).first ?? Substring(path))

        let httpStatus: String
        let contentType: String
        let body: String

        if pathOnly == "/api/status", authorized(path, request: request) {
            httpStatus = "200 OK"
            contentType = "application/json; charset=utf-8"
            body = currentStatus().json
        } else if pathOnly == "/api/extend", authorized(path, request: request) {
            let minutes = Int(queryValue("minutes", in: path) ?? "") ?? 15
            let extend = onExtend
            DispatchQueue.main.async { extend?(max(1, min(minutes, 240))) }
            httpStatus = "200 OK"
            contentType = "application/json; charset=utf-8"
            body = "{\"ok\":true,\"minutes\":\(max(1, min(minutes, 240)))}"
        } else if pathOnly == "/stop", authorized(path, request: request) {
            httpStatus = "200 OK"
            contentType = "text/html; charset=utf-8"
            body = Self.doneHTML
            let callback = onStop
            DispatchQueue.main.async { callback?() }
        } else if pathOnly == "/" || pathOnly == "/index" || pathOnly.isEmpty {
            httpStatus = "200 OK"
            contentType = "text/html; charset=utf-8"
            body = Self.dashboardHTML(token: token)
        } else {
            httpStatus = "404 Not Found"
            contentType = "text/plain; charset=utf-8"
            body = "Not found"
        }

        let payload = Array("""
        HTTP/1.1 \(httpStatus)\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.utf8.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        Access-Control-Allow-Origin: *\r
        \r
        \(body)
        """.utf8)
        _ = payload.withUnsafeBytes { raw in
            send(client, raw.baseAddress, payload.count, 0)
        }
    }

    private static let doneHTML = """
    <!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
    <title>Despierto</title>
    <body style="font-family:-apple-system,sans-serif;background:#141413;color:#ECEAE6;display:flex;min-height:100vh;align-items:center;justify-content:center;margin:0">
    <div style="text-align:center;padding:24px"><h1 style="font-size:22px;margin:0 0 8px">Listo</h1>
    <p style="opacity:.7;margin:0">Despierto volvió a lo normal. El Mac ya puede dormirse.</p></div></body>
    """

    private static func dashboardHTML(token: String) -> String {
        """
        <!doctype html>
        <html lang=es>
        <meta charset=utf-8>
        <meta name=viewport content="width=device-width,initial-scale=1,viewport-fit=cover">
        <meta name=apple-mobile-web-app-capable content=yes>
        <title>Despierto</title>
        <style>
          :root { color-scheme: dark; }
          * { box-sizing: border-box; }
          body { margin:0; font-family:-apple-system,BlinkMacSystemFont,sans-serif; background:#141413; color:#ECEAE6;
                 min-height:100vh; padding:28px 20px 40px; }
          .wrap { max-width:380px; margin:0 auto; }
          h1 { font-size:22px; font-weight:650; margin:0 0 4px; letter-spacing:-.02em; }
          .sub { opacity:.55; font-size:13px; margin:0 0 22px; }
          .time { font-size:48px; font-weight:650; font-variant-numeric:tabular-nums; letter-spacing:-.03em;
                  margin:8px 0 4px; }
          .time-label { opacity:.55; font-size:13px; margin-bottom:22px; }
          .agents { display:grid; gap:8px; margin:0 0 22px; }
          .agent { display:flex; justify-content:space-between; align-items:center; padding:12px 14px;
                   border-radius:12px; background:rgba(255,255,255,.06); font-size:14px; }
          .agent .name { font-weight:600; }
          .pill { font-size:11px; font-weight:650; padding:4px 8px; border-radius:999px; }
          .on { background:rgba(110,231,160,.18); color:#6EE7A0; }
          .off { background:rgba(255,255,255,.08); color:rgba(236,234,230,.45); }
          .row { display:flex; gap:8px; flex-wrap:wrap; margin:0 0 12px; }
          button, .btn { appearance:none; border:0; cursor:pointer; font:inherit; font-weight:650; font-size:14px;
                         padding:14px 16px; border-radius:12px; text-decoration:none; text-align:center;
                         flex:1 1 30%; min-width:96px; color:#141413; background:#ECEAE6; }
          button.ghost { background:rgba(255,255,255,.08); color:#ECEAE6; }
          .stop { width:100%; background:#FBBF57; color:#141413; margin-top:8px; }
          .err { color:#FBBF57; font-size:13px; min-height:1.2em; margin-top:12px; }
        </style>
        <body>
        <div class=wrap>
          <h1>Despierto</h1>
          <p class=sub>despierto.local:8787 · misma Wi‑Fi</p>
          <div class=time id=time>—</div>
          <div class=time-label id=timeLabel>Cargando…</div>
          <div class=agents>
            <div class=agent><span class=name>Claude Code</span><span class="pill off" id=claude>…</span></div>
            <div class=agent><span class=name>Cursor</span><span class="pill off" id=cursor>…</span></div>
            <div class=agent><span class=name>Codex</span><span class="pill off" id=codex>…</span></div>
            <div class=agent><span class=name>Antigravity</span><span class="pill off" id=agy>…</span></div>
          </div>
          <div class=row>
            <button type=button onclick="extend(15)">+15 min</button>
            <button type=button onclick="extend(30)">+30 min</button>
            <button type=button onclick="extend(60)">+1 h</button>
          </div>
          <a class="btn stop" href="/stop?t=\(token)">Volver a lo normal</a>
          <p class=err id=err></p>
        </div>
        <script>
        const T = "\(token)";
        function fmt(sec) {
          sec = Math.max(0, sec|0);
          const h = Math.floor(sec/3600), m = Math.floor((sec%3600)/60), s = sec%60;
          if (h > 0) return h + ":" + String(m).padStart(2,"0") + ":" + String(s).padStart(2,"0");
          return m + ":" + String(s).padStart(2,"0");
        }
        function setAgent(id, on) {
          const el = document.getElementById(id);
          el.textContent = on ? "Ejecutando" : "No";
          el.className = "pill " + (on ? "on" : "off");
        }
        async function refresh() {
          try {
            const r = await fetch("/api/status?t=" + T, { cache: "no-store" });
            const d = await r.json();
            if (!d.awake) {
              document.getElementById("time").textContent = "—";
              document.getElementById("timeLabel").textContent = "Despierto no está activo";
            } else if (d.unlimited) {
              document.getElementById("time").textContent = "∞";
              document.getElementById("timeLabel").textContent = "Sin límite · podés extender o apagar";
            } else {
              document.getElementById("time").textContent = fmt(d.remainingSeconds);
              document.getElementById("timeLabel").textContent = "Tiempo restante";
            }
            setAgent("claude", d.claude);
            setAgent("cursor", d.cursor);
            setAgent("codex", d.codex);
            setAgent("agy", d.antigravity);
            document.getElementById("err").textContent = "";
          } catch (e) {
            document.getElementById("err").textContent = "Sin conexión con el Mac (¿misma Wi‑Fi?)";
          }
        }
        async function extend(minutes) {
          try {
            await fetch("/api/extend?t=" + T + "&minutes=" + minutes, { cache: "no-store" });
            setTimeout(refresh, 400);
          } catch (e) {
            document.getElementById("err").textContent = "No se pudo extender";
          }
        }
        refresh();
        setInterval(refresh, 2000);
        </script>
        </body>
        </html>
        """
    }
}

// MARK: - Panel

/// Raíz del panel: el «humo» que oscurece el cristal y el esquema de color.
struct PanelRoot: View {
    @EnvironmentObject var model: Despierto
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        PanelView()
            .environment(\.colorScheme, model.isAwake ? .dark : systemScheme)
            .frame(maxHeight: .infinity, alignment: .top) // al cambiar de tamaño, el contenido se queda arriba
            .background(
                RoundedRectangle(cornerRadius: Glass.radius, style: .continuous)
                    .fill(Smoke.color(awake: model.isAwake, scheme: systemScheme))
                    .animation(Motion.curve(Motion.slow), value: model.isAwake) // el cristal se ahúma despacio, como el vapor
            )
    }
}

/// Cuánto se ahúma el cristal en cada estado.
enum Smoke {
    static func color(awake: Bool, scheme: ColorScheme) -> Color {
        if awake { return Ash.c950.opacity(0.74) }
        return scheme == .dark ? Ash.c900.opacity(0.3) : Color.white.opacity(0.5)
    }
}

struct PanelView: View {
    @EnvironmentObject var model: Despierto

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StatusHeader()
                .padding(.bottom, 20)
            DurationControl()
            if model.isAwake {
                ReturnButton()
                    .padding(.top, 10)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -4)), removal: .opacity))
            }
            Hairline().padding(.vertical, 14)
            VStack(alignment: .leading, spacing: 14) {
                if model.agentsOpen {
                    AgentsRow().transition(.opacity)
                }
                // Un bloque, un QR: apagar o seguir desde el móvil.
                MobileSection().transition(.opacity)
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                    .transition(.opacity)
            }
            if let notice = model.notice {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: noticeIcon(for: notice))
                    Text(notice).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 10)
                .transition(.opacity)
            }
            Hairline().padding(.top, 14).padding(.bottom, 12)
            Footer()
        }
        .padding(18)
        .frame(width: 320)
        .animation(Motion.curve(Motion.standard), value: model.isAwake)
        .animation(Motion.curve(Motion.standard), value: model.openAgents)
        .animation(Motion.curve(Motion.standard), value: model.phoneTarget)
        .animation(Motion.curve(Motion.standard), value: model.mobilePane)
        .animation(Motion.curve(Motion.standard), value: model.errorMessage)
        .animation(Motion.curve(Motion.standard), value: model.notice)
    }

    private func noticeIcon(for notice: String) -> String {
        notice.hasPrefix("Copiado") || notice.hasPrefix("Enlace") ? "link" : "battery.25percent"
    }
}

struct StatusHeader: View {
    @EnvironmentObject var model: Despierto

    private var title: String {
        if !model.isAwake { return "Modo normal" }
        return model.remaining == nil ? "Despierto" : "Pausa café"
    }

    private var subtitle: String {
        model.isAwake ? "Puedes cerrar la tapa tranquilamente" : "Se dormirá al cerrar la tapa"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                BrewIcon(awake: model.isAwake, brewedAt: model.brewedAt)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .textMorph()
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textMorph()
                }
                Spacer(minLength: 0)
            }

            if let remaining = model.remaining, let endDate = model.endDate {
                Countdown(remaining: remaining, endDate: endDate, progress: model.progress)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -6)), removal: .opacity))
            }
        }
        // La cuenta atrás entra 80 ms después de la taza (escalonado)
        .animation(Motion.curve(Motion.standard).delay(0.08), value: model.endDate)
    }
}

/// Taza vacía (normal) ↔ taza llena con vapor (despierto). El momento estrella:
/// la taza se hunde un instante (anticipación), se llena con un pequeño rebote
/// y el vapor se dibuja de abajo arriba.
struct BrewIcon: View {
    let awake: Bool
    let brewedAt: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(awake ? Ash.c100 : Color.primary.opacity(0.09))
            VStack(spacing: -1) {
                Steam(brewedAt: brewedAt, animate: awake && !reduceMotion)
                    .frame(width: 14, height: 9)
                    .opacity(awake ? 1 : 0)
                    .offset(y: awake || reduceMotion ? 0 : -3) // al apagarse, el vapor se escapa hacia arriba
                    .animation(awake ? Motion.curve(Motion.standard) : Motion.accelerateCurve(Motion.quick), value: awake)
                Image(systemName: awake ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .font(.system(size: 15, weight: .semibold))
                    .symbolSwap()
            }
            .foregroundStyle(awake ? Ash.c950 : Color.primary)
            .offset(y: awake ? 0 : -4) // sin vapor, la taza se centra
        }
        .frame(width: 40, height: 40)
        .animation(reduceMotion ? Motion.curve(Motion.quick) : Motion.settle, value: awake)
        .accessibilityHidden(true)
    }
}

/// Tres hilos de vapor. Al activarlo se dibujan de abajo arriba (escalonados 70 ms);
/// luego suben y se desvanecen en bucle, como gas: lento, suave y sin saltos.
struct Steam: View {
    let brewedAt: Date
    let animate: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animate)) { context in
            Canvas { ctx, size in
                let t = animate ? context.date.timeIntervalSince(brewedAt) : 10
                for i in 0..<3 {
                    let wisp = Double(i)
                    // 1. Se dibuja (después de que la taza se llene)
                    let intro = Motion.easeOutCubic(min(1, max(0, (t - 0.15 - wisp * 0.07) / 0.45)))
                    // 2. Bucle: cada hilo sube 2,5 pt y se desvanece; empieza y acaba invisible
                    let cycle = animate ? ((t + wisp * 0.8) / 2.4).truncatingRemainder(dividingBy: 1) : 0.5
                    let breath = pow(sin(cycle * .pi), 0.8)
                    let rise = CGFloat(cycle) * 2.5
                    let sway = CGFloat(sin((t + wisp) * 1.6)) * 0.6
                    let x = size.width * (CGFloat(i) + 0.5) / 3

                    var path = Path()
                    path.move(to: CGPoint(x: x, y: size.height))
                    path.addCurve(to: CGPoint(x: x + sway, y: 0),
                                  control1: CGPoint(x: x - 2.2, y: size.height * 0.66),
                                  control2: CGPoint(x: x + 2.2 + sway, y: size.height * 0.33))
                    ctx.opacity = 0.9 * min(1, intro * 1.4) * (animate ? breath : 1)
                    ctx.stroke(path.trimmedPath(from: 0, to: intro).offsetBy(dx: 0, dy: -rise),
                               with: .foreground,
                               style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                }
            }
        }
    }
}

struct Countdown: View {
    let remaining: TimeInterval
    let endDate: Date
    let progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(Format.countdown(remaining))
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .countdownTransition() // las cifras ruedan hacia abajo al descontar
                    .animation(Motion.curve(0.3), value: Int(remaining.rounded(.up)))
                Spacer()
                Text("hasta las \(Format.time(endDate))")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.14))
                    Capsule().fill(Color.primary)
                        .frame(width: geo.size.width * progress)
                        .animation(.linear(duration: 1), value: progress) // progreso continuo
                }
            }
            .frame(height: 3)
        }
    }
}

struct DurationControl: View {
    @EnvironmentObject var model: Despierto
    @Namespace private var selection
    private let options: [(id: String, minutes: Int?)] = [
        ("15 min", 15), ("30 min", 30), ("1 h", 60), ("2 h", 120), ("sin límite", nil),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.isAwake ? "Cambiar el tiempo" : "¿Cuánto tiempo te vas?")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .textMorph()
            HStack(spacing: 2) {
                ForEach(options, id: \.id) { option in
                    Segment(option: option,
                            selected: model.isAwake && model.chosenMinutes == option.minutes,
                            namespace: selection) {
                        model.start(minutes: option.minutes)
                    }
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))
            // La selección se desliza de un tiempo a otro
            .animation(Motion.slide, value: model.chosenMinutes)
            .animation(Motion.slide, value: model.isAwake)
            if model.needsSetup {
                Label("Solo la primera vez te pedirá la contraseña.", systemImage: "lock.open")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .animation(Motion.curve(Motion.standard), value: model.needsSetup)
    }

    private struct Segment: View {
        let option: (id: String, minutes: Int?)
        let selected: Bool
        let namespace: Namespace.ID
        let action: () -> Void
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            Button(action: action) {
                Group {
                    if option.minutes == nil {
                        Image(systemName: "infinity").font(.system(size: 13, weight: .semibold))
                    } else {
                        Text(option.id).font(.system(size: 12, weight: .semibold))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 28)
                .foregroundStyle(selected ? (scheme == .dark ? Ash.c950 : .white) : Color.primary)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary)
                            .matchedGeometryEffect(id: "selection", in: namespace)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .help(option.minutes == nil ? "Sin límite, hasta que lo apagues" : "Despierto durante \(option.id)")
            .accessibilityLabel(option.minutes == nil ? "Sin límite" : option.id)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}

struct ReturnButton: View {
    @EnvironmentObject var model: Despierto

    var body: some View {
        Button { model.stop() } label: {
            Label("Volver a lo normal", systemImage: "cup.and.saucer")
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.2))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}

struct AgentsRow: View {
    @EnvironmentObject var model: Despierto
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: model.isAwake ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(model.isAwake ? Semantic.ok(scheme) : Semantic.warn(scheme))
                .symbolSwap()
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.openAgents.count == 1
                     ? "\(model.openAgentsLabel) está abierto"
                     : "\(model.openAgentsLabel) están abiertos")
                    .font(.system(size: 13, weight: .semibold))
                    .textMorph()
                // Con Despierto activo el encabezado ya dice lo de la tapa; solo avisamos si aún no.
                if !model.isAwake {
                    Text("Si cierras la tapa ahora, se pararán")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textMorph()
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Apagar o seguir desde el móvil: un solo bloque, un solo QR.
enum MobilePane: String, CaseIterable, Identifiable {
    case stop, follow
    var id: String { rawValue }
    var title: String {
        switch self {
        case .stop: return "Apagar"
        case .follow: return "Seguir"
        }
    }
}

struct MobileSection: View {
    @EnvironmentObject var model: Despierto

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isAwake {
                HStack(spacing: 10) {
                    Text("Desde el móvil")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                    MobilePanePicker()
                        .frame(width: 148)
                }
                Group {
                    if model.mobilePane == .stop {
                        RemoteStopContent()
                    } else {
                        PhoneContent(showTitle: false)
                    }
                }
                .id(model.mobilePane)
                .transition(.opacity)
            } else {
                PhoneContent(showTitle: true)
            }
        }
        .animation(Motion.curve(Motion.standard), value: model.mobilePane)
        .animation(Motion.curve(Motion.standard), value: model.isAwake)
    }
}

struct MobilePanePicker: View {
    @EnvironmentObject var model: Despierto
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MobilePane.allCases) { option in
                let selected = model.mobilePane == option
                Button {
                    withAnimation(Motion.slide) { model.mobilePane = option }
                } label: {
                    Text(option.title)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.primary.opacity(0.12))
                                    .matchedGeometryEffect(id: "mobile-pane", in: selection)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}

/// Enlace/QR para apagar después con el Mac cerrado (misma Wi‑Fi).
struct RemoteStopContent: View {
    @EnvironmentObject var model: Despierto

    private var phoneLink: String? { model.remoteControlURL ?? model.remoteStopURL }

    private var subtitle: String {
        if phoneLink == nil {
            return "Conectá el Mac a la misma Wi‑Fi que el celular."
        }
        return "Misma Wi‑Fi. Escaneá o copiá antes de cerrar."
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textMorph()
                if phoneLink != nil {
                    // verbatim: evita que el locale pinte 8787 como «8.787»
                    Text(verbatim: RemoteStopServer.hostPort)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                    HStack(spacing: 6) {
                        Button { model.copyRemoteStopLink() } label: {
                            Label("Copiar", systemImage: "doc.on.doc")
                                .font(.system(size: 11, weight: .semibold))
                                .labelStyle(.titleAndIcon)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.primary.opacity(0.09)))
                        }
                        .buttonStyle(PressStyle())
                        .help("Copiá el enlace para pegarlo en Safari del iPhone")

                        Button { model.shareRemoteStopLink() } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 26, height: 22)
                                .background(Capsule().fill(Color.primary.opacity(0.09)))
                        }
                        .buttonStyle(PressStyle())
                        .help("Mandá el enlace al iPhone por AirDrop o Mensajes")
                        .accessibilityLabel("Compartir")
                    }
                }
            }
            Spacer(minLength: 0)
            if let url = phoneLink, let qr = QR.image(for: url) {
                QRBadge(image: qr, help: url, accessibilityLabel: "Código QR: abrí esta página en el móvil antes de cerrar la tapa")
            }
        }
    }
}

struct PhoneContent: View {
    @EnvironmentObject var model: Despierto
    var showTitle: Bool = true

    private var target: PhoneTarget { model.phoneTarget }

    private var qrURL: String {
        if target == .claude, let session = model.selectedSession { return session.url }
        return target.portalURL
    }

    private var showClaudeSessionPicker: Bool {
        target == .claude && model.selectedSession != nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    if showTitle {
                        Text("Sigue en el móvil")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textMorph()
                }
                PhoneTargetPicker()
                if showClaudeSessionPicker, let session = model.selectedSession {
                    SessionPicker(selected: session)
                }
                copyCommandButton
            }
            Spacer(minLength: 0)
            if let qr = QR.image(for: qrURL) {
                QRBadge(image: qr, help: qrURL, accessibilityLabel: accessibilityQR)
                    .id(qrURL)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(Motion.curve(Motion.standard), value: model.selectedSession?.id)
        .animation(Motion.curve(Motion.standard), value: model.phoneTarget)
    }

    private var accessibilityQR: String {
        switch target {
        case .claude:
            if let session = model.selectedSession {
                return "Código QR para abrir «\(session.name)» en Claude"
            }
            return "Código QR para abrir Claude Code en el móvil"
        case .cursor: return "Código QR para abrir los agentes de Cursor en el móvil"
        case .codex: return "Código QR para abrir Codex en ChatGPT"
        }
    }

    private var description: String {
        switch target {
        case .claude:
            if model.selectedSession != nil {
                return "Escaneá el QR o activá Remote Control:"
            }
            return model.openSessionCount > 0
                ? "Conectá el chat con Remote Control:"
                : "Abrí Claude Code con Remote Control:"
        case .cursor:
            return "App Cursor en el iPhone, o /remote-control:"
        case .codex:
            return "App ChatGPT → Codex, o el comando:"
        }
    }

    private var copyCommandButton: some View {
        Button {
            model.copyRemoteControlCommand()
        } label: {
            HStack(spacing: 5) {
                Text(target.copyCommand)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(0.09)))
        }
        .buttonStyle(PressStyle())
        .help(target.copyHelp)
    }
}

struct QRBadge: View {
    let image: CGImage
    let help: String
    let accessibilityLabel: String

    var body: some View {
        Image(decorative: image, scale: 1)
            .interpolation(.none)
            .resizable()
            .frame(width: 58, height: 58)
            .padding(5)
            .background(.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .help(help)
            .accessibilityLabel(accessibilityLabel)
    }
}

/// Claude / Cursor / Codex: el QR e instrucciones cambian con el destino.
struct PhoneTargetPicker: View {
    @EnvironmentObject var model: Despierto
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PhoneTarget.allCases) { target in
                let selected = model.phoneTarget == target
                Button {
                    withAnimation(Motion.slide) { model.phoneTarget = target }
                } label: {
                    Text(target.title)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.primary.opacity(0.12))
                                    .matchedGeometryEffect(id: "phone-target", in: selection)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}

/// Muestra el chat del QR. Si hay varios conectados, al pulsarlo eliges otro.
struct SessionPicker: View {
    @EnvironmentObject var model: Despierto
    let selected: ClaudeSession

    private var chip: some View {
        HStack(spacing: 5) {
            Text(selected.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .textMorph()
            if model.phoneSessions.count > 1 {
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold))
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.09)))
        .contentShape(Capsule())
    }

    var body: some View {
        let several = model.phoneSessions.count > 1
        Group {
            if several {
                // Menu de SwiftUI se ancla al chip (no a NSEvent.mouseLocation global).
                Menu {
                    ForEach(model.phoneSessions) { session in
                        Button {
                            model.selectedSessionID = session.id
                        } label: {
                            if session.id == selected.id {
                                Label(session.busy ? "\(session.name) · trabajando" : session.name,
                                      systemImage: "checkmark")
                            } else {
                                Text(session.busy ? "\(session.name) · trabajando" : session.name)
                            }
                        }
                    }
                } label: {
                    chip
                }
                .menuStyle(.borderlessButton)
                .buttonStyle(PressStyle())
            } else {
                chip.help(selected.name)
            }
        }
        .help(several ? "Elegir otro chat" : selected.name)
    }
}

struct Footer: View {
    @EnvironmentObject var model: Despierto
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 10) {
            if let battery = model.battery {
                let low = model.isAwake && !battery.charging && battery.percent <= 20
                HStack(spacing: 5) {
                    Image(systemName: Format.batterySymbol(battery))
                    Text(low ? "\(battery.percent) % · enchúfalo" : "\(battery.percent) %")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(low ? AnyShapeStyle(Semantic.warn(scheme)) : AnyShapeStyle(.secondary))
            }
            Spacer()
            Button { withAnimation(Motion.curve(Motion.quick)) { model.toggleLaunchAtLogin() } } label: {
                HStack(spacing: 4) {
                    Image(systemName: model.launchAtLogin ? "checkmark.circle.fill" : "circle")
                        .symbolSwap()
                    Text("Abrir al iniciar")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(model.launchAtLogin ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(PressStyle())
            .help("Salir de Despierto")
        }
    }
}

// MARK: - Piezas de diseño

/// Escala «ceniza»: grises cálidos del carbón a la ceniza clara.
enum Ash {
    static let c950 = Color(hex: 0x141413)
    static let c900 = Color(hex: 0x1C1B1A)
    static let c800 = Color(hex: 0x2A2927)
    static let c600 = Color(hex: 0x4A4845)
    static let c200 = Color(hex: 0xD9D6D1)
    static let c100 = Color(hex: 0xECEAE6)
    static let ns950 = NSColor(srgbRed: 0x14 / 255, green: 0x14 / 255, blue: 0x13 / 255, alpha: 1)
    static let ns900 = NSColor(srgbRed: 0x1C / 255, green: 0x1B / 255, blue: 0x1A / 255, alpha: 1)
}

/// Colores con significado: solo para «todo bien» y «ojo».
enum Semantic {
    static func ok(_ scheme: ColorScheme) -> Color { scheme == .dark ? Color(hex: 0x6EE7A0) : Color(hex: 0x15803D) }
    static func warn(_ scheme: ColorScheme) -> Color { scheme == .dark ? Color(hex: 0xFBBF57) : Color(hex: 0xB45309) }
}

struct Hairline: View {
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(configuration.isPressed ? Motion.curve(0.1) : Motion.settleLight, value: configuration.isPressed)
    }
}

/// Lenguaje de movimiento: una curva firma que arranca rápido y aterriza suave,
/// y tres duraciones. El vapor es «gas»: más lento y sin rebotes.
enum Motion {
    static let quick = 0.15
    static let standard = 0.25
    static let slow = 0.45

    static func curve(_ duration: Double) -> Animation { .timingCurve(0.2, 0, 0, 1, duration: duration) }
    static func accelerateCurve(_ duration: Double) -> Animation { .timingCurve(0.3, 0, 1, 1, duration: duration) }
    static let settle = Animation.spring(response: 0.42, dampingFraction: 0.62)     // la taza se asienta al llenarse
    static let settleLight = Animation.spring(response: 0.25, dampingFraction: 0.8) // soltar un botón
    static let slide = Animation.spring(response: 0.32, dampingFraction: 0.86)      // la selección se desliza

    static let decelerate = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
    static let accelerate = CAMediaTimingFunction(controlPoints: 0.3, 0, 1, 1)

    static func easeOutCubic(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
}

extension View {
    /// Cambio de icono con el efecto «replace» de SF Symbols (macOS 14+).
    @ViewBuilder
    func symbolSwap() -> some View {
        if #available(macOS 14.0, *) {
            contentTransition(.symbolEffect(.replace.downUp))
        } else {
            self
        }
    }

    /// Un texto se transforma en otro en vez de saltar.
    func textMorph() -> some View {
        contentTransition(.interpolate)
    }

    @ViewBuilder
    func countdownTransition() -> some View {
        if #available(macOS 14.0, *) {
            contentTransition(.numericText(countsDown: true))
        } else {
            self
        }
    }
}

enum Format {
    /// «A», «A y B», «A, B y C».
    static func joinedList(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) y \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + " y " + (items.last ?? "")
        }
    }

    /// `fixedWidth`: rellena con un espacio del ancho de una cifra (9:59 → « 9:59»),
    /// para que el icono de la barra no cambie de ancho al pasar de 10:00 a 9:59.
    static func countdown(_ seconds: TimeInterval, fixedWidth: Bool = false) -> String {
        let s = Int(seconds.rounded(.up))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        let text = String(format: "%d:%02d", m, sec)
        return fixedWidth && m < 10 ? "\u{2007}" + text : text
    }

    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    static func duration(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) minutos" : (minutes == 60 ? "1 hora" : "\(minutes / 60) horas")
    }

    static func batterySymbol(_ battery: Battery) -> String {
        if battery.charging { return "battery.100percent.bolt" }
        let level = [100, 75, 50, 25].first { battery.percent >= $0 - 12 } ?? 0
        return "battery.\(level)percent"
    }
}

@MainActor
enum QR {
    private static var cache: [String: CGImage] = [:]
    private static let context = CIContext()

    /// Código QR para un enlace (se guarda para no recalcularlo cada segundo).
    static func image(for url: String) -> CGImage? {
        if let cached = cache[url] { return cached }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let image = context.createCGImage(output, from: output.extent) else { return nil }
        cache[url] = image
        return image
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - Capturas para el README

/// Dibuja el panel sobre un fondo de escritorio, imitando el cristal
/// (ImageRenderer no puede dibujar el cristal real del sistema).
enum Snapshot {
    @MainActor
    static func render(to path: String, args: [String]) {
        _ = NSApplication.shared
        let state = args.firstIndex(of: "--state").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "timer"
        let systemDark = args.contains("--dark")

        let model = Despierto(preview: true)
        model.battery = Battery(percent: 52, charging: false)
        model.openAgents = [.claude, .cursor, .codex]
        model.phoneTarget = .claude
        model.openSessionCount = 3
        model.needsSetup = args.contains("--needs-setup")
        // `--low-battery`: el aviso de cuando vuelve solo a lo normal por batería baja
        if args.contains("--low-battery") {
            model.battery = Battery(percent: Despierto.lowBatteryLimit, charging: false)
            model.notice = Despierto.lowBatteryNotice(percent: Despierto.lowBatteryLimit,
                                                      at: Calendar.current.date(bySettingHour: 18, minute: 42, second: 0, of: Date()) ?? Date())
        }
        // `--brew-t 0.3`: dibuja el vapor como se ve 0,3 s después de activarlo
        let brewT = args.firstIndex(of: "--brew-t").flatMap { args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil } ?? 1.3
        model.brewedAt = model.now.addingTimeInterval(-brewT)
        if !args.contains("--no-phone") {
            // Chats de ejemplo (el enlace es inventado)
            model.phoneSessions = [
                ClaudeSession(id: "session_ejemplo1", name: "Mantener el Mac despierto", busy: true, updatedAt: 2),
                ClaudeSession(id: "session_ejemplo2", name: "Girl Dinner Generator app", busy: false, updatedAt: 1),
            ]
        }
        switch state {
        case "normal":
            model.isAwake = false
            model.mobilePane = .follow
        case "awake":
            model.isAwake = true
            model.mobilePane = .stop
            model.remoteControlURL = "http://\(RemoteStopServer.localHost):\(RemoteStopServer.portText)/"
        default:
            // `--remaining 1800 --total 1800`: cuánto queda y cuánto duraba (para el GIF)
            func number(_ flag: String) -> Double? {
                args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil }
            }
            let remaining = number("--remaining") ?? (18 * 60 + 24)
            let total = number("--total") ?? (30 * 60)
            model.isAwake = true
            model.mobilePane = .stop
            model.remoteControlURL = "http://\(RemoteStopServer.localHost):\(RemoteStopServer.portText)/"
            model.startDate = model.now.addingTimeInterval(remaining - total)
            model.endDate = model.now.addingTimeInterval(remaining)
        }

        let shape = RoundedRectangle(cornerRadius: Glass.radius, style: .continuous)
        let panel = PanelRoot().environmentObject(model).fixedSize()
        let canvasHeight = args.firstIndex(of: "--canvas-height")
            .flatMap { args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil }

        let view: AnyView
        if let canvasHeight {
            // Lienzo fijo (para el GIF): el panel cuelga de arriba y crece hacia abajo
            view = AnyView(ZStack(alignment: .top) {
                Backdrop()
                panel.hidden().background(shape.fill(Color.black.opacity(0.35)))
                    .blur(radius: 16).offset(y: 10).padding(28)                               // sombra
                Backdrop().blur(radius: 14).mask(alignment: .top) {
                    panel.hidden().background(shape.fill(Color.black)).padding(28)           // cristal
                }
                panel.padding(28)
            }
            .frame(width: 376, height: canvasHeight)
            .environment(\.colorScheme, systemDark ? .dark : .light))
        } else {
            view = AnyView(panel
                .padding(28)
                .background {
                    ZStack {
                        Backdrop()
                        shape.fill(Color.black.opacity(0.35)).padding(28).blur(radius: 16).offset(y: 10) // sombra
                        Backdrop().blur(radius: 14).mask(shape.padding(28))                             // cristal
                    }
                }
                .environment(\.colorScheme, systemDark ? .dark : .light))
        }

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            print("No se pudo dibujar el panel"); exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("📸 \(path)")
        } catch {
            print("No se pudo guardar: \(error.localizedDescription)"); exit(1)
        }
    }

    /// Fondo de escritorio abstracto para que se note la transparencia.
    private struct Backdrop: View {
        var body: some View {
            ZStack {
                LinearGradient(colors: [Color(hex: 0x8FA3B8), Color(hex: 0xC9B8A6), Color(hex: 0x6F7F8F)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(Color(hex: 0xE9C9A6)).frame(width: 260).offset(x: -110, y: -170).blur(radius: 30)
                Circle().fill(Color(hex: 0x51677D)).frame(width: 300).offset(x: 140, y: 160).blur(radius: 40)
                RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0x1F2329))
                    .frame(width: 230, height: 300).offset(x: 150, y: -40)
            }
            .clipped()
        }
    }
}
