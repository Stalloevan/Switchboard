import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var matter: MatterManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingAdd = false
    @State private var showingScenes = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if matter.bulbs.isEmpty {
                        emptyState
                    }
                    ForEach(matter.bulbs) { bulb in
                        BulbCard(bulb: bulb)
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Switchboard")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingScenes = true
                    } label: {
                        Image(systemName: "wand.and.stars")
                    }
                    .disabled(matter.bulbs.isEmpty || !matter.isReady)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(!matter.isReady)
                }
            }
            .sheet(isPresented: $showingScenes) {
                ScenesView()
                    .environmentObject(matter)
            }
            .sheet(isPresented: $showingAdd) {
                AddBulbView()
                    .environmentObject(matter)
            }
            .alert("Something went wrong",
                   isPresented: Binding(get: { matter.errorMessage != nil },
                                        set: { if !$0 { matter.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(matter.errorMessage ?? "")
            }
        }
        .onAppear { matter.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { matter.refreshAll() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "lightbulb")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No bulbs yet")
                .font(.headline)
            Text("Tap + to pair a Matter bulb with its setup code.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

struct BulbCard: View {
    @EnvironmentObject private var matter: MatterManager
    let bulb: Bulb

    private var state: BulbState {
        matter.states[bulb.nodeID] ?? BulbState()
    }

    private var statusText: String {
        if !state.reachable { return "Connecting…" }
        return state.isOn ? "On" : "Off"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: state.isOn ? "lightbulb.fill" : "lightbulb")
                    .font(.title2)
                    .foregroundStyle(state.isOn ? Color.yellow : Color.secondary)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bulb.name)
                        .font(.headline)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Power", isOn: Binding(
                    get: { state.isOn },
                    set: { matter.setPower(bulb.nodeID, on: $0) }
                ))
                .labelsHidden()
                .disabled(!state.reachable)
            }

            if state.hasLevel {
                HStack(spacing: 10) {
                    Image(systemName: "sun.min")
                    Slider(value: Binding(
                        get: { state.level },
                        set: { matter.setLevel(bulb.nodeID, fraction: $0) }
                    ), in: 0...1)
                    Image(systemName: "sun.max")
                }
                .foregroundStyle(.secondary)
                .disabled(!state.reachable || !state.isOn)
            }

            if state.hasColorTemp {
                HStack(spacing: 10) {
                    Text("Cool")
                        .font(.caption)
                    Slider(value: Binding(
                        get: { state.mireds },
                        set: { matter.setColorTemp(bulb.nodeID, mireds: $0) }
                    ), in: state.minMireds...state.maxMireds)
                    Text("Warm")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .disabled(!state.reachable || !state.isOn)
            }

            if state.hasHueSat {
                ColorPicker("Color", selection: Binding(
                    get: { Color(hue: state.hue, saturation: state.saturation, brightness: 1) },
                    set: { newColor in
                        var h: CGFloat = 0
                        var s: CGFloat = 0
                        var b: CGFloat = 0
                        var a: CGFloat = 0
                        if UIColor(newColor).getHue(&h, saturation: &s, brightness: &b, alpha: &a) {
                            // The picker can echo back the color it was just given (for example while a
                            // fade updates it). Ignore that, or it would cancel the fade.
                            let current = matter.states[bulb.nodeID] ?? BulbState()
                            if abs(Double(h) - current.hue) < 0.02 && abs(Double(s) - current.saturation) < 0.02 {
                                return
                            }
                            matter.setColor(bulb.nodeID, hue: Double(h), saturation: Double(s))
                        }
                    }
                ), supportsOpacity: false)
                .disabled(!state.reachable || !state.isOn)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .contextMenu {
            Button(role: .destructive) {
                matter.remove(bulb)
            } label: {
                Label("Remove bulb", systemImage: "trash")
            }
        }
    }
}

struct AddBulbView: View {
    @EnvironmentObject private var matter: MatterManager
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var code = ""
    @State private var ssid = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (for example, Desk lamp)", text: $name)
                    TextField("Pairing code", text: $code)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                } header: {
                    Text("Bulb")
                } footer: {
                    Text("Use the 11-digit number printed on the bulb or its box. A reset bulb in pairing mode usually blinks or pulses.")
                }

                Section {
                    TextField("Wi-Fi name", text: $ssid)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Wi-Fi password", text: $password)
                } header: {
                    Text("Wi-Fi (for freshly reset bulbs)")
                } footer: {
                    Text("A reset bulb needs your 2.4 GHz Wi-Fi details. Leave these blank if the bulb is already on your network.")
                }

                if matter.isCommissioning {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(matter.status)
                        }
                    }
                }

                if let failure = matter.pairingError {
                    Section("Pairing failed") {
                        Text(failure)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }

                if !matter.pairingLog.isEmpty {
                    Section {
                        Text(matter.pairingLog.joined(separator: "\n"))
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                        Button("Copy log") {
                            UIPasteboard.general.string = matter.pairingLog.joined(separator: "\n")
                        }
                    } header: {
                        Text("Pairing log")
                    }
                }
            }
            .navigationTitle("Add bulb")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(matter.isCommissioning)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Pair") {
                        matter.addBulb(name: name, code: code, ssid: ssid, password: password)
                    }
                    .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || matter.isCommissioning)
                }
            }
            .onChange(of: matter.pairingFinished) { _, finished in
                if finished {
                    matter.acknowledgePairing()
                    dismiss()
                }
            }
        }
        .interactiveDismissDisabled(matter.isCommissioning)
    }
}
