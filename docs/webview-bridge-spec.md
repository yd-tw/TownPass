# Town Pass WebView 整合規格書

> 對象：在 Town Pass App 內以 WebView 開啟的網頁服務（例如論壇 `https://tp2026.ydtw.net/`）
> 依據：Town Pass `main` 分支原始碼（App 版本 0.0.12）
> 程式位置：`lib/util/web_message_handler/`、`lib/util/tp_web_view.dart`

---

## 1. 概觀

App 以 `flutter_inappwebview` 開啟網頁，並在頁面中注入一個全域 JS 物件 **`flutterObject`**。網頁透過它與 App 雙向溝通：

```
網頁  ── flutterObject.postMessage(JSON 字串) ──▶  App（依 name 分派給對應 handler）
網頁  ◀── flutterObject.onmessage (event.data = JSON 字串) ──  App 回覆
```

- App **不會**在網址上附加任何參數（沒有 query string、沒有 token），所有資料都要由網頁主動透過 `flutterObject` 索取。
- 目前**沒有網域白名單**：任何在 App WebView 內載入的頁面（含 iframe）都能呼叫所有功能。

---

## 2. 訊息格式

### 2.1 網頁 → App（請求）

必須是 **JSON 字串**（App 端會 `jsonDecode`，傳物件或非 JSON 字串會失敗）：

```json
{ "name": "<功能名稱>", "data": <參數，可為 null / 字串 / 物件> }
```

### 2.2 App → 網頁（回覆）

`event.data` 是 **JSON 字串**，需自行 `JSON.parse`：

```json
{ "name": "<功能名稱>", "data": <結果> }
```

- 回覆的 `name` 與請求相同，**所有功能的回覆都從同一個 `onmessage` 進來**，請依 `name` 分派。
- 回覆沒有 request id，同一功能同時發多個請求時無法區分是哪一次的回覆，建議同一功能一次只發一個。
- 部分功能在某些情況**不會回覆**（見各功能說明），請自行加上逾時處理。

---

## 3. 網頁端範例（建議直接複製使用）

```js
// townpass-bridge.js
const pending = new Map(); // name -> { resolve, timer }

function isInTownPass() {
  return typeof window.flutterObject !== 'undefined';
}

function initBridge() {
  if (!isInTownPass()) return;
  window.flutterObject.onmessage = (event) => {
    let msg;
    try {
      msg = JSON.parse(event.data);
    } catch {
      return;
    }
    const p = pending.get(msg.name);
    if (p) {
      clearTimeout(p.timer);
      pending.delete(msg.name);
      p.resolve(msg.data);
    }
  };
}

/**
 * 呼叫 App 功能
 * @param {string} name 功能名稱
 * @param {any} data 參數
 * @param {number} timeoutMs 逾時（毫秒），逾時 resolve(undefined)
 */
function callApp(name, data = null, timeoutMs = 10000) {
  if (!isInTownPass()) return Promise.reject(new Error('not in Town Pass app'));
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      pending.delete(name);
      resolve(undefined);
    }, timeoutMs);
    pending.set(name, { resolve, timer });
    window.flutterObject.postMessage(JSON.stringify({ name, data }));
  });
}

initBridge();

// 使用範例
// const user = await callApp('userinfo');
// const pos  = await callApp('location', null, 20000);
```

> `flutterObject` 在頁面載入時即已注入（document start），一般在 `DOMContentLoaded` 之後呼叫即可。
> 在一般瀏覽器開啟時 `flutterObject` 不存在，請用 `isInTownPass()` 判斷並提供替代流程。

---

## 4. 功能清單

| name | 用途 | 請求 data | 回覆 data |
|---|---|---|---|
| `userinfo` | 取得使用者資料 | `null` | 帳號物件，見 4.1 |
| `location` | 取得 GPS 定位 | `null` | 定位物件或 `[]`，見 4.2 |
| `deviceinfo` | 取得裝置資訊 | `null` | 裝置資訊物件，見 4.3 |
| `qr_code_scan` | 開啟 App 掃描 QR Code | `null` | 掃描結果字串或 `null` |
| `open_link` | 由 App 開啟連結 | URL 字串 | 成功不回覆；`data` 為 null 時回 `false` |
| `launch_map` | 開啟外部地圖 / URL | URL 字串 | `true` / `false` |
| `phone_call` | 撥打電話 | 電話號碼字串 | `true` / `false` |
| `1999agree` | 撥打 1999（含使用者同意流程） | 任意非 null 值 | 失敗回 `false`；成功不回覆 |
| `notify` | 顯示系統通知 | `{ title, content, url? }` | 成功不回覆；格式錯誤回 `false` |
| `push_token` | 取得 FCM 推播 token | `null` | `{ token, platform }` 或 `null`，見 [fcm-push-spec.md](./fcm-push-spec.md) |
| `report_draft` | 取得問題回報草稿（僅論壇網域） | `null` | 草稿物件或 `null`，見 4.10 |

### 4.1 `userinfo`

```js
const user = await callApp('userinfo');
```

回覆範例（**目前 App 內為寫死的測試資料** `assets/mock_data/account.json`，非真實使用者）：

```json
{
  "id": "7f3562f4-bb3f-4ec7-89b9-da3b4b5ff250",
  "account": "wz7786",
  "username": "Wesley",
  "realName": "金大森",
  "idNo": "A123456789",
  "email": "ist83903@bcaoo.com",
  "phoneNo": "0932166777",
  "birthday": "1988/12/12",
  "memberType": "personal",
  "verifyLevel": "3",
  "addresses": [
    {
      "zip3": 104,
      "city": "臺北市",
      "town": "中山區",
      "village": "正得里",
      "street": "吉林路",
      "usageType": "0",
      "seq": 1,
      "priority": true
    }
  ],
  "residentAddress": "臺北市中山區吉林路 69 號 4 樓",
  "citizen": true,
  "nativePeople": false,
  "cityInternetUid": ""
}
```

| 欄位 | 型別 | 說明 |
|---|---|---|
| `id` | string | 使用者唯一 ID（UUID），**建議作為論壇帳號對應鍵** |
| `account` | string | 帳號 |
| `username` | string | 暱稱 |
| `realName` | string | 真實姓名 |
| `idNo` | string | 身分證字號 |
| `email` | string | Email |
| `phoneNo` | string | 手機號碼 |
| `birthday` | string | 生日，格式 `YYYY/MM/DD` |
| `memberType` | string | 會員類型，例 `personal` |
| `verifyLevel` | string | 驗證等級（字串型別的數字） |
| `addresses` | array | 地址清單 |
| `residentAddress` | string | 戶籍地址 |
| `citizen` | boolean | 是否為市民 |
| `nativePeople` | boolean | 是否為原住民 |
| `cityInternetUid` | string | 市民網路 UID，可能為空字串 |

- 使用者可在 App「基本資料」頁修改 `idNo`、`birthday`、`email`、`phoneNo`、地址，修改只存在記憶體，**App 重啟後會還原**。
- 若帳號不存在，`data` 會是 `[]`（空陣列），請檢查 `Array.isArray(data)`。

> ⚠️ **安全性**：這份資料沒有簽章或 token，網頁端無法驗證真偽，任何人都可以在一般瀏覽器偽造 `flutterObject` 回傳任意資料。**請勿將其當作可信的登入憑證**，正式環境需另行設計伺服器端驗證機制。

### 4.2 `location`

```js
const pos = await callApp('location', null, 20000); // 定位可能較久，建議加長逾時
if (!pos || Array.isArray(pos)) {
  // 取得失敗：定位服務未開 / 使用者拒絕權限
}
```

- 呼叫時若 App 尚未取得定位權限，會跳出 Android 系統權限視窗。
- 失敗（定位服務關閉、使用者拒絕、永久拒絕）時回覆 `data: []`，**不會提供錯誤原因**。

成功回覆欄位：

| 欄位 | 型別 | 說明 |
|---|---|---|
| `latitude` | number | 緯度 |
| `longitude` | number | 經度 |
| `accuracy` | number | 水平精度（公尺） |
| `altitude` | number | 海拔（公尺） |
| `altitude_accuracy` | number | 海拔精度 |
| `heading` | number | 方向（度） |
| `heading_accuracy` | number | 方向精度 |
| `speed` | number | 速度（m/s） |
| `speed_accuracy` | number | 速度精度 |
| `timestamp` | number | 時間戳（毫秒 epoch） |
| `floor` | number \| null | 樓層 |
| `is_mocked` | boolean | 是否為模擬定位 |
| `vertical_speed` / `vertical_speed_accuracy` | number | 垂直速度與精度 |
| `has_*` | boolean | 各欄位是否有效（如 `has_accuracy`、`has_speed`） |

#### 替代方式：標準 Geolocation API

App 對網頁的 `navigator.geolocation` 請求一律**自動允許**（不會出現網頁層級提示），因此也可直接使用：

```js
navigator.geolocation.getCurrentPosition(
  (p) => console.log(p.coords.latitude, p.coords.longitude),
  (err) => console.error(err),
  { enableHighAccuracy: true, timeout: 20000 }
);
```

仍需 App 已取得 Android 定位權限才會成功。好處是網頁在一般瀏覽器也能用同一套程式。

### 4.3 `deviceinfo`

回覆 `device_info_plus` 套件的原始裝置資訊。Android 上主要欄位包含：`brand`、`manufacturer`、`model`、`device`、`product`、`id`、`version`（含 `release`、`sdkInt`）、`isPhysicalDevice`、`supportedAbis` 等。欄位隨平台（Android / iOS）不同，請以實測為準，不要依賴固定結構。

### 4.4 `qr_code_scan`

```js
const text = await callApp('qr_code_scan', null, 120000); // 使用者操作時間長，逾時要設長
```

開啟 App 原生掃描頁，回覆掃到的字串；使用者按返回取消時回覆 `null`。

### 4.5 `open_link`

```js
flutterObject.postMessage(JSON.stringify({ name: 'open_link', data: 'https://example.com' }));
```

- 一般網址：在 App 內**另開一個新的 WebView 頁面**（新頁面一樣有 `flutterObject`）。
- `local://<route>`：開啟 App 內建頁面，例如 `local://online_police`。
- 成功時**不回覆**，請不要 await 等待結果。

### 4.6 `launch_map`

`data` 為 URL 字串（例如 `https://www.google.com/maps/search/?api=1&query=25.04,121.56` 或 `geo:25.04,121.56`），App 以外部應用程式開啟，回覆是否能開啟。

### 4.7 `phone_call`

`data` 為電話號碼字串（例如 `"0223456789"`），App 開啟撥號畫面並回覆是否能撥打。

### 4.8 `1999agree`

撥打 1999 市民熱線。首次使用會先導向 App 內的同意條款頁；同意後顯示撥號對話框。使用者不同意或裝置無法撥號時回覆 `false`，其餘情況**不回覆**。

### 4.9 `notify`

```js
flutterObject.postMessage(JSON.stringify({
  name: 'notify',
  data: { title: '論壇', content: '有人回覆了你的文章' },
}));
```

- 顯示 Android 系統通知。`title`、`content` 皆須為字串。
- 特殊行為：`content` 符合 `已訂閱XXX` 時，App 會把 `XXX` 加入「訂閱」清單；符合 `已取消訂閱XXX` 時移除。一般通知請避免使用這兩種字樣。

### 4.10 `report_draft`（問題回報）

使用者在 App 任一畫面按左下角 🐞（或長按「論壇」按鈕）→ 預覽確認 → 「送到論壇」後，App 開啟 `https://tp2026.ydtw.net/new?source=app-report`。論壇偵測到 `source=app-report` 時呼叫：

```js
const draft = await callApp('report_draft');
if (draft) {
  // 填入發文表單；圖片轉為 Blob 上傳
  const blob = draft.image ? await (await fetch(draft.image)).blob() : null;
}
```

回覆範例：

```json
{
  "id": "1ce602be6615c442396cf53bbe853e96",
  "description": "按下送出沒有反應",
  "image": "data:image/png;base64,iVBORw0K...",
  "context": {
    "screen": "/account",
    "screenTitle": "帳戶",
    "route": "/account",
    "routeHistory": ["/", "/account"],
    "webUrl": null,
    "appVersion": "0.0.12",
    "platform": "android",
    "osVersion": "14",
    "deviceModel": "SM-A236E",
    "locale": "zh-Hant-TW",
    "timestamp": 1794040555730
  }
}
```

| 欄位 | 說明 |
|---|---|
| `image` | PNG data URL；使用者關閉「附上截圖」時為 `null`。個資已遮蔽（App 原生畫面以色塊、網頁以模糊） |
| `context.screen` | 截圖時所在畫面：一般頁面為路由（`/account`）；首頁加分頁（`/#service`、`/#home`、`/#perk`、`/#bill`）；WebView 為 `web:` + host + path，query 只保留白名單參數（論壇的 `question`，例如 `web:tp2026.ydtw.net/?question=12`）；開著對話框或底部彈窗時結尾加 `+dialog` / `+sheet`。舊版 App 沒有此欄位 |
| `context.screenTitle` | 截圖時標題列的文字；首頁為分頁名稱，WebView 為網頁 `<title>`；取不到時為 `null` |
| `context.route` / `routeHistory` | 回報時所在的 App 頁面與最近 10 次頁面切換 |
| `context.webUrl` | 回報時所在 WebView 的網址，只保留 scheme、host、path（去除 query 與 hash） |

- **只有論壇網域**（`tp2026.ydtw.net`）可讀取，其他網域一律回 `null`。
- **只能讀一次**，讀取後即從 App 記憶體刪除；送出後 10 分鐘未讀取也會作廢。
- 論壇自己的頁面請在個資元素加上 `data-sensitive` 屬性，截圖時會被模糊。

---

## 5. 已知限制與注意事項

1. **`data` 為 null 的處理不完整**：`launch_map`、`phone_call` 傳 `data: null` 時，App 會先回 `false` 再繼續執行而發生例外。請一律傳有效字串。
2. **無請求 ID**：同名功能並行呼叫時回覆無法對應，請序列化呼叫。
3. **無網域限制**：所有在 App WebView 內的頁面與 iframe 都能取得使用者個資與定位，嵌入第三方內容（廣告、外部 iframe）時請特別注意。
4. **測試資料**：目前 `userinfo` 永遠回傳同一筆假帳號，所有測試手機上的「使用者」都是同一人。
5. **WebView 行為**：App 標題列預設顯示網頁 `<title>`；App 返回鍵會先執行網頁的上一頁，無上一頁才關閉 WebView。
6. **麥克風（`getUserMedia`）**：只有論壇網域可以使用，且只開放 `{ audio: true }`，要求鏡頭或其他網域一律拒絕。網頁第一次要求時 App 會跳出系統權限詢問；使用者拒絕時 `getUserMedia` 會丟出 `NotAllowedError`，網頁要自行處理。實作見 `lib/util/tp_web_view.dart` 的 `_canGrant`，寫法見 [`forum-web-guide.md`](./forum-web-guide.md) §3.3。

---

## 6. 測試方式

### 6.1 在 App 內測試

1. 裝好 App 後，首頁「釘選服務」點「論壇」，或在服務列表的「其他服務」中找到「論壇」。
2. 電腦連接手機（USB 偵錯），Chrome 開啟 `chrome://inspect/#devices`，即可對 App 內的 WebView 下中斷點、看 console。
   - 只有 **debug 版**可以被 inspect（`flutter_inappwebview` 預設只在 debug 模式開啟 WebView 偵錯）。目前裝在手機上的 release 版 APK 看不到，請改用 `flutter run` 安裝 debug 版。
3. 在 console 直接測試：

```js
flutterObject.onmessage = (e) => console.log(JSON.parse(e.data));
flutterObject.postMessage(JSON.stringify({ name: 'userinfo', data: null }));
flutterObject.postMessage(JSON.stringify({ name: 'location', data: null }));
```

### 6.2 在一般瀏覽器模擬（開發用）

在 App 外開發時，可用以下 mock 模擬 `flutterObject`，於載入 bridge 之前注入：

```js
// mock-townpass.js —— 僅限開發環境，勿部署到正式站
if (typeof window.flutterObject === 'undefined') {
  const mockData = {
    userinfo: {
      id: '7f3562f4-bb3f-4ec7-89b9-da3b4b5ff250',
      account: 'wz7786',
      username: 'Wesley',
      realName: '金大森',
      idNo: 'A123456789',
      email: 'ist83903@bcaoo.com',
      phoneNo: '0932166777',
      birthday: '1988/12/12',
      memberType: 'personal',
      verifyLevel: '3',
      addresses: [],
      residentAddress: '臺北市中山區吉林路 69 號 4 樓',
      citizen: true,
      nativePeople: false,
      cityInternetUid: '',
    },
    location: { latitude: 25.0478, longitude: 121.5170, accuracy: 10, timestamp: Date.now() },
    deviceinfo: { brand: 'mock', model: 'browser' },
    qr_code_scan: 'mock-qr-content',
    launch_map: true,
    phone_call: true,
  };
  const obj = {
    onmessage: null,
    postMessage(str) {
      const { name } = JSON.parse(str);
      if (!(name in mockData)) return;
      setTimeout(() => {
        obj.onmessage?.({ data: JSON.stringify({ name, data: mockData[name] }) });
      }, 100);
    },
  };
  window.flutterObject = obj;
}
```
