//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  NativeEngine.swift
//  Starscream
//
//  Created by Dalton Cherry on 6/15/19
//  Copyright © 2019 Vluxe. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//
//////////////////////////////////////////////////////////////////////////////////////////////////

import Foundation

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public class NativeEngine: NSObject, Engine, URLSessionDataDelegate, URLSessionWebSocketDelegate {
    private var task: URLSessionWebSocketTask?
    weak var delegate: EngineDelegate?
    private var certPinner: CertificatePinning? = nil
    
    // --- [新增] Ping/Pong 相關屬性 ---
    private var pingTimer: Timer?
    public var pingInterval: TimeInterval = 30.0 // 預設每 30 秒 Ping 一次
    // -------------------------------
    
    init(certPinner: CertificatePinning?) {
        self.certPinner = certPinner
    }
    
    public func register(delegate: EngineDelegate) {
        self.delegate = delegate
    }

    public func start(request: URLRequest) {
        let session = URLSession(configuration: URLSessionConfiguration.default, delegate: self, delegateQueue: nil)
        task = session.webSocketTask(with: request)
        doRead()
        task?.resume()
    }

    public func stop(closeCode: UInt16) {
        // [新增] 停止 Ping Timer
        stopPing()
        
        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: Int(closeCode)) ?? .normalClosure
        task?.cancel(with: closeCode, reason: nil)
    }

    public func forceStop() {
        stop(closeCode: UInt16(URLSessionWebSocketTask.CloseCode.abnormalClosure.rawValue))
    }

    public func write(string: String, completion: (() -> ())?) {
        task?.send(.string(string), completionHandler: { (error) in
            completion?()
        })
    }

    public func write(data: Data, opcode: FrameOpCode, completion: (() -> ())?) {
        switch opcode {
        case .binaryFrame:
            task?.send(.data(data), completionHandler: { (error) in
                completion?()
            })
        case .textFrame:
            // 先前是強制解包，呼叫 write(stringData:) 傳入非 UTF-8 資料就會 crash。
            guard let text = String(data: data, encoding: .utf8) else {
                broadcast(event: .error(WSError(type: .protocolError,
                                                message: "text frame payload is not valid UTF-8",
                                                code: CloseCode.encoding.rawValue)))
                completion?()
                return
            }
            write(string: text, completion: completion)
        case .ping:
            task?.sendPing(pongReceiveHandler: { (error) in
                completion?()
            })
        default:
            break //unsupported
        }
    }

    private func doRead() {
        task?.receive { [weak self] (result) in
            switch result {
            case .success(let message):
                switch message {
                case .string(let string):
                    self?.broadcast(event: .text(string))
                case .data(let data):
                    self?.broadcast(event: .binary(data))
                @unknown default:
                    break
                }
                break
            case .failure(let error):
                self?.broadcast(event: .error(error))
                // [新增] 讀取失敗時也要停止 Ping
                self?.stopPing()
                return
            }
            self?.doRead()
        }
    }

    private func broadcast(event: WebSocketEvent) {
        delegate?.didReceive(event: event)
    }
    
    // --- [新增] Ping/Pong 邏輯 ---
    
    private func startPing() {
        stopPing() // 確保舊的 Timer 已移除
        
        // 為了簡單起見，我們將 Timer 排程在主執行緒
        // 如果你的 App 對主執行緒非常敏感，可以改用 DispatchSourceTimer
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.pingTimer = Timer.scheduledTimer(withTimeInterval: self.pingInterval, repeats: true) { [weak self] _ in
                self?.sendPing()
            }
        }
    }
    
    private func stopPing() {
        DispatchQueue.main.async { [weak self] in
            self?.pingTimer?.invalidate()
            self?.pingTimer = nil
        }
    }
    
    private func sendPing() {
        // 發送 Ping
        task?.sendPing { [weak self] (error) in
            if let error = error {
                // 如果 Ping 發送失敗或沒有收到 Pong (error 不為 nil)
                // 這通常代表連線已經斷了，NativeEngine 會自動觸發 disconnect，這裡僅作紀錄
                print("[NativeEngine] Ping failed/timeout: \(error)")
            } else {
                // 成功收到 Pong
                // print("[NativeEngine] Pong received")
            }
        }
    }
    
    // ---------------------------
    
    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        let p = `protocol` ?? ""
        broadcast(event: .connected([HTTPWSHeader.protocolName: p]))
        
        // [新增] 連線建立後，開始 Ping
        startPing()
    }
    
    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        // [新增] 連線關閉，停止 Ping
        stopPing()
        
        var r = ""
        if let d = reason {
            r = String(data: d, encoding: .utf8) ?? ""
        }
        broadcast(event: .disconnected(r, UInt16(closeCode.rawValue)))
    }
    
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // [新增] 發生錯誤，停止 Ping
        stopPing()
        
        broadcast(event: .error(error))
    }
    
    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // 只接管伺服器憑證驗證，其餘（Basic / NTLM / proxy 等）交還系統處理，
        // 先前一律 cancelAuthenticationChallenge 會讓這些情境直接連不上。
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // 沒有 pinner 就走系統預設驗證。先前用 .useCredential 搭配 nil credential，
        // 語意未定義，實務上等同不做驗證。
        guard let certPinner = certPinner else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // host 為 IP 直連時，這裡拿到的就是 IP，會比對憑證的 iPAddress SAN。
        certPinner.evaluateTrust(trust: serverTrust, domain: challenge.protectionSpace.host) { (state) in
            switch state {
            case .success:
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
            case .failed(_):
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }
}
