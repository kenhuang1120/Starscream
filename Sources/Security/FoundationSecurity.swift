//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  FoundationSecurity.swift
//  Starscream
//
//  Created by Dalton Cherry on 3/16/19.
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

public enum FoundationSecurityError: Error {
    case invalidRequest
}

public class FoundationSecurity  {
    /// 接受無法追溯到受信任根憑證的伺服器憑證（自簽、私有 CA）。
    /// 注意：hostname 與有效期限「仍會」被驗證，但攻擊者只要自簽一張
    /// 對應主機名稱的憑證就能通過，因此僅適用於內部/測試環境。
    let allowSelfSigned: Bool
    /// 對清單內的主機完全略過憑證驗證。這是最寬鬆的逃生門，
    /// 用於「以 IP 直連且憑證沒有對應 SAN」這類無法靠 hostname 比對的情境。
    let allowCredentialHosts: [String]
    
    public init(allowSelfSigned: Bool = false, allowCredentialHosts: [String] = []) {
        self.allowSelfSigned = allowSelfSigned
        self.allowCredentialHosts = allowCredentialHosts
    }
}

extension FoundationSecurity: CertificatePinning {
    /// 只有在被要求接受自簽憑證、或設定了略過驗證的主機清單時，才需要接管系統驗證。
    /// 其餘情況一律讓系統先做完整的憑證鏈驗證，這裡再做一次確認。
    public var overridesSystemTrustEvaluation: Bool {
        return allowSelfSigned || !allowCredentialHosts.isEmpty
    }

    public func evaluateTrust(trust: SecTrust, domain: String?, completion: ((PinningState) -> ())) {
        // 明確列出的主機完全略過驗證。這是唯一的完全放行路徑，
        // 且限縮在呼叫端寫死的清單內。
        if let domain = domain, allowCredentialHosts.contains(domain) {
            completion(.success)
            return
        }

        // 其餘一律先做完整驗證：憑證鏈 + hostname + 有效期限。
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, domain as NSString?))
        var systemError: CFError?
        if evaluate(trust: trust, error: &systemError) {
            completion(.success)
            return
        }

        // 系統驗證沒過。允許自簽時，只放行「憑證鏈無法追溯到受信任的根」這一類失敗；
        // hostname 不符、憑證過期、金鑰強度不足等一律照樣擋下。
        guard allowSelfSigned, failuresAreChainTrustOnly(trust) else {
            completion(.failed(systemError))
            return
        }
        completion(.success)
    }

    /// allowSelfSigned 可以放行的失敗項目。
    private static let chainTrustFailures: Set<String> = [
        "AnchorTrusted",       // 根憑證不在信任清單內（自簽、私有 CA）
        "MissingIntermediate", // 憑證鏈不完整，也就是 -9807 的常見成因
        "ServerAuthEKU",       // 自簽憑證常常沒有 serverAuth 的 EKU 擴充
        "StatusCodes"          // 只是彙總資訊，不是獨立的失敗項目
    ]

    /// 這次評估的失敗是否「只」跟憑證鏈信任有關。
    private func failuresAreChainTrustOnly(_ trust: SecTrust) -> Bool {
        // kSecTrustResultDetails 沒有導出到 Swift，因此直接用它的字串值。
        guard let result = SecTrustCopyResult(trust) as? [String: Any],
              let details = result["TrustResultDetails"] as? [[String: Any]] else {
            return false // 讀不到細節就不放行
        }
        for certDetail in details {
            for key in certDetail.keys where !FoundationSecurity.chainTrustFailures.contains(key) {
                return false
            }
        }
        return true
    }

    private func evaluate(trust: SecTrust, error: inout CFError?) -> Bool {
        if #available(iOS 12.0, OSX 10.14, watchOS 5.0, tvOS 12.0, *) {
            return SecTrustEvaluateWithError(trust, &error)
        }
        var result: SecTrustResultType = .unspecified
        SecTrustEvaluate(trust, &result)
        if result == .unspecified || result == .proceed {
            return true
        }
        error = CFErrorCreate(kCFAllocatorDefault, "FoundationSecurityError" as NSString?, Int(result.rawValue), nil)
        return false
    }
    
}

extension FoundationSecurity: HeaderValidator {
    public func validate(headers: [String: String], key: String) -> Error? {
        func failure(_ message: String) -> Error {
            return WSError(type: .securityError, message: message, code: SecurityErrorCode.acceptFailed.rawValue)
        }

        // RFC 6455 §4.1：缺少 Sec-WebSocket-Accept 一律視為握手失敗。
        // 先前缺少時直接放行，等於任何回 101 的伺服器都能冒充 WebSocket。
        guard let acceptKey = headers.valueForHTTPHeader(HTTPWSHeader.acceptName) else {
            return failure("missing \(HTTPWSHeader.acceptName) header")
        }
        let sha = HTTPWSHeader.acceptValue(for: key)
        guard sha == acceptKey else {
            return failure("accept header doesn't match")
        }

        // 同樣依 RFC 6455 §4.1 確認這確實是一次 WebSocket 升級。
        guard headers.valueForHTTPHeader(HTTPWSHeader.upgradeName)?.lowercased() == HTTPWSHeader.upgradeValue else {
            return failure("invalid \(HTTPWSHeader.upgradeName) header")
        }
        // Connection 可能是 "Upgrade"，也可能是 "keep-alive, Upgrade"。
        guard headers.valueForHTTPHeader(HTTPWSHeader.connectionName)?
                .lowercased()
                .contains(HTTPWSHeader.connectionValue.lowercased()) == true else {
            return failure("invalid \(HTTPWSHeader.connectionName) header")
        }
        return nil
    }
}

