//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  HTTPHandler.swift
//  Starscream
//
//  Created by Dalton Cherry on 1/24/19.
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
import CommonCrypto

public enum HTTPUpgradeError: Error {
    case notAnUpgrade(Int, [String: String])
    case invalidData
    /// HTTP 回應的 header 超過上限，多半代表對方在灌資料。
    case headersTooLarge
}

/// 升級回應 header 的累積上限。header 收完前 buffer 是無上限成長的，
/// 伺服器可以一直送 header 卻永遠不結束。
public let DefaultMaxHTTPHeaderSize: Int = 64 * 1024

public struct HTTPWSHeader {
    static let upgradeName        = "Upgrade"
    static let upgradeValue       = "websocket"
    static let hostName           = "Host"
    static let connectionName     = "Connection"
    static let connectionValue    = "Upgrade"
    static let protocolName       = "Sec-WebSocket-Protocol"
    static let versionName        = "Sec-WebSocket-Version"
    static let versionValue       = "13"
    static let extensionName      = "Sec-WebSocket-Extensions"
    static let keyName            = "Sec-WebSocket-Key"
    static let originName         = "Origin"
    static let acceptName         = "Sec-WebSocket-Accept"
    static let switchProtocolCode = 101
    static let defaultSSLSchemes  = ["wss", "https"]
    
    /// Creates a new URLRequest based off the source URLRequest.
    /// - Parameter request: the request to "upgrade" the WebSocket request by adding headers.
    /// - Parameter supportsCompression: set if the client support text compression.
    /// - Parameter secKeyName: the security key to use in the WebSocket request. https://tools.ietf.org/html/rfc6455#section-1.3
    /// - Parameter cookieStorage: 取用 cookie 的來源。傳 nil 表示這條連線完全不帶 cookie，
    ///   傳入獨立的 storage 可以避免與 App 其他 HTTP 流量共用 cookie。
    /// - returns: A URLRequest request to be converted to data and sent to the server.
    public static func createUpgrade(request: URLRequest,
                                     supportsCompression: Bool,
                                     secKeyValue: String,
                                     cookieStorage: HTTPCookieStorage? = .shared) -> URLRequest {
        guard let url = request.url, let parts = url.getParts() else {
            return request
        }
        
        var req = request
        if request.value(forHTTPHeaderField: HTTPWSHeader.originName) == nil {
            var origin = url.absoluteString
            if let hostUrl = URL (string: "/", relativeTo: url) {
                origin = hostUrl.absoluteString
                origin.remove(at: origin.index(before: origin.endIndex))
            }
            req.setValue(origin, forHTTPHeaderField: HTTPWSHeader.originName)
        }
        req.setValue(HTTPWSHeader.upgradeValue, forHTTPHeaderField: HTTPWSHeader.upgradeName)
        req.setValue(HTTPWSHeader.connectionValue, forHTTPHeaderField: HTTPWSHeader.connectionName)
        req.setValue(HTTPWSHeader.versionValue, forHTTPHeaderField: HTTPWSHeader.versionName)
        req.setValue(secKeyValue, forHTTPHeaderField: HTTPWSHeader.keyName)
        
        if req.allHTTPHeaderFields?["Cookie"] == nil {
            if let cookies = cookieStorage?.cookies(for: url), !cookies.isEmpty {
                let headers = HTTPCookie.requestHeaderFields(with: cookies)
                for (key, val) in headers {
                    req.setValue(val, forHTTPHeaderField: key)
                }
            }
	     }
        
        if supportsCompression {
            let val = "permessage-deflate; client_max_window_bits; server_max_window_bits=15"
            req.setValue(val, forHTTPHeaderField: HTTPWSHeader.extensionName)
        }
        let hostValue = req.allHTTPHeaderFields?[HTTPWSHeader.hostName] ?? "\(parts.host):\(parts.port)"
        req.setValue(hostValue, forHTTPHeaderField: HTTPWSHeader.hostName)
        return req
    }
    
    /// generateWebSocketKey 產生 RFC 6455 §4.1 要求的 16 bytes 隨機值並回傳 base64。
    /// 先前用 `UInt8.random(in: 97...122)`，不但不是密碼學安全的亂數，
    /// 熵也只有 26^16（約 75 bits）而非要求的 128 bits。
    public static func generateWebSocketKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // 極少數情況下 SecRandomCopyBytes 會失敗，退回系統亂數而不是固定值。
            bytes = (0..<16).map { _ in UInt8.random(in: UInt8.min...UInt8.max) }
        }
        return Data(bytes).base64EncodedString()
    }

    /// 依 RFC 6455 §4.2.2，由 client 的 Sec-WebSocket-Key 算出 Sec-WebSocket-Accept。
    public static func acceptValue(for key: String) -> String {
        return "\(key)258EAFA5-E914-47DA-95CA-C5AB0DC85B11".sha1Base64()
    }
}

public extension Dictionary where Key == String, Value == String {
    /// HTTP header 名稱大小寫不敏感。StringHTTPHandler 會把 key 全部轉小寫，
    /// 直接用 headers["Sec-WebSocket-Accept"] 查會落空。
    func valueForHTTPHeader(_ name: String) -> String? {
        if let value = self[name] {
            return value
        }
        let lowercased = name.lowercased()
        return first(where: { $0.key.lowercased() == lowercased })?.value
    }
}

extension String {
    func sha1Base64() -> String {
        guard let data = self.data(using: .utf8) else {
            return ""
        }
        let digest = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> [UInt8] in
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
            CC_SHA1(bytes.baseAddress, CC_LONG(data.count), &digest)
            return digest
        }
        return Data(digest).base64EncodedString()
    }
}

public enum HTTPEvent {
    case success([String: String])
    case failure(Error)
}

public protocol HTTPHandlerDelegate: AnyObject {
    func didReceiveHTTP(event: HTTPEvent)
}

public protocol HTTPHandler {
    func register(delegate: HTTPHandlerDelegate)
    func convert(request: URLRequest) -> Data
    func parse(data: Data) -> Int
}

public protocol HTTPServerDelegate: AnyObject {
    func didReceive(event: HTTPEvent)
}

public protocol HTTPServerHandler {
    func register(delegate: HTTPServerDelegate)
    func parse(data: Data)
    func createResponse(headers: [String: String]) -> Data
}

public struct URLParts {
    let port: Int
    let host: String
    let isTLS: Bool
}

public extension URL {
    /// isTLSScheme returns true if the scheme is https or wss
    var isTLSScheme: Bool {
        guard let scheme = self.scheme else {
            return false
        }
        return HTTPWSHeader.defaultSSLSchemes.contains(scheme)
    }
    
    /// getParts pulls host and port from the url.
    func getParts() -> URLParts? {
        guard let host = self.host else {
            return nil // no host, this isn't a valid url
        }
        let isTLS = isTLSScheme
        var port = self.port ?? 0
        if self.port == nil {
            if isTLS {
                port = 443
            } else {
                port = 80
            }
        }
        return URLParts(port: port, host: host, isTLS: isTLS)
    }
}
