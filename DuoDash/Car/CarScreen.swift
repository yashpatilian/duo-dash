import SwiftUI

/// The Car app: live gauges for whatever the car supports, battery voltage, trouble
/// codes and the adapter. Wide windows put diagnostics in a column beside the gauges;
/// narrow ones stack everything. Decided from the window size alone.
struct CarScreen: View {
    @Environment(CarDataModel.self) private var car
    @State private var confirmingClear = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let wide = width >= 820
            let sideWidth = min(440, max(320, width * 0.38))
            ScrollView {
                if wide {
                    HStack(alignment: .top, spacing: Theme.gap) {
                        VStack(spacing: Theme.gap) {
                            CarStatusCard()
                            gauges(width: width - sideWidth - Theme.gap)
                        }
                        VStack(spacing: Theme.gap) {
                            diagnostics
                            CarAdapterSection()
                        }
                        .frame(width: sideWidth)
                    }
                } else {
                    VStack(spacing: Theme.gap) {
                        CarStatusCard()
                        gauges(width: width)
                        diagnostics
                        CarAdapterSection()
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .background(DashBackground())
        .onAppear { car.start() }
        .alert("Clear trouble codes?", isPresented: $confirmingClear) {
            Button("Clear codes", role: .destructive) { Task { await car.clearCodes() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This turns off the check-engine light and erases the car's fault records and readiness monitors, so it may fail an emissions check until it has been driven for a while. If the fault is still there, the code comes back. Best done with the engine off and the ignition on.")
        }
    }

    // MARK: Gauges

    @ViewBuilder
    private func gauges(width: CGFloat) -> some View {
        if car.state.hasAdapter {
            let columns = max(1, min(4, Int(width / 190)))
            let tileHeight: CGFloat = width < 420 ? 118 : 138
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.gap), count: columns),
                      spacing: Theme.gap) {
                ForEach(car.visiblePIDs) { pid in
                    CarGaugeTile(title: pid.title, symbol: pid.symbol,
                                 value: car.value(pid).map(pid.format), unit: pid.unit,
                                 tint: Self.tint(for: pid, value: car.value(pid)),
                                 fraction: pid == .rpm ? car.value(pid).map { min(1, $0 / 9000) } : nil)
                        .frame(height: tileHeight)
                        .accessibilityIdentifier("car.tile.\(pid.title)")
                }
                CarGaugeTile(title: "Battery", symbol: "minus.plus.batteryblock",
                             value: car.batteryVoltage.map { String(format: "%.1f", $0) }, unit: "V",
                             tint: Self.batteryTint(car.batteryVoltage), fraction: nil)
                    .frame(height: tileHeight)
                    .accessibilityIdentifier("car.tile.battery")
            }
        }
    }

    static func tint(for pid: OBDPID, value: Double?) -> Color {
        guard let value else { return Theme.textPrimary }
        switch pid {
        case .coolantTemp: return value >= 105 ? Theme.danger : value < 60 ? Theme.accent : Theme.textPrimary
        case .oilTemp: return value >= 130 ? Theme.danger : Theme.textPrimary
        case .rpm: return value >= 7800 ? Theme.danger : Theme.textPrimary
        case .fuelLevel: return value < 12 ? Theme.warning : Theme.textPrimary
        default: return Theme.textPrimary
        }
    }

    /// Below about 12.2 V with the engine off the battery is getting flat; over 15 V
    /// with it running the alternator is overcharging.
    static func batteryTint(_ volts: Double?) -> Color {
        guard let volts else { return Theme.textPrimary }
        if volts < 11.8 || volts > 15.0 { return Theme.danger }
        if volts < 12.2 { return Theme.warning }
        return Theme.positive
    }

    // MARK: Diagnostics

    private var diagnostics: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "engine.combustion.fill")
                        .foregroundStyle(car.hasTroubleCodes ? Theme.warning : Theme.textSecondary)
                    Text("Check engine").font(.dashTitle)
                    Spacer(minLength: 0)
                    if car.isReadingCodes { ProgressView() }
                }
                diagnosticsBody
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var diagnosticsBody: some View {
        if !car.state.isConnected {
            Text(car.state.hasAdapter ? "Trouble codes need the car's computer to answer."
                                       : "Connect to the car to read trouble codes.")
                .font(.dashCaption)
                .foregroundStyle(Theme.textSecondary)
        } else {
            if car.storedCodes.isEmpty && car.pendingCodes.isEmpty {
                Label("No trouble codes", systemImage: "checkmark.circle.fill")
                    .font(.dashBody)
                    .foregroundStyle(Theme.positive)
                    .accessibilityIdentifier("car.noCodes")
            }
            ForEach(car.storedCodes + car.pendingCodes) { code in
                CarCodeRow(code: code)
            }
            if let message = car.codesMessage {
                Text(message).font(.dashCaption).foregroundStyle(Theme.warning)
            }
            if let checked = car.codesCheckedAt {
                Text("Checked \(checked, format: .dateTime.hour().minute())")
                    .font(.dashCaption)
                    .foregroundStyle(Theme.textSecondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { codeButtons }
                VStack(alignment: .leading, spacing: 10) { codeButtons }
            }
            if car.hasTroubleCodes, let reason = car.clearCodesBlockedReason {
                Text(reason).font(.dashCaption).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var codeButtons: some View {
        DashPillButton(title: "Check again", symbol: "arrow.clockwise", prominent: false,
                       identifier: "car.checkCodes") {
            Task { await car.refreshCodes() }
        }
        .disabled(car.isReadingCodes)
        if car.hasTroubleCodes {
            DashPillButton(title: "Clear codes", symbol: "trash", tint: Theme.danger, identifier: "car.clearCodes") {
                confirmingClear = true
            }
            .disabled(!car.canClearCodes)
            .opacity(car.canClearCodes ? 1 : 0.45)
        }
    }
}

/// One big, glanceable reading.
struct CarGaugeTile: View {
    let title: String
    let symbol: String
    let value: String?
    let unit: String
    var tint: Color = Theme.textPrimary
    /// 0...1 for a bar under the value (RPM), or nil for none.
    var fraction: Double?

    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: symbol)
                    .font(.dashCaption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value ?? "–")
                        .font(.system(size: 46, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .contentTransition(.numericText())
                    Text(unit).font(.dashCaption).foregroundStyle(Theme.textSecondary)
                }
                if let fraction {
                    GeometryReader { bar in
                        Capsule().fill(Theme.surfaceRaised)
                            .overlay(alignment: .leading) {
                                Capsule().fill(tint == Theme.textPrimary ? Theme.accent : tint)
                                    .frame(width: bar.size.width * max(0, min(1, fraction)))
                            }
                    }
                    .frame(height: 6)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(value ?? "unavailable") \(unit)")
    }
}

struct CarCodeRow: View {
    let code: DTC

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(code.code)
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundStyle(code.isPending ? Theme.warning : Theme.danger)
            VStack(alignment: .leading, spacing: 2) {
                Text(code.description).font(.dashCaption).foregroundStyle(Theme.textPrimary)
                if code.isPending {
                    Text("Pending: seen once, not confirmed yet").font(.dashCaption).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(minHeight: Theme.minTouch)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("car.code.\(code.code)")
    }
}

/// Connection status with what to do next.
struct CarStatusCard: View {
    @Environment(CarDataModel.self) private var car

    var body: some View {
        let info = Self.guidance(for: car.state, remembered: car.rememberedAdapterName)
        Card {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    if info.busy {
                        ProgressView().controlSize(.large)
                    } else {
                        Image(systemName: info.symbol)
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(info.tint)
                    }
                }
                .frame(width: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(info.title).font(.dashTitle).lineLimit(2)
                    Text(info.message)
                        .font(.dashCaption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if car.state.isConnected, let updated = car.lastUpdate {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let age = max(0, Int(context.date.timeIntervalSince(updated)))
                            Text(age < 3 ? "Live" : "Updated \(age) s ago")
                                .font(.dashCaption)
                                .foregroundStyle(age < 3 ? Theme.positive : Theme.warning)
                        }
                    }
                }
                Spacer(minLength: 0)
                action
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("car.status")
    }

    @ViewBuilder
    private var action: some View {
        switch car.state {
        case .idle:
            DashPillButton(title: "Connect", symbol: "antenna.radiowaves.left.and.right", identifier: "car.connect") {
                car.start()
            }
        case .unauthorised:
            DashPillButton(title: "Settings", symbol: "gear", identifier: "car.settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        case .noECU, .failed:
            DashPillButton(title: "Try again", symbol: "arrow.clockwise", identifier: "car.retry") { car.retry() }
        default:
            EmptyView()
        }
    }

    struct Guidance {
        var symbol: String
        var title: String
        var message: String
        var tint: Color = Theme.accent
        var busy = false
    }

    static func guidance(for state: CarConnectionState, remembered: String?) -> Guidance {
        switch state {
        case .idle:
            Guidance(symbol: "car.side", title: "Car data",
                     message: "Plug a Bluetooth LE OBD-II adapter into the port under the dashboard, turn the ignition on, then tap Connect.")
        case .bluetoothOff:
            Guidance(symbol: "antenna.radiowaves.left.and.right.slash", title: "Bluetooth is off",
                     message: "Turn Bluetooth on in Control Center to read car data.", tint: Theme.warning)
        case .unauthorised:
            Guidance(symbol: "lock.shield", title: "Bluetooth access needed",
                     message: "Allow Bluetooth for this app in Settings to talk to the OBD-II adapter.", tint: Theme.warning)
        case .searching:
            Guidance(symbol: "magnifyingglass", title: remembered.map { "Waiting for \($0)" } ?? "Looking for an adapter",
                     message: remembered == nil
                        ? "Plug the adapter in and turn the ignition on. Then pick it from the list below."
                        : "It connects by itself once it's plugged in and the ignition is on. Most adapters light up when powered.",
                     busy: true)
        case .connecting(let name):
            Guidance(symbol: "antenna.radiowaves.left.and.right", title: "Connecting to \(name)",
                     message: "This takes a few seconds.", busy: true)
        case .initialising:
            Guidance(symbol: "cpu", title: "Talking to the car",
                     message: "Resetting the adapter and finding the car's protocol. The first time can take up to 15 seconds.",
                     busy: true)
        case .connected(let name):
            Guidance(symbol: "checkmark.circle.fill", title: "Connected", message: name, tint: Theme.positive)
        case .noECU(let message):
            Guidance(symbol: "exclamationmark.triangle.fill", title: "Adapter connected",
                     message: message + " Turn the ignition on if it's off; Duo Dash keeps trying.", tint: Theme.warning)
        case .failed(let message):
            Guidance(symbol: "xmark.octagon.fill", title: "Couldn't connect", message: message, tint: Theme.danger)
        }
    }
}

/// Found adapters, Search again and Forget adapter.
struct CarAdapterSection: View {
    @Environment(CarDataModel.self) private var car

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Adapter").font(.dashTitle)
                    Spacer(minLength: 0)
                    if car.isDemo {
                        Text("Demo").font(.dashCaption).foregroundStyle(Theme.textSecondary)
                    }
                }
                if let current = car.adapterName ?? car.rememberedAdapterName {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(current).font(.dashBody)
                        Text([car.adapterVersion, car.rememberedAdapterName != nil ? "Reconnects automatically" : nil]
                                .compactMap { $0 }.joined(separator: " · "))
                            .font(.dashCaption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                let others = car.adapters.filter { $0.name != car.adapterName || !car.state.hasAdapter }
                if !others.isEmpty {
                    Text("Nearby").font(.dashCaption).foregroundStyle(Theme.textSecondary)
                    ForEach(others.prefix(8)) { adapter in
                        ListRow(title: adapter.name,
                                subtitle: adapter.isLikelyOBD ? "OBD-II adapter" : "Bluetooth device",
                                identifier: "car.adapter.\(adapter.name)") {
                            Image(systemName: adapter.isLikelyOBD ? "car.side" : "dot.radiowaves.left.and.right")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(adapter.isLikelyOBD ? Theme.accent : Theme.textSecondary)
                                .frame(width: 36)
                        } action: {
                            car.connect(to: adapter)
                        }
                    }
                } else if !car.state.hasAdapter {
                    Text("No adapters found yet. iPhone can only use Bluetooth LE (BLE 4.0) or Wi-Fi adapters, not classic Bluetooth ones.")
                        .font(.dashCaption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { buttons }
                    VStack(alignment: .leading, spacing: 10) { buttons }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var buttons: some View {
        DashPillButton(title: "Search again", symbol: "magnifyingglass", prominent: false, identifier: "car.scan") {
            car.scanForAdapters()
        }
        if car.rememberedAdapterName != nil {
            DashPillButton(title: "Forget adapter", symbol: "xmark", prominent: false, identifier: "car.forget") {
                car.forgetAdapter()
            }
        }
    }
}
