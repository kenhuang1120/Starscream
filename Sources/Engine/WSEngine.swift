//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  WSEngine.swift
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

public class WSEngine: Engine, TransportEventClient, FramerEventClient,
FrameCollectorDelegate, HTTPHandlerDelegate {
    private let transport: Transport
    private let framer: Framer
    private let httpHandler: HTTPHandler
    private let compressionHandler: CompressionHandler?
    private let certPinner: CertificatePinning?
    private let headerChecker: HeaderValidator
    private let cookieStorage: HTTPCookieStorage?
    private var request: URLRequest!
    
    private let frameHandler = FrameCollector()
    private var didUpgrade = false
    private var secKeyValue = ""
    private let writeQueue = DispatchQueue(label: "com.vluxe.starscream.writequeue")
    private let keepAliveQueue = DispatchQueue(label: "com.vluxe.starscream.keepalive")
    /// 只保護兩個 timer，跟 mutex 分開以免彼此等待。
    private let keepAliveLock = NSLock()
    private var pingTimer: DispatchSourceTimer?
    private var pongWatchdog: DispatchSourceTimer?
    private let mutex = DispatchSemaphore(value: 1)
    private var canSend = false
    private var isConnecting = false
    /// 曾經連線成功過，重連前要先把上一條連線收乾淨。
    private var needsTransportReset = false
    
    weak var delegate: EngineDelegate?
    public var respondToPingWithPong: Bool = true
    /// 每隔多久送一次 ping。設 0 以下表示不送。
    public var pingInterval: TimeInterval
    /// 送出 ping 後等待 pong 的上限，逾時就視為連線已死。
    public var pongTimeout: TimeInterval
    
    public init(transport: Transport,
                certPinner: CertificatePinning? = nil,
                headerValidator: HeaderValidator = FoundationSecurity(),
                httpHandler: HTTPHandler = FoundationHTTPHandler(),
                framer: Framer? = nil,
                compressionHandler: CompressionHandler? = nil,
                cookieStorage: HTTPCookieStorage? = .shared,
                maxMessageSize: Int = DefaultMaxPayloadLength,
                pingInterval: TimeInterval = 30.0,
                pongTimeout: TimeInterval = 10.0) {
        self.pingInterval = pingInterval
        self.pongTimeout = pongTimeout
        self.transport = transport
        self.framer = framer ?? WSFramer(maxPayloadLength: maxMessageSize)
        self.httpHandler = httpHandler
        self.certPinner = certPinner
        self.headerChecker = headerValidator
        self.compressionHandler = compressionHandler
        self.cookieStorage = cookieStorage
        frameHandler.maxMessageSize = maxMessageSize
        self.framer.updateCompression(supports: compressionHandler != nil)
        frameHandler.delegate = self
    }
    
    public func register(delegate: EngineDelegate) {
        self.delegate = delegate
    }
    
    public func start(request: URLRequest) {
        mutex.wait()
        let isConnecting = self.isConnecting
        let isConnected = canSend
        mutex.signal()
        if isConnecting || isConnected {
            return
        }
        
        self.request = request
        transport.register(delegate: self)
        framer.register(delegate: self)
        httpHandler.register(delegate: self)
        frameHandler.delegate = self
        guard let url = request.url else {
            return
        }
        mutex.wait()
        self.isConnecting = true
        let needsReset = needsTransportReset
        needsTransportReset = false
        mutex.signal()

        // 上一條連線（例如對方關閉後）可能還握著 socket，重連前先收乾淨，
        // 否則舊的 NWConnection / stream 會一路累積下去。
        if needsReset {
            transport.disconnect()
        }
        transport.connect(url: url, timeout: request.timeoutInterval, certificatePinning: certPinner)
    }
    
    public func stop(closeCode: UInt16 = CloseCode.normal.rawValue) {
        let capacity = MemoryLayout<UInt16>.size
        var pointer = [UInt8](repeating: 0, count: capacity)
        writeUint16(&pointer, offset: 0, value: closeCode)
        let payload = Data(bytes: pointer, count: MemoryLayout<UInt16>.size)
        write(data: payload, opcode: .connectionClose, completion: { [weak self] in
            self?.reset()
            self?.forceStop()
        })
    }
    
    public func forceStop() {
        stopKeepAlive()
        mutex.wait()
        isConnecting = false
        mutex.signal()
        
        transport.disconnect()
    }
    
    public func write(string: String, completion: (() -> ())?) {
        let data = string.data(using: .utf8)!
        write(data: data, opcode: .textFrame, completion: completion)
    }
    
    public func write(data: Data, opcode: FrameOpCode, completion: (() -> ())?) {
        writeQueue.async { [weak self] in
            guard let s = self else { return }
            s.mutex.wait()
            let canWrite = s.canSend
            s.mutex.signal()
            if !canWrite {
                return
            }
            
            var isCompressed = false
            var sendData = data
            if let compressedData = s.compressionHandler?.compress(data: data) {
                sendData = compressedData
                isCompressed = true
            }
            
            let frameData = s.framer.createWriteFrame(opcode: opcode, payload: sendData, isCompressed: isCompressed)
            s.transport.write(data: frameData, completion: {_ in
                completion?()
            })
        }
    }
    
    // MARK: - TransportEventClient
    
    public func connectionChanged(state: ConnectionState) {
        switch state {
        case .connected:
            mutex.wait()
            needsTransportReset = true
            mutex.signal()
            secKeyValue = HTTPWSHeader.generateWebSocketKey()
            let wsReq = HTTPWSHeader.createUpgrade(request: request,
                                                  supportsCompression: framer.supportsCompression(),
                                                  secKeyValue: secKeyValue,
                                                  cookieStorage: cookieStorage)
            let data = httpHandler.convert(request: wsReq)
            transport.write(data: data, completion: {_ in })
        case .waiting:
            break
        case .failed(let error):
            handleError(error)
        case .viability(let isViable):
            broadcast(event: .viabilityChanged(isViable))
        case .shouldReconnect(let status):
            broadcast(event: .reconnectSuggested(status))
        case .receive(let data):
            if didUpgrade {
                framer.add(data: data)
            } else {
                let offset = httpHandler.parse(data: data)
                if offset > 0 {
                    let extraData = data.subdata(in: offset..<data.endIndex)
                    framer.add(data: extraData)
                }
            }
        case .cancelled:
            // 先前只清掉 isConnecting，canSend / didUpgrade 仍留在上一條連線的狀態。
            // start() 的守衛是 (isConnecting || canSend)，所以 App 之後呼叫
            // connect() 會直接 return 什麼都不做，斷線後就再也連不回來。
            reset()
            broadcast(event: .cancelled)
        case .peerClosed:
            reset()
            broadcast(event: .peerClosed)
        }
    }
    
    // MARK: - HTTPHandlerDelegate
    
    public func didReceiveHTTP(event: HTTPEvent) {
        switch event {
        case .success(let headers):
            if let error = headerChecker.validate(headers: headers, key: secKeyValue) {
                handleError(error)
                return
            }
            mutex.wait()
            isConnecting = false
            didUpgrade = true
            canSend = true
            mutex.signal()
            compressionHandler?.load(headers: headers)
            // 只在 TLS 連線上採納伺服器送來的 cookie。明文 ws:// 的 Set-Cookie
            // 可被任意竄改，寫進共用 storage 後會被 App 其他 HTTPS 流量帶出去，
            // 形成 session fixation。
            if let url = request.url, url.isTLSScheme, let cookieStorage = cookieStorage {
                HTTPCookie.cookies(withResponseHeaderFields: headers, for: url).forEach {
                    cookieStorage.setCookie($0)
                }
            }

            broadcast(event: .connected(headers))
            startKeepAlive()
        case .failure(let error):
            handleError(error)
        }
    }
    
    // MARK: - FramerEventClient
    
    public func frameProcessed(event: FrameEvent) {
        switch event {
        case .frame(let frame):
            frameHandler.add(frame: frame)
        case .error(let error):
            handleError(error)
        }
    }
    
    // MARK: - FrameCollectorDelegate
    
    public func decompress(data: Data, isFinal: Bool) -> Data? {
        return compressionHandler?.decompress(data: data, isFinal: isFinal)
    }
    
    public func didForm(event: FrameCollector.Event) {
        switch event {
        case .text(let string):
            broadcast(event: .text(string))
        case .binary(let data):
            broadcast(event: .binary(data))
        case .pong(let data):
            cancelPongWatchdog()
            broadcast(event: .pong(data))
        case .ping(let data):
            broadcast(event: .ping(data))
            if respondToPingWithPong {
                write(data: data ?? Data(), opcode: .pong, completion: nil)
            }
        case .closed(let reason, let code):
            broadcast(event: .disconnected(reason, code))
            stop(closeCode: code)
        case .error(let error):
            handleError(error)
        }
    }
    
    private func broadcast(event: WebSocketEvent) {
        delegate?.didReceive(event: event)
    }
    
    //This call can be coming from a lot of different queues/threads.
    //be aware of that when modifying shared variables
    private func handleError(_ error: Error?) {
        if let wsError = error as? WSError {
            stop(closeCode: wsError.code)
        } else {
            stop()
        }
        
        delegate?.didReceive(event: .error(error))
    }
    
    // MARK: - Keep-alive

    /// 握手完成後開始定期送 ping。用掛在自有 queue 上的 DispatchSourceTimer，
    /// 而不是 main run loop 的 Timer：App 進背景後 run loop 會停擺、UI 捲動時
    /// run loop 進入 .tracking mode，兩種情況 Timer 都不會觸發，連線就被
    /// 伺服器或 NAT 的 idle timeout 砍掉。
    private func startKeepAlive() {
        stopKeepAlive()
        guard pingInterval > 0 else { return }

        let timer = DispatchSource.makeTimerSource(queue: keepAliveQueue)
        timer.schedule(deadline: .now() + pingInterval, repeating: pingInterval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.sendKeepAlivePing()
        }
        keepAliveLock.lock()
        pingTimer = timer
        keepAliveLock.unlock()
        timer.resume()
    }

    private func stopKeepAlive() {
        keepAliveLock.lock()
        let ping = pingTimer
        let watchdog = pongWatchdog
        pingTimer = nil
        pongWatchdog = nil
        keepAliveLock.unlock()
        ping?.cancel()
        watchdog?.cancel()
    }

    /// 收到任何 pong 都代表對方還活著。
    private func cancelPongWatchdog() {
        keepAliveLock.lock()
        let watchdog = pongWatchdog
        pongWatchdog = nil
        keepAliveLock.unlock()
        watchdog?.cancel()
    }

    private func sendKeepAlivePing() {
        mutex.wait()
        let canWrite = canSend
        mutex.signal()
        guard canWrite else { return }

        // ping 送得出去不代表對方還活著。行動網路切換造成的半開連線，
        // 寫入會成功但 pong 永遠不回，因此另外掛一個逾時看門狗。
        // 必須在寫入「之前」就架好，否則很快回來的 pong 會取消不到它。
        armPongWatchdogIfNeeded()
        write(data: Data(), opcode: .ping, completion: nil)
    }

    private func armPongWatchdogIfNeeded() {
        keepAliveLock.lock()
        // 上一個 ping 還在等 pong 時要維持原本的期限，不能重新計時：
        // 否則只要 pingInterval 小於 pongTimeout，每次 ping 都會把看門狗
        // 往後推，逾時就永遠不會觸發。
        guard pongWatchdog == nil else {
            keepAliveLock.unlock()
            return
        }
        let watchdog = DispatchSource.makeTimerSource(queue: keepAliveQueue)
        watchdog.schedule(deadline: .now() + pongTimeout)
        watchdog.setEventHandler { [weak self] in
            self?.handleKeepAliveTimeout()
        }
        pongWatchdog = watchdog
        keepAliveLock.unlock()
        watchdog.resume()
    }

    private func handleKeepAliveTimeout() {
        stopKeepAlive()
        let error = WSError(type: .protocolError,
                            message: "did not receive pong within \(pongTimeout) seconds",
                            code: CloseCode.protocolError.rawValue)
        broadcast(event: .error(error))
        forceStop()
    }

    private func reset() {
        stopKeepAlive()
        mutex.wait()
        isConnecting = false
        canSend = false
        didUpgrade = false
        mutex.signal()
    }
    
    
}
