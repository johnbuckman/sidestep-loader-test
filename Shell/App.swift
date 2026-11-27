import SwiftUI
import UniformTypeIdentifiers

@main
struct LoaderTestApp: App {
    @StateObject private var loader = Loader()
    var body: some Scene {
        WindowGroup { ContentView().environmentObject(loader) }
    }
}

struct ContentView: View {
    @EnvironmentObject var loader: Loader
    @State private var importing = false
    @State private var password = ""
    @State private var showPayload = false

    var body: some View {
        NavigationView {
            List {
                Section {
                    Text("Downloads a dylib, signs it on this phone with your Apple ID's key, and loads it with dlopen. Then it tries an unsigned copy, which iOS should refuse.")
                        .font(.footnote).foregroundColor(.secondary)
                }
                Section(header: Text("1. Signing key")) {
                    Text(loader.keySummary)
                    SecureField("Password (only for a .p12)", text: $password)
                        .textContentType(.password)
                    Button("Import key file…") { importing = true }
                    Text("On your Mac: ~/Library/Application Support/SideStep/cert-<your Apple ID>.json. AirDrop it to this phone, save it to Files, then import it here.")
                        .font(.footnote).foregroundColor(.secondary)
                    if loader.keySummary.hasPrefix("Signing key imported") {
                        Button("Forget key", role: .destructive) { loader.forgetKey() }
                    }
                }
                Section(header: Text("2. Payload")) {
                    TextField("https://…/payload.dylib", text: $loader.payloadURL)
                        .keyboardType(.URL).autocapitalization(.none).disableAutocorrection(true)
                        .font(.footnote)
                }
                Section(header: Text("3. Test")) {
                    Button("Run the whole test") { Task { await loader.runAll() } }
                        .font(.headline).disabled(loader.busy)
                    Button("Download only") { Task { _ = await loader.download() } }.disabled(loader.busy)
                    Button("Sign on phone + load") { _ = loader.signAndLoad() }.disabled(loader.busy)
                    Button("Load unsigned copy (control)") { loader.loadUnsigned() }.disabled(loader.busy)
                    if loader.loadedHello != nil {
                        Button("Show the payload's screen") { showPayload = true }
                    }
                }
                Section(header: HStack {
                    Text("Log")
                    Spacer()
                    Button("Copy") { UIPasteboard.general.string = loader.lines.joined(separator: "\n") }
                    Button("Clear") { loader.clearLog() }
                }) {
                    ForEach(Array(loader.lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Loader Test")
        }
        .navigationViewStyle(.stack)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url): loader.importKey(from: url, password: password)
            case .failure(let e): loader.log("❌ Import cancelled: \(e.localizedDescription)")
            }
        }
        .sheet(isPresented: $showPayload) { PayloadScreen().environmentObject(loader) }
    }
}

/// Hosts the UIViewController that the downloaded code builds.
struct PayloadScreen: UIViewControllerRepresentable {
    @EnvironmentObject var loader: Loader
    func makeUIViewController(context: Context) -> UIViewController {
        if let vc = loader.payloadViewController() { return vc }
        let vc = UIViewController()
        let l = UILabel(); l.text = "The payload has no screen function"; l.textAlignment = .center
        vc.view = l
        return vc
    }
    func updateUIViewController(_ vc: UIViewController, context: Context) {}
}
