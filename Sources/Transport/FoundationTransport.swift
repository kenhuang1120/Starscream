//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  FoundationTransport.swift
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

import Foundation

public enum FoundationTransportError: Error {
    case invalidRequest
    case invalidOutputStream
    case timeout
    /// 無法從連線取得 SecTrust，因此無從驗證伺服器憑證。
    case invalidTrust
}

public class FoundationTransport: NSObject, Transport, StreamDelegate {
    private var delegate: TransportEventClient?
    private let workQueue = DispatchQueue(label: "com.vluxe.starscream.websocket", attributes: [])
    private let accessQueue = DispatchQueue(label: "com.vluxe.starscream.access", attributes: .concurrent)
    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private var _isOpen = false
    private var isOpen: Bool {
        get {
            return accessQueue.sync { _isOpen }
        }
        set {
            accessQueue.async(flags: .barrier) { self._isOpen = newValue }
        }
    }
    private var _didSignalConnected = false
    /// 是否已經對外送出 .connected（避免重複送出）。
    private var didSignalConnected: Bool {
        get { return accessQueue.sync { _didSignalConnected } }
        set { accessQueue.sync(flags: .barrier) { self._didSignalConnected = newValue } }
    }
    private var _didFailTrust = false
    /// 憑證驗證是否已判定失敗（失敗後不再送出任何成功事件）。
    private var didFailTrust: Bool {
        get { return accessQueue.sync { _didFailTrust } }
        set { accessQueue.sync(flags: .barrier) { self._didFailTrust = newValue } }
    }
    private var onConnect: ((InputStream, OutputStream) -> Void)?
    private var isTLS = false
    private var certPinner: CertificatePinning?
    /// 憑證要驗證的主機名稱。以 IP 直連、但伺服器憑證只簽了網域名稱時，
    /// 在此指定該網域即可正常完成 TLS 驗證（同時作為 SNI 送出）。
    private let tlsPeerName: String?
    private var expectedPeerName: String?
    
    public var usingTLS: Bool {
        return self.isTLS
    }
    
    /// - Parameter streamConfiguration: 在開啟 stream 前對 stream 做額外設定。
    /// - Parameter tlsPeerName: 憑證驗證時要比對的主機名稱。預設為 URL 的 host；
    ///   以 IP 直連但憑證上只有網域名稱時，請帶入該網域。
    public init(streamConfiguration: ((InputStream, OutputStream) -> Void)? = nil,
                tlsPeerName: String? = nil) {
        self.tlsPeerName = tlsPeerName
        super.init()
        onConnect = streamConfiguration
    }
    
    deinit {
        inputStream?.delegate = nil
        outputStream?.delegate = nil
        delegate = nil
    }
    
    public func connect(url: URL, timeout: Double = 10, certificatePinning: CertificatePinning? = nil) {
        guard let parts = url.getParts() else {
            delegate?.connectionChanged(state: .failed(FoundationTransportError.invalidRequest))
            return
        }
        self.certPinner = certificatePinning
        self.isTLS = parts.isTLS
        self.expectedPeerName = tlsPeerName ?? parts.host
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?
        let h = parts.host as NSString
        CFStreamCreatePairWithSocketToHost(nil, h, UInt32(parts.port), &readStream, &writeStream)
        inputStream = readStream?.takeRetainedValue()
        outputStream = writeStream?.takeRetainedValue()
        guard let inStream = inputStream, let outStream = outputStream else {
                return
        }
        inStream.delegate = self
        outStream.delegate = self
    
        if isTLS {
            inStream.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: Stream.PropertyKey.socketSecurityLevelKey)
            outStream.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: Stream.PropertyKey.socketSecurityLevelKey)

            var sslSettings = [NSString: Any]()

            // 只在「呼叫端明確指定 tlsPeerName」或「host 是網域名稱」時才設定 peer name。
            // host 本身就是 IP 字面值時保持 CFNetwork 的預設行為（不會送出 IP 形式的
            // SNI，違反 RFC 6066），憑證仍會以該 IP 比對 iPAddress SAN。
            if tlsPeerName != nil || !FoundationTransport.isIPAddress(parts.host) {
                sslSettings[NSString(format: kCFStreamSSLPeerName)] = (tlsPeerName ?? parts.host) as NSString
            }

            // 預設維持系統的憑證鏈驗證。只有在 pinner 明確表示要自行接管驗證時
            // 才關閉，避免整條 wss:// 對任何憑證照單全收。
            if certificatePinning?.overridesSystemTrustEvaluation == true {
                sslSettings[NSString(format: kCFStreamSSLValidatesCertificateChain)] = kCFBooleanFalse
            }

            if !sslSettings.isEmpty {
                inStream.setProperty(sslSettings, forKey: kCFStreamPropertySSLSettings as Stream.PropertyKey)
                outStream.setProperty(sslSettings, forKey: kCFStreamPropertySSLSettings as Stream.PropertyKey)
            }
        }
        
        onConnect?(inStream, outStream)
        
        isOpen = false
        didSignalConnected = false
        didFailTrust = false
        CFReadStreamSetDispatchQueue(inStream, workQueue)
        CFWriteStreamSetDispatchQueue(outStream, workQueue)
        inStream.open()
        outStream.open()
        
        
        workQueue.asyncAfter(deadline: .now() + timeout, execute: { [weak self] in
            guard let s = self else { return }
            if !s.isOpen && !s.didFailTrust {
                s.delegate?.connectionChanged(state: .failed(FoundationTransportError.timeout))
            }
        })
    }
    
    public func disconnect() {
        if let stream = inputStream {
            stream.delegate = nil
            CFReadStreamSetDispatchQueue(stream, nil)
            stream.close()
        }
        if let stream = outputStream {
            stream.delegate = nil
            CFWriteStreamSetDispatchQueue(stream, nil)
            stream.close()
        }
        isOpen = false
        didSignalConnected = false
        didFailTrust = false
        outputStream = nil
        inputStream = nil
    }
    
    public func register(delegate: TransportEventClient?) {
        self.delegate = delegate
    }
    
    public func write(data: Data, completion: @escaping ((Error?) -> ())) {
        guard let outStream = outputStream else {
            completion(FoundationTransportError.invalidOutputStream)
            return
        }
        
        data.withUnsafeBytes { bytes in
            let buffer = bytes.bindMemory(to: UInt8.self)
            var total = 0
            while total < data.count {
                let written = outStream.write(buffer.baseAddress! + total, maxLength: data.count - total)
                if written < 0 {
                    completion(FoundationTransportError.invalidOutputStream)
                    return
                }
                total += written
            }
            completion(nil)
        }
    }
    
    private func getSecurityData() -> (SecTrust?, String?) {
        #if os(watchOS)
        return (nil, nil)
        #else
        guard let outputStream = outputStream else {
            return (nil, nil)
        }
        
        var trust: SecTrust? = nil
        // raw CFTypeRef from stream
        if let trustObj = outputStream.property(forKey: kCFStreamPropertySSLPeerTrust as Stream.PropertyKey) {
            // Check CFTypeID to ensure it *is* SecTrust
            if CFGetTypeID(trustObj as CFTypeRef) == SecTrustGetTypeID() {
                trust = (trustObj as! SecTrust)
            }
        }
        
        // Try to get domain from stream property
        var domain = outputStream.property(forKey: kCFStreamSSLPeerName as Stream.PropertyKey) as? String

        
        if domain == nil {
            if #available(iOS 13.0, macOS 10.15, *) {
                if let streamDomain = outputStream.property(forKey: kCFStreamSSLPeerName as Stream.PropertyKey) as? String {
                    domain = streamDomain
                } else {
                    domain = nil
                }
            } else if let sslContextOut = CFWriteStreamCopyProperty(outputStream, CFStreamPropertyKey(rawValue: kCFStreamPropertySSLContext)) as! SSLContext? {
                var peerNameLen: Int = 0
                let status = SSLGetPeerDomainNameLength(sslContextOut, &peerNameLen)
                guard status == errSecSuccess, peerNameLen > 0 else {
                    return (trust, domain)
                }
                
                var peerName = Data(count: peerNameLen)
                let result = peerName.withUnsafeMutableBytes { (peerNamePtr: UnsafeMutableRawBufferPointer) in
                    guard let baseAddress = peerNamePtr.bindMemory(to: Int8.self).baseAddress else {
                        return errSecParam
                    }
                    return SSLGetPeerDomainName(sslContextOut, baseAddress, &peerNameLen)
                }
                
                if result == errSecSuccess,
                   let peerDomain = String(bytes: peerName.prefix(peerNameLen), encoding: .utf8),
                   !peerDomain.isEmpty {
                    domain = peerDomain
                }
            } else {
                domain = nil
            }
        }
        return (trust, domain)
        #endif
    }
    
    /// host 是否為 IPv4/IPv6 字面值。
    static func isIPAddress(_ host: String) -> Bool {
        // URL 的 IPv6 host 會帶中括號，比對前先去掉。
        let trimmed = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var v4 = in_addr()
        if trimmed.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            return true
        }
        var v6 = in6_addr()
        return trimmed.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1
    }

    private func read() {
        guard let stream = inputStream else { return }
        
        let maxBuffer = 4096
        guard let buf = NSMutableData(capacity: maxBuffer) else { return } // 安全檢查
        let buffer = UnsafeMutableRawPointer(mutating: buf.bytes).assumingMemoryBound(to: UInt8.self)
        let length = stream.read(buffer, maxLength: maxBuffer)
        if length < 1 {
            return
        }
        let data = Data(bytes: buffer, count: length)
        delegate?.connectionChanged(state: .receive(data))
    }
    
    // MARK: - StreamDelegate
    
    /// 送出 .connected，重複呼叫或憑證已判定失敗時不做事。
    private func signalConnected() {
        if didSignalConnected || didFailTrust { return }
        didSignalConnected = true
        isOpen = true
        delegate?.connectionChanged(state: .connected)
    }

    private func failTrust(_ error: Error?) {
        if didSignalConnected || didFailTrust { return }
        didFailTrust = true
        delegate?.connectionChanged(state: .failed(error))
    }

    /// TLS 交握完成後（此時才讀得到 SecTrust）執行 pinner 驗證並送出 .connected。
    /// - returns: 是否可以繼續處理這條連線上的資料。
    @discardableResult
    private func completeHandshakeIfNeeded() -> Bool {
        if didFailTrust { return false }
        if didSignalConnected { return true }
        guard isTLS, let pinner = certPinner else {
            signalConnected()
            return true
        }

        let (trust, streamDomain) = getSecurityData()
        guard let trust = trust else {
            if pinner.overridesSystemTrustEvaluation {
                // 系統驗證已被 pinner 接管，卻又拿不到 SecTrust，
                // 這時放行等於完全沒有驗證憑證。
                failTrust(FoundationTransportError.invalidTrust)
                return false
            }
            // 系統仍在做憑證鏈驗證，失敗會走 errorOccurred。
            signalConnected()
            return true
        }

        // 優先用連線時就已知的主機名稱：stream property 常常讀不到值，
        // 傳 nil 會讓 SecPolicyCreateSSL 略過 hostname 比對。
        let domain = expectedPeerName ?? streamDomain
        var passed = false
        pinner.evaluateTrust(trust: trust, domain: domain, completion: { [weak self] (state) in
            switch state {
            case .success:
                passed = true
                self?.signalConnected()
            case .failed(let error):
                self?.failTrust(error)
            }
        })
        return passed
    }

    open func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable:
            if aStream == inputStream {
                guard completeHandshakeIfNeeded() else { break }
                read()
            }
        case .hasSpaceAvailable:
            // TLS 交握完成後才會有可寫空間，這裡是驗證憑證最早、也最可靠的時機。
            if aStream == outputStream {
                completeHandshakeIfNeeded()
            }
        case .errorOccurred:
            if !didFailTrust {
                delegate?.connectionChanged(state: .failed(aStream.streamError))
            }
        case .endEncountered:
            if aStream == inputStream {
                delegate?.connectionChanged(state: .cancelled)
            }
        case .openCompleted:
            // TLS 的交握要到 openCompleted 之後才完成，此時還讀不到 SecTrust，
            // 因此 TLS 連線一律延到 hasSpaceAvailable / hasBytesAvailable 再驗證。
            if aStream == inputStream && !isTLS {
                signalConnected()
            }
        default:
            break
        }
    }
}
