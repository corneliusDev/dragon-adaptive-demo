//  ConnectBar.swift  — small connect/disconnect control used by ContentView.
import SwiftUI
struct ConnectBar: View {
    @ObservedObject var hud: HUDController
    var body: some View {
        Button(hud.connection.isConnected ? "DISCONNECT" : "CONNECT GLASSES") {
            hud.connection.isConnected ? hud.disconnect() : hud.connect()
        }
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .foregroundColor(hud.connection.isConnected ? .red : .green)
        .frame(maxWidth: .infinity).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 7).stroke(Color(white: 0.2)))
    }
}
