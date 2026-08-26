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
    weak var delegate: EngineDelegate?
    private var certPinner: CertificatePinning?

    /// task / session 會被多條執行緒碰到（delegate callback、ping timer、呼叫端），
    /// 統一用這把鎖保護。
    private let stateLock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pingTimer: DispatchSourceTimer?
    private var pongWatchdog: DispatchSourceTimer?

    private let timerQueue = DispatchQueue(label: "com.vluxe.starscream.nativeengine.ping")

    /// 每隔多久送一次 ping。設為 0 以下表示不送。
    public var pingInterval: TimeInterval = 30.0
    /// 送出 ping 之後等待 pong 的上限，逾時就視為連線已死。
    public var pongTimeout: TimeInterval = 10.0

    /// - Parameter pingInterval: 每隔多久送一次 ping，設 0 以下表示不送。
    /// - Parameter pongTimeout: 送出 ping 後等待 pong 的上限，逾時視為連線已死。
    public init(certPinner: CertificatePinning? = FoundationSecurity(),
                pingInterval: TimeInterval = 30.0,
                pongTimeout: TimeInterval = 10.0) {
        self.certPinner = certPinner
        self.pingInterval = pingInterval
        self.pongTimeout = pongTimeout
    }

    deinit {
        teardown()
    }

    public func register(delegate: EngineDelegate) {
        self.delegate = delegate
    }

    public func start(request: URLRequest) {
        // 先把上一輪的 session/task 收乾淨。URLSession 會「強參考」delegate
        // （也就是 self）直到 invalidate，先前每次 start 都建新 session 卻從不
        // invalidate，於是 NativeEngine 永遠不會釋放，舊 task 的 callback 也會
        // 繼續打進來，把新連線的狀態弄亂。
        teardown()

        let session = URLSession(configuration: URLSessionConfiguration.default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        stateLock.lock()
        self.session = session
        self.task = task
        stateLock.unlock()

        doRead(task)
        task.resume()
    }

    public func stop(closeCode: UInt16) {
        stopTimers()
        let code = URLSessionWebSocketTask.CloseCode(rawValue: Int(closeCode)) ?? .normalClosure
        // 這裡不 invalidate session，讓關閉交握有機會完成；
        // session 會在 didCloseWith / didCompleteWithError 收到後才釋放。
        currentTask?.cancel(with: code, reason: nil)
    }

    public func forceStop() {
        teardown()
    }

    public func write(string: String, completion: (() -> ())?) {
        currentTask?.send(.string(string), completionHandler: { (error) in
            completion?()
        })
    }

    public func write(data: Data, opcode: FrameOpCode, completion: (() -> ())?) {
        switch opcode {
        case .binaryFrame:
            currentTask?.send(.data(data), completionHandler: { (error) in
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
            currentTask?.sendPing(pongReceiveHandler: { (error) in
                completion?()
            })
        default:
            break //unsupported
        }
    }

    // MARK: - 連線狀態

    private var currentTask: URLSessionWebSocketTask? {
        stateLock.lock(); defer { stateLock.unlock() }
        return task
    }

    /// 這個 callback 是不是來自「目前」這條連線。舊 task 的事件必須丟掉，
    /// 否則上一條連線的錯誤會把剛建立的新連線關掉。
    private func isCurrent(_ candidate: URLSessionTask?) -> Bool {
        guard let candidate = candidate else { return false }
        stateLock.lock(); defer { stateLock.unlock() }
        return task === candidate
    }

    /// 立即釋放 session/task 並丟棄之後的所有事件。
    private func teardown() {
        stopTimers()
        stateLock.lock()
        let task = self.task
        let session = self.session
        self.task = nil
        self.session = nil
        stateLock.unlock()

        task?.cancel()
        // invalidateAndCancel 會解除 URLSession 對 delegate 的強參考。
        session?.invalidateAndCancel()
    }

    /// 連線正常結束後釋放 session，但保留已經送出的事件。
    private func releaseSession() {
        stopTimers()
        stateLock.lock()
        let session = self.session
        self.session = nil
        self.task = nil
        stateLock.unlock()
        session?.finishTasksAndInvalidate()
    }

    private func doRead(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] (result) in
            guard let self = self, self.isCurrent(task) else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let string):
                    self.broadcast(event: .text(string))
                case .data(let data):
                    self.broadcast(event: .binary(data))
                @unknown default:
                    break
                }
            case .failure(let error):
                self.broadcast(event: .error(error))
                self.releaseSession()
                return
            }
            self.doRead(task)
        }
    }

    private func broadcast(event: WebSocketEvent) {
        delegate?.didReceive(event: event)
    }

    // MARK: - Ping / Pong

    private func startPing() {
        stopTimers()
        guard pingInterval > 0 else { return }

        // 先前用 Timer.scheduledTimer 排在 main run loop：App 進背景後 run loop
        // 停擺、UI 捲動時 run loop 進入 .tracking mode，兩種情況 ping 都不會發，
        // 連線於是被伺服器或 NAT 的 idle timeout 砍掉。
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + pingInterval, repeating: pingInterval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.sendPing()
        }
        stateLock.lock()
        pingTimer = timer
        stateLock.unlock()
        timer.resume()
    }

    private func stopTimers() {
        stateLock.lock()
        let ping = pingTimer
        let watchdog = pongWatchdog
        pingTimer = nil
        pongWatchdog = nil
        stateLock.unlock()
        ping?.cancel()
        watchdog?.cancel()
    }

    private func sendPing() {
        guard let task = currentTask else { return }

        // ping 送得出去不代表對方還活著。行動網路切換造成的半開連線，
        // send 會成功但 pong 永遠不回，因此另外掛一個逾時看門狗。
        let watchdog = DispatchSource.makeTimerSource(queue: timerQueue)
        watchdog.schedule(deadline: .now() + pongTimeout)
        watchdog.setEventHandler { [weak self] in
            self?.handleKeepAliveFailure(WSError(type: .protocolError,
                                                 message: "did not receive pong within \(self?.pongTimeout ?? 0) seconds",
                                                 code: CloseCode.protocolError.rawValue),
                                         task: task)
        }
        stateLock.lock()
        pongWatchdog?.cancel()
        pongWatchdog = watchdog
        stateLock.unlock()
        watchdog.resume()

        task.sendPing { [weak self] (error) in
            guard let self = self else { return }
            self.stateLock.lock()
            let pending = self.pongWatchdog
            self.pongWatchdog = nil
            self.stateLock.unlock()
            pending?.cancel()

            if let error = error {
                self.handleKeepAliveFailure(error, task: task)
            }
        }
    }

    /// ping 失敗或 pong 逾時：先前只有一行 print，上層完全不知道連線已經死了，
    /// 也就無從重連。
    private func handleKeepAliveFailure(_ error: Error, task: URLSessionWebSocketTask) {
        guard isCurrent(task) else { return }
        broadcast(event: .error(error))
        teardown()
    }

    // MARK: - URLSessionWebSocketDelegate

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard isCurrent(webSocketTask) else { return }
        let p = `protocol` ?? ""
        broadcast(event: .connected([HTTPWSHeader.protocolName: p]))
        startPing()
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard isCurrent(webSocketTask) else { return }
        var r = ""
        if let d = reason {
            r = String(data: d, encoding: .utf8) ?? ""
        }
        broadcast(event: .disconnected(r, UInt16(closeCode.rawValue)))
        releaseSession()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard isCurrent(task) else { return }
        // 正常關閉時 error 為 nil，didCloseWith 已經送過事件了，這裡不要再送一次。
        if let error = error {
            broadcast(event: .error(error))
        }
        releaseSession()
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
