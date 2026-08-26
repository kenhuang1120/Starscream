//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  HTTPTransport.swift
//  Starscream
//
//  Created by Dalton Cherry on 1/23/19.
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

#if canImport(Network)
import Foundation
import Network

public enum TCPTransportError: Error {
    case invalidRequest
}

@available(macOS 10.14, iOS 12.0, watchOS 5.0, tvOS 12.0, *)
public class TCPTransport: Transport {
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.vluxe.starscream.networkstream", attributes: [])
    private weak var delegate: TransportEventClient?
    private var isRunning = false
    private var isTLS = false
    /// 憑證要驗證的主機名稱。以 IP 直連、但伺服器憑證只簽了網域名稱時，
    /// 在此指定該網域即可正常完成 TLS 驗證。
    private let tlsPeerName: String?
   
    deinit {
        disconnect()
    }
 
    public var usingTLS: Bool {
        return self.isTLS
    }
    
    public init(connection: NWConnection) {
        self.tlsPeerName = nil
        self.connection = connection
        start()
    }
    
    /// - Parameter tlsPeerName: 憑證驗證時要比對的主機名稱，同時作為 SNI 送出。
    ///   預設為 URL 的 host；以 IP 直連但憑證上只有網域名稱時，請帶入該網域。
    public init(tlsPeerName: String? = nil) {
        self.tlsPeerName = tlsPeerName
        //normal connection, will use the "connect" method below
    }
    
    public func connect(url: URL, timeout: Double = 10, certificatePinning: CertificatePinning? = nil) {
        guard let parts = url.getParts() else {
            delegate?.connectionChanged(state: .failed(TCPTransportError.invalidRequest))
            return
        }
        self.isTLS = parts.isTLS
        let options = NWProtocolTCP.Options()
        options.connectionTimeout = Int(timeout.rounded(.up))

        // 憑證要比對的名稱。以 IP 直連時 host 就是 IP，會比對憑證的 iPAddress SAN。
        let peerName = tlsPeerName ?? parts.host

        let tlsOptions = isTLS ? NWProtocolTLS.Options() : nil
        if let tlsOpts = tlsOptions {
            // 明確指定 tlsPeerName 時一併覆寫 SNI 與驗證用的名稱。
            if let tlsPeerName = tlsPeerName {
                sec_protocol_options_set_tls_server_name(tlsOpts.securityProtocolOptions, tlsPeerName)
            }

            // 只有在有 pinner 時才接管驗證。沒有 pinner 就不要安裝 verify block，
            // 讓 Network.framework 做它自己的標準憑證驗證；先前在這裡直接
            // sec_protocol_verify_complete(true) 等於對任何憑證照單全收。
            if let pinner = certificatePinning {
                sec_protocol_options_set_verify_block(tlsOpts.securityProtocolOptions, { (sec_protocol_metadata, sec_trust, sec_protocol_verify_complete) in
                    let trust = sec_trust_copy_ref(sec_trust).takeRetainedValue()
                    pinner.evaluateTrust(trust: trust, domain: peerName, completion: { (state) in
                        switch state {
                        case .success:
                            sec_protocol_verify_complete(true)
                        case .failed(_):
                            sec_protocol_verify_complete(false)
                        }
                    })
                }, queue)
            }
        }
        let parameters = NWParameters(tls: tlsOptions, tcp: options)
        parameters.multipathServiceType = .handover
        // NWEndpoint.Host(_:) 會自動辨識 IPv4/IPv6 字面值，避免把 IP 當成
        // 網域名稱去做 DNS 解析、也不會送出 IP 形式的 SNI。
        let conn = NWConnection(host: NWEndpoint.Host(parts.host), port: NWEndpoint.Port(rawValue: UInt16(parts.port))!, using: parameters)
        connection = conn
        start()
    }
    
    public func disconnect() {
        isRunning = false
        connection?.cancel()
        connection = nil
    }
    
    public func register(delegate: TransportEventClient?) {
        self.delegate = delegate
    }
    
    public func write(data: Data, completion: @escaping ((Error?) -> ())) {
        connection?.send(content: data, completion: .contentProcessed { (error) in
            completion(error)
        })
    }
    
    private func start() {
        guard let conn = connection else {
            return
        }
        conn.stateUpdateHandler = { [weak self] (newState) in
            switch newState {
            case .ready:
                self?.delegate?.connectionChanged(state: .connected)
            case let .waiting(error):
                switch error {
                case .posix(.ETIMEDOUT):
                    self?.delegate?.connectionChanged(state: .failed(error))
                case .tls:
                    // TLS 交握失敗（憑證無效等）不會因為繼續等待而恢復，
                    // NWConnection 會一直停在 .waiting 而不會轉成 .failed，
                    // 不在這裡回報就會變成無聲卡住。
                    self?.delegate?.connectionChanged(state: .failed(error))
                default:
                    self?.delegate?.connectionChanged(state: .waiting)
                }
            case .cancelled:
                self?.delegate?.connectionChanged(state: .cancelled)
            case .failed(let error):
                self?.delegate?.connectionChanged(state: .failed(error))
            case .setup, .preparing:
                break
            @unknown default:
                break
            }
        }
        
        conn.viabilityUpdateHandler = { [weak self] (isViable) in
            self?.delegate?.connectionChanged(state: .viability(isViable))
        }
        
        conn.betterPathUpdateHandler = { [weak self] (isBetter) in
            self?.delegate?.connectionChanged(state: .shouldReconnect(isBetter))
        }
        
        conn.start(queue: queue)
        isRunning = true
        readLoop()
    }
    
    //readLoop keeps reading from the connection to get the latest content
    private func readLoop() {
        guard isRunning, let connection = connection else {
            return
        }
        
        connection.receive(minimumIncompleteLength: 2, maximumLength: 4096, completion: { [weak self] (data, context, isComplete, error) in
            guard let self = self, self.isRunning else {
                return
            }
            
            if let data = data {
                self.delegate?.connectionChanged(state: .receive(data))
            }
            
            // Refer to https://developer.apple.com/documentation/network/implementing_netcat_with_network_framework
            if let context = context, context.isFinal, isComplete {
                if let delegate = self.delegate {
                    // Let the owner of this TCPTransport decide what to do next: disconnect or reconnect?
                    delegate.connectionChanged(state: .peerClosed)
                } else {
                    // No use to keep connection alive
                    self.disconnect()
                }
                return
            }
            
            if error == nil && self.isRunning {
                self.readLoop()
            } else if let error = error {
                self.delegate?.connectionChanged(state: .failed(error))
            }
        })
    }
}
#else
typealias TCPTransport = FoundationTransport
#endif
