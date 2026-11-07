# 論壇 Web 端修改指南（Town Pass 整合）

> 對象：`https://tp2026.ydtw.net` 的 Next.js 專案
> 目的：讓論壇在 Town Pass App 內正確運作，並支援「問題回報」自動帶入
> 詳細規格：[`webview-bridge-spec.md`](./webview-bridge-spec.md)、[`fcm-push-spec.md`](./fcm-push-spec.md)

範例以 **App Router + TypeScript** 撰寫（`create-next-app` 預設）。若使用 Pages Router，元件程式碼相同，只是檔案位置改放 `pages/`。

---

## 修改清單

| # | 項目 | 必要性 | 檔案 |
|---|---|---|---|
| 1 | 修改網站標題 | 建議 | `app/layout.tsx` |
| 2 | 加入 App 橋接工具 | **必要** | `lib/townpass.ts`（新增） |
| 3 | 新增 `/new` 發文頁，支援問題回報帶入與語音附件 | **必要** | `src/app/new/page.tsx`、`new-post-form.tsx`、`voice-recorder.tsx` |
| 4 | 個資元素加上 `data-sensitive` | 建議 | 顯示個資的元件 |
| 5 | 同步推播 token | 選用 | 登入後執行的元件 |

---

## 1. 修改網站標題

App 的 WebView 標題列會顯示網頁的 `<title>`，目前是預設的「Create Next App」。

```tsx
// app/layout.tsx
export const metadata: Metadata = {
  title: '論壇',
  description: 'Town Pass 市民交流討論區',
};
```

各頁面可再用自己的 `metadata` 覆寫，例如發文頁設 `title: '發表文章'`。

---

## 2. App 橋接工具

App 會在 WebView 中注入全域物件 `flutterObject`，以 JSON 字串雙向溝通。新增以下檔案，之後所有 App 功能都透過 `callApp` 呼叫。

```ts
// lib/townpass.ts
'use client';

type FlutterObject = {
  postMessage: (message: string) => void;
  addEventListener: (type: 'message', listener: (event: { data: string }) => void) => void;
  removeEventListener: (type: 'message', listener: (event: { data: string }) => void) => void;
};

declare global {
  interface Window {
    flutterObject?: FlutterObject;
  }
}

/** 是否在 Town Pass App 內開啟 */
export function isInTownPass(): boolean {
  return typeof window !== 'undefined' && typeof window.flutterObject !== 'undefined';
}

/**
 * 呼叫 App 功能。不在 App 內、逾時或 App 未回覆時 resolve(undefined)。
 * 同名功能請勿並行呼叫（回覆沒有 request id，無法對應）。
 */
export function callApp<T = unknown>(name: string, data: unknown = null, timeoutMs = 10_000): Promise<T | undefined> {
  const bridge = typeof window !== 'undefined' ? window.flutterObject : undefined;
  if (!bridge) return Promise.resolve(undefined);

  return new Promise((resolve) => {
    const listener = (event: { data: string }) => {
      let message: { name?: string; data?: T };
      try {
        message = JSON.parse(event.data);
      } catch {
        return;
      }
      if (message.name !== name) return;
      cleanup();
      resolve(message.data);
    };
    const timer = setTimeout(() => {
      cleanup();
      resolve(undefined);
    }, timeoutMs);
    const cleanup = () => {
      clearTimeout(timer);
      bridge.removeEventListener('message', listener);
    };

    bridge.addEventListener('message', listener);
    bridge.postMessage(JSON.stringify({ name, data }));
  });
}

// ---- 型別 ----

export type ReportDraft = {
  id: string;
  description: string;
  /** PNG data URL；使用者未附截圖時為 null */
  image: string | null;
  context: {
    route: string;
    routeHistory: string[];
    webUrl: string | null;
    appVersion: string | null;
    platform: string;
    osVersion: string | null;
    deviceModel: string | null;
    locale: string;
    timestamp: number;
  };
};

export type PushToken = { token: string; platform: 'android' | 'ios' };
```

> ⚠️ 請使用 `addEventListener`，**不要**直接覆寫 `flutterObject.onmessage`，否則頁面上其他地方的監聽會被蓋掉。

---

## 3. `/new` 發文頁與問題回報帶入

### 3.1 流程

```
App「送到論壇」
  → 開啟 https://tp2026.ydtw.net/new?source=app-report
  → 頁面偵測 source=app-report，呼叫 callApp('report_draft')
  → 有草稿：分類預設「問題回報」、內文帶入描述與裝置資訊、顯示截圖附件
  → 使用者可再錄一段語音說明（選填）
  → 使用者確認後送出 → 截圖、語音各自上傳 POST /media → POST /questions 發文
```

草稿**只能讀一次**、App 送出後 **10 分鐘內**有效，且**只有 `tp2026.ydtw.net` 網域**讀得到。因此：

- 讀到草稿後請存在 React state，不要重複呼叫。
- React 18 開發模式（Strict Mode）的 `useEffect` 會執行兩次，第二次會讀到 `null`。範例用 `useRef` 防止重複呼叫。

### 3.2 頁面

實作在論壇專案 `TownPass-2026-web`：

| 檔案 | 內容 |
|---|---|
| `src/app/new/page.tsx` | 頁面外框；`useSearchParams` 需要 `<Suspense>` 包住，否則 production build 會失敗 |
| `src/app/new/new-post-form.tsx` | 讀草稿、表單、送出 |
| `src/app/new/voice-recorder.tsx` | 語音附件（見 §3.3） |
| `src/lib/townpass-bridge.ts` | `callApp`、`isInTownPass`、`ReportDraft` 型別 |
| `src/lib/forum-api.ts` | 後端 API：`getToken`、`uploadImage`、`uploadAudio`、`createQuestion` |

讀草稿（`new-post-form.tsx`）：

```tsx
useEffect(() => {
  // 草稿只能讀一次：Strict Mode 下 effect 會跑兩次，用 ref 防止第二次讀到 null
  if (!isAppReport || requested.current) return;
  requested.current = true;
  if (!isInTownPass()) return setLoadingDraft(false);

  callApp<ReportDraft | null>('report_draft').then((d) => {
    setLoadingDraft(false);
    if (!d) return; // 已讀過、逾時（10 分鐘）或網域不符
    setDraft(d);
    setCategory('app_usage');
    setTitle(d.description ? `[問題回報] ${d.description.slice(0, 30)}` : '[問題回報]');
    setContent(d.description);
    setImage(d.image);
  });
}, [isAppReport]);
```

送出：附件先各自上傳到 `POST /media` 取得 `id`，再放進 `POST /questions` 的 `media_ids`。

```tsx
const media_ids: string[] = [];
if (image) {
  const blob = await (await fetch(image)).blob(); // data URL → Blob
  media_ids.push((await uploadImage(token, blob, `report-${draft?.id ?? Date.now()}.png`)).id);
}
if (audio) {
  media_ids.push((await uploadAudio(token, audio.blob, audio.seconds)).id);
}
await createQuestion(token, {
  title: title.trim().slice(0, 80) || undefined,
  body: content.trim() || undefined,
  media_ids: media_ids.length ? media_ids : undefined,
  category, // 一般發文不傳，交給後端自動分類
  // 裝置資訊放 context.extra，不併入內文
  context: draft
    ? { service_id: 'townpass-app', service_name: 'Town Pass', page_route: draft.context.route.split('?')[0], extra: { reportId: draft.id, ...draft.context } }
    : null,
  client_request_id: draft?.id ?? fallbackRequestId, // 防重送
  // …language、assistance_mode 等其他欄位
});
```

- `body` 和 `media_ids` 至少要有一個，所以有截圖或錄音時內文可以不填。
- token 失效（401）時清掉快取、重建工作階段再送一次。
- 截圖是 data URL，不需要 `next/image` 的圖片最佳化，直接用原生 `<img>`。

### 3.3 語音附件（錄音）

錄音完全在網頁端進行（`getUserMedia` + `MediaRecorder`），一般發文與問題回報都能使用。在 App 內時，**只有論壇網域**能取得麥克風，第一次錄音時 App 會詢問使用者授權（App 端實作見 `lib/util/tp_web_view.dart` 的 `_canGrant`）。

`voice-recorder.tsx` 的行為：

- 最長 60 秒，到時自動停止；錄完顯示 `<audio controls>` 試聽與刪除鈕，回傳 `{ blob, seconds }`。
- 依序嘗試 `audio/mp4`、`audio/webm;codecs=opus`、`audio/webm`，取第一個 `MediaRecorder.isTypeSupported` 的格式；位元率 32 kbps，60 秒約 240 KB。
- `NotAllowedError`（使用者拒絕）、`NotFoundError`（沒有麥克風）顯示對應提示。
- 非 HTTPS 或瀏覽器不支援時不顯示按鈕；離開頁面時釋放麥克風。

| 環境 | 錄出的格式 | 上傳檔名 |
|---|---|---|
| iOS（WKWebView／Safari） | `audio/mp4`（AAC） | `voice.m4a` |
| Android WebView／Chrome | `audio/webm`（Opus） | `voice.webm` |

注意事項：

- 必須由使用者點擊才開始錄音，不要在頁面載入時要求麥克風。
- iOS 錄的 `audio/mp4` 在 Android 可以播；Android 錄的 `audio/webm` 要 iOS 17.4 以後才能播。要所有裝置都能播，需由後端轉檔成 AAC。
- iOS 要 15 以上，WKWebView 才支援網頁錄音。

### 3.4 後端 API

完整規格見論壇專案的 `api-spec.md`，這裡只列發文相關的部分。

`POST /media`（`multipart/form-data`）：

| 欄位 | 說明 |
|---|---|
| `kind` | `image` 或 `audio` |
| `duration_seconds` | `kind=audio` 時必填，前端以錄音經過的秒數帶入 |
| `file` | 圖片：JPEG、PNG、WebP，最大 10 MB；語音：M4A、AAC、MP3、WebM，最長 3 分鐘 |

- 文字欄位要放在 `file` 前面，有些 multipart 解析器處理檔案時只看得到前面的欄位。
- 錄音的 MIME 可能帶 `;codecs=opus`，上傳前會去掉參數並改成對應副檔名（`forum-api.ts` 的 `audioFile`）。
- 超過 24 小時沒被問題或回答引用的檔案會被刪除。

`POST /questions`（JSON）：`media_ids` 最多 5 項；`client_request_id` 用來去重，問題回報帶草稿 ID，避免同一份回報被發兩次。

注意事項：

- **發文者身分以後端的工作階段 token 判斷**，不要信任前端或 App `userinfo` 傳來的使用者 ID（無法驗證真偽）。
- 前端的 60 秒限制可以被繞過，長度與大小要由後端檢查。

### 3.5 測試

在一般瀏覽器開發時沒有 `flutterObject`，可以在發文頁之前載入模擬程式（**僅限開發環境**）：

```ts
// lib/townpass-mock.ts —— 在 layout 中以 process.env.NODE_ENV === 'development' 條件載入
if (typeof window !== 'undefined' && !window.flutterObject) {
  const listeners = new Set<(e: { data: string }) => void>();
  window.flutterObject = {
    addEventListener: (_, l) => listeners.add(l),
    removeEventListener: (_, l) => listeners.delete(l),
    postMessage(raw) {
      const { name } = JSON.parse(raw);
      if (name !== 'report_draft') return;
      const data = {
        id: 'mock-report-id',
        description: '按下送出後沒有反應',
        image: null,
        context: {
          route: '/account', routeHistory: ['/', '/account'], webUrl: null,
          appVersion: '0.0.12', platform: 'android', osVersion: '14',
          deviceModel: 'SM-A236E', locale: 'zh-Hant-TW', timestamp: Date.now(),
        },
      };
      setTimeout(() => listeners.forEach((l) => l({ data: JSON.stringify({ name, data }) })), 100);
    },
  };
}
```

開啟 `http://localhost:3000/new?source=app-report`，表單應自動帶入描述與裝置資訊。

在 App 內實測：

1. 在任一畫面點左下角 🐞（或長按右下角「論壇」）。
2. 填寫描述 →「送到論壇」。
3. 確認 `/new` 頁面自動帶入內容與截圖。
4. 點「錄製語音說明」：第一次會跳出麥克風授權，允許後開始計時，停止後可試聽、刪除。
5. 送出後確認文章附有語音且可播放（iOS、Android 各測一次，格式不同）。
6. 重新整理頁面，應不再帶入（草稿只能讀一次）。

在一般瀏覽器開發時錄音也能直接測（`localhost` 允許 `getUserMedia`），不需要 mock。

偵錯：手機以 USB 連接電腦（需 debug 版 App），Chrome 開啟 `chrome://inspect/#devices` 即可檢查 WebView。

---

## 4. 個資元素加上 `data-sensitive`

App 截圖時會模糊以下內容：

- 所有 `input`、`textarea`
- 文字中含有使用者的姓名、帳號、身分證、手機、Email、地址、生日、使用者 ID
- 符合身分證、手機、Email、經緯度格式的文字
- **有 `data-sensitive` 屬性的元素**

前兩類靠文字比對，可能漏掉（例如分段顯示的地址、遮罩過的電話 `09***777`）。凡是顯示個資的元素都請明確標記：

```tsx
<span data-sensitive>{user.realName}</span>
<div data-sensitive className="avatar">…</div>
```

---

## 5. 同步推播 token（選用）

若要讓論壇發送推播（例如「有人回覆你的文章」），在使用者登入後的頁面執行：

```tsx
'use client';
import { useEffect } from 'react';
import { callApp, type PushToken } from '@/lib/townpass';

export function PushTokenSync() {
  useEffect(() => {
    callApp<PushToken | null>('push_token').then((res) => {
      if (!res?.token) return;
      fetch('/api/push-tokens', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(res), // 使用者身分由後端 session 判斷
      });
    });
  }, []);
  return null;
}
```

後端發送方式、資料表設計與錯誤處理見 [`fcm-push-spec.md`](./fcm-push-spec.md)。
