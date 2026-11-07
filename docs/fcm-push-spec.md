# Town Pass 推播（FCM）規格書

> 對象：論壇等在 Town Pass 內開啟的網頁服務，以及其後端
> 相關文件：[`webview-bridge-spec.md`](./webview-bridge-spec.md)（`flutterObject` 基本用法）

---

## 1. 架構

```
┌────────────┐ 1. 取得 FCM token  ┌──────────┐
│ Town Pass  │◀──────────────────▶│   FCM    │
│    App     │                    └────▲─────┘
│ ┌────────┐ │ 2. push_token           │ 4. 發送推播（HTTP v1）
│ │論壇網頁│◀┼─ flutterObject          │
│ └───┬────┘ │                    ┌────┴─────┐
└─────┼──────┘                    │ 論壇後端 │
      └── 3. 上傳 token 綁定使用者 ─▶│          │
                                  └──────────┘
5. 使用者點擊通知 → App 開啟 WebView 到 data.url
```

1. App 啟動時向 FCM 註冊，取得此裝置的 token。
2. 論壇網頁透過 `flutterObject` 呼叫 `push_token` 取得 token。
3. 網頁把 token 連同使用者識別送到論壇後端儲存。
4. 有事件（例如文章被回覆）時，論壇後端呼叫 FCM HTTP v1 API 發送推播。
5. 使用者點擊通知，App 在內建 WebView 開啟 `data.url`。

| App 狀態 | 收到推播時 | 點擊通知後 |
|---|---|---|
| 前景（正在使用） | App 以本機通知顯示 | 開啟 `data.url` |
| 背景 | 系統自動顯示 | App 回到前景並開啟 `data.url` |
| 完全關閉 | 系統自動顯示 | 啟動 App 後開啟 `data.url` |

---

## 2. 網頁端

### 2.1 取得 token：`push_token`

```js
const res = await callApp('push_token'); // callApp 見 webview-bridge-spec.md
// res = { token: "fcm-token...", platform: "android" }
// 推播未啟用或取得失敗時：res = null
```

| 欄位 | 型別 | 說明 |
|---|---|---|
| `token` | string | FCM 註冊 token |
| `platform` | string | `android` 或 `ios` |

### 2.2 上傳時機

token 可能因為重新安裝 App、清除資料、FCM 輪替而**改變**，且 App 無法主動通知網頁。請：

- **每次載入論壇頁面**（或使用者登入後）都呼叫 `push_token`，並 upsert 到後端。
- 後端以 token 為唯一鍵，同一使用者可有多個 token（多支手機）。

```js
async function syncPushToken(userId) {
  const res = await callApp('push_token');
  if (!res?.token) return;
  await fetch('/api/push-tokens', {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ userId, token: res.token, platform: res.platform }),
  });
}
```

### 2.3 `notify` 新增 `url`（向下相容）

頁面開著時的即時通知可帶 `url`，點擊後同樣會開啟該網址：

```js
flutterObject.postMessage(JSON.stringify({
  name: 'notify',
  data: { title: '論壇', content: '有人回覆了你的文章', url: 'https://tp2026.ydtw.net/t/123' },
}));
```

---

## 3. 後端

### 3.1 資料表建議

```sql
CREATE TABLE push_tokens (
  token       TEXT PRIMARY KEY,
  user_id     TEXT NOT NULL,       -- 對應 userinfo.id
  platform    TEXT NOT NULL,       -- android / ios
  updated_at  TIMESTAMP NOT NULL
);
CREATE INDEX ON push_tokens (user_id);
```

### 3.2 發送推播（FCM HTTP v1）

```
POST https://fcm.googleapis.com/v1/projects/{FIREBASE_PROJECT_ID}/messages:send
Authorization: Bearer {OAuth2 access token，scope: https://www.googleapis.com/auth/firebase.messaging}
Content-Type: application/json
```

```json
{
  "message": {
    "token": "<FCM token>",
    "notification": {
      "title": "論壇",
      "body": "王小明回覆了你的文章「如何申辦…」"
    },
    "data": {
      "url": "https://tp2026.ydtw.net/t/123#post-5"
    },
    "android": {
      "priority": "HIGH",
      "notification": {
        "channel_id": "TownPass android notification id"
      }
    }
  }
}
```

| 欄位 | 必填 | 說明 |
|---|---|---|
| `notification.title` / `body` | ✅ | 通知標題與內文。**一定要放在 `notification`**，App 在背景或關閉時系統才會自動顯示 |
| `data.url` | 選填 | 點擊後開啟的網址（`https://…`）或 App 內頁（`local://…`）。`data` 的值必須都是字串 |
| `android.notification.channel_id` | 建議 | 固定為 `TownPass android notification id`，與 App 本機通知同一個通道 |
| `android.priority` | 建議 | `HIGH` 才會即時送達並彈出 |

- OAuth token 用 Firebase 專案的**服務帳戶金鑰**產生（Firebase 主控台 → 專案設定 → 服務帳戶 → 產生新的私密金鑰）。建議直接用官方 Admin SDK（Node.js `firebase-admin`、Python `firebase-admin`），它會處理 OAuth：

```js
// Node.js
import admin from 'firebase-admin';
admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });

await admin.messaging().send({
  token,
  notification: { title: '論壇', body: '有人回覆了你的文章' },
  data: { url: 'https://tp2026.ydtw.net/t/123' },
  android: { priority: 'high', notification: { channelId: 'TownPass android notification id' } },
});
```

- **服務帳戶金鑰只能放在後端**，絕對不可放進網頁或 App。

### 3.3 錯誤處理

| FCM 回應 | 意義 | 處理 |
|---|---|---|
| `404 UNREGISTERED` | token 已失效（App 被移除等） | 從資料表刪除該 token |
| `400 INVALID_ARGUMENT` | token 格式錯誤或 payload 錯誤 | 檢查 payload；若是 token 問題則刪除 |
| `429` / `503` | 流量限制 / 服務暫時不可用 | 指數退避後重試 |
| `401` / `403` | 金鑰或權限錯誤 | 檢查服務帳戶設定 |

---

## 4. 安全性注意事項

- `push_token` 和 `userinfo` 一樣**沒有網域限制**，任何在 App 內開啟的頁面都拿得到 token。token 本身無法用來發送推播（需要服務帳戶金鑰），風險有限，但仍建議日後加上網域白名單。
- 目前 `userinfo.id` 無法驗證真偽，任何人都能偽造 `userId` 呼叫上傳 API，把自己的裝置綁到別人帳號而收到他人的通知。**正式上線前，上傳 token 的 API 必須以論壇自己的登入 session 判斷使用者**，不要信任前端傳來的 `userId`。
- 推播內文會顯示在鎖定畫面，請勿放入個資或敏感內容。

---

## 5. App 端設定（一次性）

推播需要 Firebase 專案。**未設定時 App 仍可正常建置與執行，只是 `push_token` 回傳 `null`。**

1. 到 [Firebase 主控台](https://console.firebase.google.com/) 建立專案。
2. 新增 Android 應用程式，套件名稱填 **`com.example.townpass`**（必須與 `android/app/build.gradle` 的 `applicationId` 一致；若之後更改套件名稱，需在 Firebase 重新註冊）。
3. 下載 `google-services.json`，放到 `android/app/google-services.json`。
4. 重新建置 App：`flutter build apk --release`。
5. 驗證：在論壇頁面 console 執行 `callApp('push_token')`，應取得 token；再到 Firebase 主控台 → Messaging → 「傳送測試訊息」貼上 token 測試。

> `google-services.json` 不是機密，但它綁定你的 Firebase 專案，開源專案通常不提交。本專案已將它加入 `.gitignore`。
