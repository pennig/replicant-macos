// ============================================================================
// PROTOTYPE v2 — automation-brain ticket 05: primitive contracts (print/deliver/shuttle)
// THROWAWAY. Run:  swift .scratch/automation-brain/research/05-primitives-prototype.swift
// ============================================================================
//
// QUESTION (ticket 05): contracts of print / deliver / shuttle, and how they compose?
//
// v2 corrects v1 (operator feedback): print & deliver are INDEPENDENT primitives; v1
// fused them and skipped stow. Corrections now baked in:
//   • `print` is standalone — enqueue_print(device_type) at a printer that already sits
//     at a stocked location; its output AUTO-DEPLOYS, idle, at that location (research 07).
//     Usable with NO delivery (batch relays at a hub; a device for a location event).
//   • `deliver` picks up an already-deployed idle device and moves it. It must STOW/ATTACH
//     first (v1's missing step), then travel, then re-deploy at the destination.
//   • Boring waypoint gaps have NO stockpile -> you cannot print there. Relays are printed
//     at a stocked HUB and delivered out. print-location != deliver-destination, always.
//   • TRANSPORT is a don't-strand choice [02#7], not a hull preference:
//       - surge plate delivers ANYTHING (esp. non-stowable), but ONLY to an already-meshed
//         system — otherwise the device is STRANDED on arrival;
//       - an FTL relay goes to an UNMESHED system by definition, so it MUST ride stowed in
//         the replicant vessel, whose presence authorises deploy + activate IN-SITU.
//   • ACTIVATION lives INSIDE deliver (operator call): deliver-of-a-relay ends deployed +
//     activated + confirmed-meshed. Pre-activating then moving does NOT mesh (live-tested).
//     SalvageRun's emplace/activate/confirm is the proven shape; new work = self-SUPPLY
//     the relay (print at hub) instead of the operator staging it.
//
// GROUNDING (verbatim shapes, this session):
//   MissionStepMachine / MissionAction .. Modules/DirectiveEngine/Sources/MissionStepMachine.swift:22,252
//   Directive* .. Modules/GameModels/Sources/Directive.swift:20,39,62,184
//   OperationKind (.print,.travel,.simple) .. Modules/GameModels/Sources/Operation.swift:112,120
//   print = enqueue_print(device_type) ONLY .. Modules/GameServices/Sources/CommandClient+Printing.swift:13
//   SalvageRun emplace/activate/confirm/settle .. Modules/DirectiveEngine/Sources/SalvageRun.swift:579,620,658,715
//   Haul Run = tag-driven ferry repoint (SHIPPED) .. app/.claude/memory/haul-run-design.md
//   robustness clauses [02#N]; seam facts [04].

import Foundation

// ============================================================================
// PART 0 — throwaway mirrors of the real engine types (shapes match source)
// ============================================================================

struct OperationKind: Equatable { let raw: String
    static let travel = OperationKind(raw: "travel")
    static let print  = OperationKind(raw: "print")
    static func simple(_ s: String) -> OperationKind { OperationKind(raw: s) }
}
struct CommandParams: Equatable {
    var destination: String? = nil
    var deviceType: String? = nil          // the ONLY field enqueue_print carries
    var target: String? = nil              // for stow/attach: the carrier to load onto
}
enum MissionAction: Equatable {
    case dispatch(kind: OperationKind, deviceCode: String, params: CommandParams, nextStep: String)
    case wait
    case advanceStep(nextStep: String)
    case refreshDevices(deviceCodes: [String], thenStall: AttentionReason?)
    case setDeviceTags(deviceCode: String, tags: [String], nextStep: String)
    case stall(AttentionReason)
    case done
}
enum AttentionReason: String {
    case unreachableDevice, relayActivationFailed, commandRejected, vesselPositionUnconfirmed
    case awaitingRelayRestock                 // the shipped Salvage-Run stall this flow SUPERSEDES
    case printStockShort                      // •NEW print: location stockpile < blueprint bill
    case noPrinterAtSite                      // •NEW print: no print-capable device at the location
    case deliveryWouldStrand                  // •NEW deliver: surge to an UNMESHED target [02#7]
    case needsFulfilmentChoice                // •NEW event composer's HITL decision-request [04 §3]
    enum Disposition: String { case retry, escalate, decisionRequest }
    var brainDisposition: Disposition {
        switch self {
        case .unreachableDevice, .relayActivationFailed, .commandRejected,
             .vesselPositionUnconfirmed, .printStockShort:              return .retry
        case .awaitingRelayRestock, .noPrinterAtSite, .deliveryWouldStrand: return .escalate
        case .needsFulfilmentChoice:                                    return .decisionRequest
        }
    }
}
enum DirectiveStatus: String { case running, needsAttention, paused, completed, cancelled }

enum Transport: String { case stowAboard, surge }   // deliver's two modes

/// The prototype row. D5 (two-device ownership) RESOLVES to: the printer is NEVER held (a
/// shared autofactory queue), so the directive's `deviceCode` = the carrier is the ONLY
/// lease; the printed relay is held THROUGH the carrier once stowed (04's existing rule).
/// No fleet, no committed-devices column. `printerCode` below is just a dispatch target.
struct Row {
    var kind: String                         // "relayRun" — tendMesh's executor
    var status: DirectiveStatus = .running
    var carrierCode: String                 // the directive's deviceCode — the ONLY device held
    var printerCode: String                 // a dispatch target for enqueue_print; NOT owned
    var step: String
    var attentionReason: AttentionReason? = nil
    var mode: Transport = .stowAboard        // relay path forces stowAboard
    var target: String                       // the gap system we're planting a relay into
}

struct World {
    // hub (print) side
    var printerPresentAtHub = true
    var hubStockUnits = 0
    var relayBillUnits = 370                  // ftl_relay six-type bill (research 07), coarsened
    var printedRelayCode: String? = nil       // print_complete -> new_device_code, auto-deployed idle @hub
    // deliver side
    var relayStowed = false
    var carrierAtGap = false
    var relayDeployed = false
    var relayRelaying = false                 // server statusBase == "relaying"
    var targetIsMeshed = false                // is the GAP already FTL-networked? (false = why we plant a relay)
    var targetInControlRange = false          // authoritative reachability bit [02#4], true AFTER activate
}

// ============================================================================
// PART 1 — the three primitives, as independent step-libraries
// ============================================================================

/// PRIMITIVE `print` — standalone. Product: a deployed-idle device @ the printer's location.
enum PrintLib {
    enum S { static let checkStock = "print.checkStock"; static let enqueue = "print.enqueue"; static let awaitPrint = "print.awaitPrint" }
    static let firstStep = S.checkStock
    static let complete  = "print.__complete__"          // composer hands off from here
    static func next(step: String, printer: String, deviceType: String, w: World) -> MissionAction {
        switch step {
        case S.checkStock:
            guard w.printerPresentAtHub else { return .stall(.noPrinterAtSite) }          // •escalate
            guard w.hubStockUnits >= w.relayBillUnits else { return .stall(.printStockShort) } // •retry (self-supply refills)
            return .advanceStep(nextStep: S.enqueue)
        case S.enqueue:
            return .dispatch(kind: .print, deviceCode: printer,
                             params: CommandParams(deviceType: deviceType), nextStep: S.awaitPrint)
        case S.awaitPrint:
            return w.printedRelayCode == nil ? .wait : .advanceStep(nextStep: complete)   // enqueued -> poll
        default: return .wait
        }
    }
}

/// PRIMITIVE `deliver` — standalone. Move a deployed-idle device A -> B. Two modes gated by
/// don't-strand. Relay path: stowAboard + in-situ activate (activation is deliver's TAIL).
enum DeliverLib {
    enum S {
        static let selectMode = "deliver.selectMode"; static let stow = "deliver.stow"
        static let travel = "deliver.travel"; static let deploy = "deliver.deploy"
        static let activate = "deliver.activate"; static let confirm = "deliver.confirm"; static let detach = "deliver.detach"
    }
    static let firstStep = S.selectMode
    static let complete  = "deliver.__complete__"
    /// `isRelay` gates the activate tail; non-relay deliveries skip activate+confirm.
    static func next(step: String, device: String, carrier: String, target: String,
                     mode: Transport, isRelay: Bool, w: World) -> MissionAction {
        switch step {
        case S.selectMode:
            // DON'T-STRAND [02#7]: surge only reaches an already-meshed target.
            if mode == .surge && !w.targetIsMeshed { return .stall(.deliveryWouldStrand) } // •escalate
            return .advanceStep(nextStep: S.stow)
        case S.stow:
            // stowAboard: load into the vessel's cradle; surge: attach to a surge_plate.
            guard w.relayStowed else {
                let verb = mode == .stowAboard ? "stow" : "attach"
                return .dispatch(kind: .simple(verb), deviceCode: device,
                                 params: CommandParams(target: carrier), nextStep: S.stow)
            }
            return .advanceStep(nextStep: S.travel)
        case S.travel:
            guard w.carrierAtGap else {
                return .dispatch(kind: .travel, deviceCode: carrier,
                                 params: CommandParams(destination: target + "-L4"), nextStep: S.travel)
            }
            return .advanceStep(nextStep: S.deploy)
        case S.deploy:
            // in-situ, vessel present. stowAboard: deploy; surge: detach.
            guard w.relayDeployed else {
                let verb = mode == .stowAboard ? "deploy" : "detach"
                return .dispatch(kind: .simple(verb), deviceCode: device, params: CommandParams(),
                                 nextStep: S.deploy)
            }
            return .advanceStep(nextStep: isRelay ? S.activate : complete)
        case S.activate:
            return .dispatch(kind: .simple("activate"), deviceCode: device, params: CommandParams(),
                             nextStep: S.confirm)                              // vessel present == authority
        case S.confirm:
            if w.relayRelaying && w.targetInControlRange { return .advanceStep(nextStep: S.detach) }
            return .refreshDevices(deviceCodes: [device], thenStall: nil)      // + activationDeadline -> .relayActivationFailed
        case S.detach:
            return .setDeviceTags(deviceCode: device, tags: [], nextStep: complete) // permanent infra
        default: return .wait
        }
    }
}

/// PRIMITIVE `shuttle` — cargo, multi-source -> a hub. STUB: D4 (collapse into shipped Haul
/// Run vs distinct kind) + the multi-source shape (owned by ticket 06) are unresolved, so
/// this is not exercised. In the composition below, "stock arrives at the hub" is a
/// PRECONDITION met upstream by shuttle/Haul Run.

// ============================================================================
// PART 2 — worked composition: `RelayRestockRun` (closes `awaitingRelayRestock`)
// ============================================================================
//
// tendMesh GROW branch, home = existing DirectiveKind.relayRun. Composes print THEN deliver
// (each independent above) across a hub, as ONE carrier-owned directive. The autofactory is a
// shared queue (a dispatch target, not a lease); the ONLY device held is the carrier
// (deviceCode) + the relay once stowed aboard [04]. Reports up ONLY via row status+reason [04 §3].

enum RelayRestockRun {
    static func nextAction(_ r: Row, _ w: World) -> MissionAction {
        // phase hand-offs (the composer's only sequencing job):
        if r.step == PrintLib.complete   { return .advanceStep(nextStep: DeliverLib.firstStep) }
        if r.step == DeliverLib.complete { return .done }
        if r.step.hasPrefix("print.") {
            return PrintLib.next(step: r.step, printer: r.printerCode, deviceType: "ftl_relay", w: w)
        }
        if r.step.hasPrefix("deliver.") {
            let relay = w.printedRelayCode ?? "RLY-PENDING"
            return DeliverLib.next(step: r.step, device: relay, carrier: r.carrierCode,
                                   target: r.target, mode: r.mode, isRelay: true, w: w)
        }
        return .done
    }
    static let firstStep = PrintLib.firstStep
}

// ============================================================================
// PART 3 — interactive driver (thin throwaway TUI over the pure machines above)
// ============================================================================

func esc(_ s: String) -> String { "\u{1B}[\(s)" }
func render(_ r: Row, _ w: World, _ last: MissionAction?) {
    print(esc("2J") + esc("H"), terminator: "")
    print(esc("1m") + "RelayRestockRun — print(@hub) ▸ deliver(stow-aboard ▸ emplace @gap)" + esc("0m"))
    print(esc("2m") + "(self-supplies a relay instead of stalling awaitingRelayRestock)" + esc("0m") + "\n")
    let phase = r.step.hasPrefix("print.") ? "PRINT" : (r.step.hasPrefix("deliver.") ? "DELIVER" : "—")
    print(esc("1m") + "ROW" + esc("0m") + "   phase " + esc("36m") + phase + esc("0m"))
    print("  step             " + esc("1m") + r.step + esc("0m"))
    print("  status           " + statusColour(r.status))
    if let a = r.attentionReason {
        print("  attentionReason  " + esc("33m") + a.rawValue + esc("0m") + esc("2m") + "  -> brain: \(a.brainDisposition.rawValue)" + esc("0m"))
    } else { print("  attentionReason  " + esc("2m") + "none" + esc("0m")) }
    print("  mode             \(r.mode.rawValue)    deviceCode \(r.carrierCode)  " + esc("2m") + "(the ONLY lease; printer not held)" + esc("0m"))
    print("\n" + esc("1m") + "WORLD" + esc("0m"))
    print("  [hub]  printer \(w.printerPresentAtHub)   stock \(w.hubStockUnits)/\(w.relayBillUnits)   printedRelay \(w.printedRelayCode ?? "-")")
    print("  [move] stowed \(w.relayStowed)   atGap \(w.carrierAtGap)")
    print("  [gap]  targetMeshed \(w.targetIsMeshed)   deployed \(w.relayDeployed)   relaying \(w.relayRelaying)   in_control_range \(w.targetInControlRange)")
    if let a = last { print("\n" + esc("2m") + "last action: \(a)" + esc("0m")) }
    print("\n" + esc("1m") + "KEYS" + esc("0m") + esc("2m") + "  [n]tick  [S]fill-stock  [p]print_complete  [c]relaying+range" + esc("0m"))
    print(esc("2m") + "     [!]yank-printer  [m]toggle-mode(stow/surge)  [g]toggle-target-meshed  [?]decisions  [q]quit" + esc("0m"))
}
func statusColour(_ s: DirectiveStatus) -> String {
    switch s {
    case .running: return esc("32m") + "running" + esc("0m")
    case .needsAttention: return esc("31m") + "needsAttention" + esc("0m")
    case .completed: return esc("36m") + "completed" + esc("0m")
    default: return s.rawValue
    }
}
/// Apply one tick: evaluate, advance the step, and fake the OBVIOUS local effects of a
/// dispatch (stow took, arrival, deploy took). The two async/server-confirmed facts —
/// print_complete and relaying — stay MANUAL ([p]/[c]), because those are the real waits.
func tick(_ r: inout Row, _ w: inout World) -> MissionAction {
    let a = RelayRestockRun.nextAction(r, w)
    switch a {
    case let .advanceStep(next): r.step = next; r.status = .running; r.attentionReason = nil
    case let .dispatch(kind, _, _, next):
        r.step = next; r.status = .running; r.attentionReason = nil
        switch kind.raw {                       // fake local effects
        case "stow", "attach": w.relayStowed = true
        case "travel":         w.carrierAtGap = true
        case "deploy", "detach": w.relayDeployed = true
        default: break
        }
    case let .refreshDevices(_, stall): if let s = stall { r.status = .needsAttention; r.attentionReason = s }
    case let .setDeviceTags(_, _, next): r.step = next
    case let .stall(reason): r.status = .needsAttention; r.attentionReason = reason
    case .done: r.status = .completed
    case .wait: break
    }
    return a
}

let DECISIONS = """
\u{1B}[1mDECISIONS — ticket 05\u{1B}[0m

 D1  Primitives are independent STEP-LIBRARIES spliced into ONE composing MissionStepMachine
     (no lighter tier exists; SalvageRun already inlines deliver+mine). CALLED.
 D2  print: standalone; enqueue_print(device_type) at a printer already at a stocked location;
     output auto-deploys idle THERE. short-stock -> .printStockShort (retry/idle, self-supply
     refills); no printer -> .noPrinterAtSite (escalate). CALLED.
 D3  deliver: standalone; STOW/attach -> travel -> deploy in-situ; activation is deliver's
     TAIL for a relay (operator call) -> deploy+activate+confirm-meshed, vessel present.
     Confirm keys off authoritative in_control_range, never a recomputed mesh [02#4]. CALLED.
 D3b TRANSPORT = don't-strand gate [02#7] (operator call): surge delivers anything incl.
     non-stowable, but ONLY to an already-MESHED target (else .deliveryWouldStrand escalate);
     a relay -> unmeshed target by definition -> MUST stow aboard the vessel. CALLED.
 D5  two-device ownership: RESOLVED — the printer is a shared autofactory queue, never held,
     so the carrier (deviceCode) is the ONLY lease + the relay held via stow. 04's "add a
     committed-devices field?" -> NO. (A print-VESSEL collapses printer==carrier to one code.)
 D4  \u{1B}[33mOPEN\u{1B}[0m — does `shuttle` collapse into the SHIPPED Haul Run (add hub +
     source set) or ship distinct? Multi-source shape owned by 06. Not exercised here.
 D6  report-up: only via row status+attentionReason [04 §3]; new reasons map onto 04's
     retry/escalate/decisionRequest classifier. CALLED.
"""

var row = Row(kind: "relayRun", carrierCode: "VESL-CARRIER-1", printerCode: "AUTOFAC-HUB-1",
              step: RelayRestockRun.firstStep, target: "SOHIMU")
var world = World()
var last: MissionAction? = nil
render(row, world, last)
while let line = readLine() {
    switch line.trimmingCharacters(in: .whitespaces) {
    case "n": last = tick(&row, &world)
    case "S": world.hubStockUnits = world.relayBillUnits
    case "p": world.printedRelayCode = "RLY-FRESH-9"
    case "c": world.relayRelaying = true; world.targetInControlRange = true
    case "!": world.printerPresentAtHub = false
    case "m": row.mode = (row.mode == .stowAboard) ? .surge : .stowAboard
    case "g": world.targetIsMeshed.toggle()
    case "?": print(esc("2J") + esc("H"), terminator: ""); print(DECISIONS); print("\n" + esc("2m") + "[enter] back" + esc("0m")); _ = readLine()
    case "q": print("bye"); exit(0)
    default: break
    }
    render(row, world, last)
}
