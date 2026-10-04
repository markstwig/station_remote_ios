import Foundation
import Capacitor

/// WebSocket client that accepts the speaker's self-signed certificate.
@objc(StationSocketPlugin)
public class StationSocketPlugin: CAPPlugin, CAPBridgedPlugin, URLSessionWebSocketDelegate {
    public let identifier = "StationSocketPlugin"
    public let jsName = "StationSocket"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "connect", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "send", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "disconnect", returnType: CAPPluginReturnPromise),
    ]
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var pending: CAPPluginCall?

    @objc func connect(_ call: CAPPluginCall) {
        guard let s = call.getString("url"), let url = URL(string: s) else { return call.reject("bad url") }
        task?.cancel(with: .goingAway, reason: nil)
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let t = session.webSocketTask(with: url)
        self.session = session; task = t; pending = call
        t.resume()
        receive(t)
    }

    @objc func send(_ call: CAPPluginCall) {
        guard let t = task, let data = call.getString("data") else { return call.reject("not connected") }
        t.send(.string(data)) { err in
            if let err = err { call.reject(err.localizedDescription) } else { call.resolve() }
        }
    }

    @objc func disconnect(_ call: CAPPluginCall) {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        call.resolve()
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self = self, t === self.task, case .success(let msg) = result else { return }
            switch msg {
            case .string(let s): self.notifyListeners("message", data: ["data": s])
            case .data(let d): self.notifyListeners("message", data: ["data": String(decoding: d, as: UTF8.self)])
            @unknown default: break
            }
            self.receive(t)
        }
    }

    public func urlSession(_ s: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol p: String?) {
        pending?.resolve(); pending = nil
    }

    public func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task else { return }
        pending?.reject(error?.localizedDescription ?? "connection closed"); pending = nil
        notifyListeners("closed", data: ["reason": error?.localizedDescription ?? ""])
    }

    // Trust the speaker's self-signed certificate (this session only ever connects to the speaker).
    public func urlSession(_ s: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
