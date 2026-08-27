# WebSocketEvent 參考

`WebSocketEvent`（`Sources/Starscream/WebSocket.swift:77`）是 Starscream 對外唯一的事件通道。
所有連線狀態、收到的訊息、錯誤都經由它送出，共 11 個 case。

> **最重要的前提**：哪些事件會實際出現，取決於你用哪個 engine。
> 用預設設定（iOS 13+ 走 `NativeEngine`）時，11 個 case 裡有 6 個永遠不會觸發。
> 詳見［引擎對照表］(#引擎對照表)。

---

## 目錄

- [事件如何送達](#事件如何送達)
- [各事件詳解](#各事件詳解)
- [引擎對照表](#引擎對照表)
- [典型事件時序](#典型事件時序)
- [Keep-alive](#keep-alive)
- [常見陷阱](#常見陷阱)
- [重連骨架](#重連骨架)

---

## 事件如何送達

```swift
// Sources/Starscream/WebSocket.swift:171
public func didReceive(event: WebSocketEvent) {
    callbackQueue.async { [weak self] in
        guard let s = self else { return }
        s.delegate?.didReceive(event: event, client: s)
        s.onEvent?(event)
    }
}
```

三個要點：

1. **`callbackQueue` 預設是 `DispatchQueue.main`**。高頻訊息會直接佔用主執行緒，
   必要時換成自己的 serial queue（但更新 UI 時要自己切回 main）。
2. **`delegate` 與 `onEvent` 兩者都會被呼叫**。同時設定的話，每個事件會被處理兩次。
3. 事件是非同步送出的，`connect()` 回來時連線還沒建立。

---

## 各事件詳解

### `connected([String: String])`

握手完成，可以開始收送資料。

字典內容**兩個引擎差異很大**：

| Engine | 內容 |
|---|---|
| `WSEngine` | 伺服器 101 回應的**完整 HTTP header**（`WSEngine.swift:221`） |
| `NativeEngine` | 只有一個 key `Sec-WebSocket-Protocol`，值是協商出的子協定，沒協商就是空字串（`NativeEngine.swift:268`） |

如果你的服務靠回應 header 傳遞資訊（例如 session id、伺服器版本），
用預設的 `NativeEngine` **拿不到**，必須改用 `WSEngine`。

```swift
case .connected(let headers):
    // WSEngine 才讀得到
    let sessionId = headers["X-Session-Id"]
```

---

### `disconnected(String, UInt16)`

**對方走了正常的 WebSocket 關閉交握**，也就是送了 close frame（opcode `0x8`）。

- `String` — 關閉原因，取自 close frame payload 的 UTF-8 文字。
  解不出文字時 `WSEngine` 會給 `"connection closed by server"`，
  並把 code 改成 `1002`（`FrameCollector.swift:51-57`）。
- `UInt16` — RFC 6455 close code。

`WSEngine` 收到後會自己也回一個 close frame 把交握補完（`WSEngine.swift:257-258`）。

常見 close code（`CloseCode`，`Framer.swift:38`）：

| Code | 名稱 | 意義 |
|---|---|---|
| 1000 | `normal` | 正常關閉 |
| 1001 | `goingAway` | 伺服器關機或用戶端離開頁面 |
| 1002 | `protocolError` | 協定錯誤 |
| 1003 | `protocolUnhandledType` | 收到不支援的資料型別 |
| 1005 | `noStatusReceived` | 對方沒給 close code |
| 1007 | `encoding` | payload 不是合法 UTF-8 |
| 1008 | `policyViolated` | 違反伺服器政策 |
| 1009 | `messageTooBig` | 訊息超過大小上限 |

---

### `text(String)` / `binary(Data)`

**一則完整訊息**，不是單一 frame。到達時已經：

- 組完所有 fragment（continuation frame）
- 完成 `permessage-deflate` 解壓縮

是 `text` 還是 `binary` 由**第一個 frame 的 opcode** 決定，後續 continuation frame 不影響判定。

`WSEngine` 會驗證 text 訊息是否為合法 UTF-8，不合法時改發 `error`（code 1007）而不是 `text`。

---

### `ping(Data?)` / `pong(Data?)`

> ⚠️ **只有 `WSEngine` 會發，`NativeEngine` 完全不發。**
> `URLSession` 自己處理 ping/pong，不對外暴露。

- **`ping`** — 收到對方送來的 ping。
  `respondToPingWithPong`（預設 `true`）會自動回 pong，
  所以通常你不需要做任何事。
- **`pong`** — 收到對方回應你的 ping，或 unsolicited pong。
  `WSEngine` 內建的 keep-alive 每 `pingInterval` 秒會自動送一次 ping，
  收到 pong 就取消逾時看門狗；你會同時看到這些 `pong` 事件。

payload 可能是 `nil` 或空 `Data`。

`WebSocket.respondToPingWithPong`（`WebSocket.swift:103`）在非 `WSEngine` 的情況下，
**setter 會靜默失效、getter 永遠回 `true`**：

```swift
set { guard let e = engine as? WSEngine else { return }   // NativeEngine：什麼都不做
      e.respondToPingWithPong = newValue }
get { guard let e = engine as? WSEngine else { return true }  // NativeEngine：永遠 true
      return e.respondToPingWithPong }
```

---

### `error(Error?)`

最雜的一個 case，來源包括：

| 來源 | 型別 |
|---|---|
| TLS / 憑證驗證失敗 | `NSError`（`-1202` 等）或 `CFError` |
| 握手驗證失敗 | `WSError(type: .securityError, code: 1)` |
| 協定錯誤（frame 格式、UTF-8、大小超限） | `WSError(type: .protocolError, code: 1002/1007/1009)` |
| 壓縮／解壓縮失敗 | `WSError(type: .compressionError)` |
| `URLSession` 錯誤（`NativeEngine`） | `NSError`（`-1005` 網路中斷、`-1001` 逾時…） |
| pong 逾時（`NativeEngine`） | `WSError(type: .protocolError)` |

**關鍵語意：收到 `error` 時連線已經被關掉了。**
`WSEngine.handleError`（`WSEngine.swift:270-278`）是**先 `stop()` 再發事件**，
不是「出錯了但還能繼續用」。這是重連邏輯的主要觸發點。

```swift
case .error(let error):
    if let ws = error as? WSError {
        // ws.type    : .protocolError / .securityError / .compressionError / .serverError
        // ws.code    : RFC 6455 close code
        // ws.message : 可讀訊息
    } else if let ns = error as? NSError {
        // NativeEngine 的 URLSession 錯誤
    }
    // 注意 error 是 Optional，可能為 nil
```

---

### `viabilityChanged(Bool)`

> ⚠️ **只有 `TCPTransport` 會發。**

來自 Network.framework 的 `NWConnection.viabilityUpdateHandler`（`TCPTransport.swift:181`）。

意思是**「這條連線目前還有沒有可用的網路路徑」**，不是斷線通知。

`false` 代表路徑暫時不通（Wi-Fi 掉線、進電梯或隧道），但連線物件**沒有被關閉**；
路徑恢復時會再收到 `true`，同一條連線可以繼續使用。

建議做法：

```swift
case .viabilityChanged(let isViable):
    if isViable {
        cancelViabilityTimeout()
    } else {
        // 短暫抖動很常見，先不要急著 forceDisconnect
        startViabilityTimeout(seconds: 20)   // 持續不通才主動重連
    }
```

⚠️ viability 回 `true` **不保證 WebSocket 那一層還活著**——伺服器可能早就在另一端關掉了。
那一層要靠 ping/pong watchdog 偵測。

---

### `reconnectSuggested(Bool)`

> ⚠️ **只有 `TCPTransport` 會發。**

來自 `NWConnection.betterPathUpdateHandler`（`TCPTransport.swift:185`）。

意思是**「出現了更好的網路路徑」**，例如原本走行動網路，中途連上了 Wi-Fi。
此時原連線其實還好好的，要不要重連換過去是你的選擇。

與 `viabilityChanged` 的差別：

| 事件 | 意義 |
|---|---|
| `viabilityChanged(false)` | 現在這條路不通了 |
| `reconnectSuggested(true)` | 有更好的路，可以考慮換 |

---

### `cancelled`

Transport 被取消，通常是**你自己呼叫 `disconnect()` / `forceDisconnect()`** 的結果，
或 `FoundationTransport` 讀到 stream 結束（`endEncountered`）。

`NativeEngine` 不發這個事件。

---

### `peerClosed`

> ⚠️ **只有 `TCPTransport` 會發**（`TCPTransport.swift` 的 readLoop）。

TCP 層收到 FIN，也就是**對方直接關掉 socket，沒有走 WebSocket 的 close 交握**。

與 `disconnected` 的差別很實際：

| 事件 | 情境 |
|---|---|
| `disconnected` | 有禮貌的告別（收到 close frame） |
| `peerClosed` | 線被拔掉（伺服器崩潰、中間層回收連線、LB 逾時） |

---

## 引擎對照表

| 事件 | `NativeEngine`<br>（iOS 13+ 預設） | `WSEngine`<br>`+ TCPTransport` | `WSEngine`<br>`+ FoundationTransport` |
|---|:--:|:--:|:--:|
| `connected` | ✅ 僅子協定 | ✅ 完整 header | ✅ 完整 header |
| `disconnected` | ✅ | ✅ | ✅ |
| `text` / `binary` | ✅ | ✅ | ✅ |
| `error` | ✅ | ✅ | ✅ |
| `ping` / `pong` | ❌ | ✅ | ✅ |
| `cancelled` | ❌ | ✅ | ✅ |
| `peerClosed` | ❌ | ✅ | ❌ |
| `viabilityChanged` | ❌ | ✅ | ❌ |
| `reconnectSuggested` | ❌ | ✅ | ❌ |

如何選擇 engine：

```swift
// 預設：iOS 13+ 走 NativeEngine，有內建 ping/pong keep-alive
WebSocket(request: req)

// 明確指定 NativeEngine 並調整 keep-alive 參數
WebSocket(request: req,
          engine: NativeEngine(pingInterval: 15, pongTimeout: 8))

// 走 WSEngine：拿得到完整 header、ping/pong 事件、
// 以及 maxMessageSize / cookieStorage / tlsPeerName 等設定
WebSocket(request: req, transport: TCPTransport())

// WSEngine 也有同一套 keep-alive，參數名稱與 NativeEngine 相同
WebSocket(request: req,
          engine: WSEngine(transport: TCPTransport(),
                           pingInterval: 15, pongTimeout: 8))
```

---

## 典型事件時序

**正常連線與關閉**

```
connect()
  → connected(headers)
  → text / binary ...
disconnect()
  → disconnected("", 1000)
  → cancelled
```

**伺服器主動關閉**

```
  → connected(headers)
  → text / binary ...
  → disconnected("going away", 1001)
```

**網路中斷（TCPTransport）**

```
  → connected(headers)
  → viabilityChanged(false)      // 路徑不通
  → error(...)  或  peerClosed   // 視斷法而定
```

**憑證驗證失敗**

```
connect()
  → error(-1202 / errSSLXCertChainInvalid)
  // 不會有 connected，也不會有 disconnected
```

**App 進背景後被系統收掉**

```
  → connected(headers)
  ...（進背景）
  → error(...)  或  cancelled
  ...（回前景）
  connect()                       // 必須自己觸發
  → connected(headers)
```

---

## Keep-alive

兩個 engine 都內建同一套 keep-alive，參數與語意一致：

| 參數 | 預設 | 說明 |
|---|---|---|
| `pingInterval` | `30` 秒 | 每隔多久送一次 ping。設 `0` 以下表示關閉 |
| `pongTimeout` | `10` 秒 | 送出 ping 後等待 pong 的上限，逾時視為連線已死 |

實作要點：

- 用掛在自有 queue 上的 `DispatchSourceTimer`，**不是** main run loop 的 `Timer`。
  App 進背景後 run loop 會停擺、UI 捲動時 run loop 進入 `.tracking` mode，
  用 `Timer` 的話兩種情況都不會送出 ping。
- 逾時後會發出 `error(WSError(type: .protocolError))`（訊息含 `"pong"`）並關閉連線，
  也就是會走到你的重連邏輯。
- 上一個 ping 還在等 pong 時**不會**重新計時。否則只要 `pingInterval < pongTimeout`，
  每次 ping 都把看門狗往後推，逾時就永遠不會觸發。

> `pingInterval` 要小於伺服器或中間層（LB、NAT）的 idle timeout，否則連線
> 會在兩次 ping 之間被回收。多數環境 15～30 秒是安全值。

---

## 常見陷阱

### 1. 不是每次結束都有 `disconnected`

`disconnected` 只在**收到 close frame** 時發出。網路斷線、TLS 失敗、伺服器崩潰
通常只給 `error` 或 `peerClosed`。

重連邏輯若只監聽 `disconnected`，會漏掉大部分斷線情況。

### 2. `cancelled` 是你自己造成的

要能區分「使用者主動離開」與「意外斷線」，否則使用者按下離開後會被自動連回去。
建議自己維護一個旗標。

### 3. `error` 代表連線已死

不要在收到 `error` 後繼續呼叫 `write()`——那些呼叫會被靜默丟棄。

### 4. `callbackQueue` 預設在主執行緒

高頻訊息會影響 UI 流暢度。

### 5. `delegate` 與 `onEvent` 會同時觸發

兩個都設的話，記得只在其中一個處理業務邏輯。

### 6. 這個函式庫沒有內建自動重連

`WebSocket` 不會自己重連，必須由你在事件處理裡呼叫 `connect()`。

---

## 重連骨架

```swift
final class SocketController {
    private let url: URL
    private var socket: WebSocket?
    private var isManualDisconnect = false
    private var retryCount = 0

    init(url: URL) {
        self.url = url
    }

    func connect() {
        isManualDisconnect = false
        var req = URLRequest(url: url)
        req.timeoutInterval = 10

        let socket = WebSocket(request: req,
                               engine: NativeEngine(pingInterval: 15, pongTimeout: 8))
        socket.callbackQueue = .main
        socket.onEvent = { [weak self] event in self?.handle(event) }
        self.socket = socket
        socket.connect()
    }

    func disconnect() {
        isManualDisconnect = true
        socket?.disconnect()
    }

    private func handle(_ event: WebSocketEvent) {
        switch event {
        case .connected:
            retryCount = 0

        case .text(let string):
            // 處理訊息
            _ = string

        case .binary(let data):
            _ = data

        // 涵蓋所有的結束路徑
        case .disconnected, .peerClosed, .cancelled, .error:
            scheduleReconnect()

        case .viabilityChanged(let isViable):
            // 路徑不通時先等，不要立刻重連
            if !isViable { /* 顯示「連線中」UI */ }

        case .reconnectSuggested(let isBetter):
            if isBetter { reconnectNow() }

        case .ping, .pong:
            break   // keep-alive 自動處理，通常不需要介入
        }
    }

    private func scheduleReconnect() {
        guard !isManualDisconnect else { return }
        retryCount += 1
        // 指數退避，並加上抖動避免所有 client 同時重連
        let delay = min(pow(2.0, Double(retryCount)), 30) + Double.random(in: 0...1)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connect()
        }
    }

    private func reconnectNow() {
        socket?.forceDisconnect()
        connect()
    }
}
```

搭配 App 生命週期：

```swift
NotificationCenter.default.addObserver(
    forName: UIApplication.willEnterForegroundNotification,
    object: nil, queue: .main) { [weak self] _ in
        self?.reconnectNow()   // 回前景一律重建連線
}
```

> iOS 掛起 App 之後，一般 `URLSession` 的 WebSocket **一定**會斷，這是系統行為。
> 正確做法是回前景時主動重連，而不是期待連線能撐過背景。
