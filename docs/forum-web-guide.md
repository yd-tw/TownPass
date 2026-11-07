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
| 3 | `/new`「我要發問」支援問題回報帶入截圖 | **必要** | `src/app/new/page.tsx`、`src/app/ui/line/line-app.tsx`、`chat-room.tsx` |
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
    /** 截圖時所在畫面，例如 `/account`、`/main/home`、`web:tp2026.ydtw.net/new`；格式見 webview-bridge-spec.md §4.10 */
    screen?: string;
    /** 截圖時標題列的文字 */
    screenTitle?: string | null;
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

## 3. `/new`「我要發問」與問題回報帶入

`/new` 直接開啟「我要發問」的新問題聊天室（和首頁按「我要發問」相同）。原本的發文表單已移除。

### 3.1 流程

```
App 任一畫面按回報按鈕（問號）
  → App 截圖、遮蔽個資（沒有預覽頁）
  → 開啟 https://tp2026.ydtw.net/new?source=app-report
  → 頁面偵測 source=app-report，呼叫 callApp('report_draft')，並從網址移除 source
  → 有草稿：截圖放進輸入列的待傳附件，分類預設「App 使用」，不通知附近的人
  → 使用者打字或錄音說明，可移除截圖 → 送出
  → 截圖上傳 POST /media → POST /questions（帶 context 與草稿 ID）
```

草稿**只能讀一次**、App 產生後 **10 分鐘內**有效，且**只有 `tp2026.ydtw.net` 網域**讀得到。因此：

- 讀到草稿後存在 React state，不要重複呼叫。
- React 開發模式（Strict Mode）的 `useEffect` 會執行兩次，第二次會讀到 `null`，要用 `useRef` 防止重複呼叫。
- `description` 一律是空字串，描述由使用者在聊天室輸入。
- App 端沒有預覽，截圖一定要先顯示在待傳附件，讓使用者確認或移除後才上傳。

### 3.2 頁面

實作在論壇專案 `TownPass-2026-web`：

| 檔案 | 內容 |
|---|---|
| `src/app/new/page.tsx` | 以 `<LineApp ask />` 開啟新問題聊天室 |
| `src/app/ui/line/line-app.tsx` | `readReportDraft`（讀草稿、截圖轉 `File`）、`reportContext`，以及 `send()` 建立問題時附上 context |
| `src/app/ui/line/chat-room.tsx` | `initialMedia`（預先放好的待傳附件）、`draftHint`（新問題上方的提示） |
| `src/lib/townpass-bridge.ts` | `callApp`、`isInTownPass`、`ReportDraft` 型別 |

讀草稿（`line-app.tsx`）：

草稿要和連線後端**同時**讀，等兩者都好了才顯示畫面，聊天室第一次出現就帶著截圖。若先顯示空白聊天室、讀到草稿再換一個，畫面會閃一下。

```tsx
// LineAppInner：草稿只能讀一次，存在 ref，Strict Mode 重跑 effect 或重新連線都沿用同一份
const reportRef = useRef<Promise<Report | null> | null>(null);
useEffect(() => {
  reportRef.current ??= readReportFromUrl(); // 讀完會把 source 從網址移除
  const report = reportRef.current;
  connect().then(async ({ api, note }) => {
    setConn({ status: 'ready', api, note, report: await report });
  });
}, [attempt]);

// LineAppConnected：一開始就建立帶截圖的新問題，instant 讓聊天室不播放滑入動畫
const [active, setActive] = useState(() => report
  ? { key: makeId(), id: null, category: 'app_usage', locationSharing: 'approximate', report, instant: true }
  : /* ask 模式的空白新問題，同樣 instant */ ...);
```

送出：截圖和其他附件一樣先上傳 `POST /media`，建立問題時多帶 `context` 與草稿 ID。

```tsx
await api.createQuestion({
  body,
  media_ids: mediaIds,
  // …language、category、assistance_mode、location_sharing
  // 裝置資訊放 context.extra，不併入內文
  ...(active.report ? { context: reportContext(active.report) } : {}),
  client_request_id: active.report?.id ?? makeId(), // 問題回報用草稿 ID 防重送
});

function reportContext(report) {
  return {
    service_id: 'townpass-app',
    service_name: 'Town Pass',
    // page_route 不可含 query；完整的 screen 仍會隨 extra 送出
    page_route: (report.context.screen ?? report.context.route).replace(/\?[^+]*/, ''),
    page_title: report.context.screenTitle?.slice(0, 80) || undefined,
    extra: { reportId: report.id, ...report.context },
  };
}
```

- `body` 和 `media_ids` 至少要有一個，所以只送截圖也可以。
- 截圖是 data URL，先 `fetch` 成 Blob 再包成 `File`（`report-<id>.png`）。

### 3.3 語音附件（錄音）

錄音在聊天室輸入列的麥克風按鈕（`src/app/ui/line/media.tsx` 的 `VoiceRecorder`），用 `getUserMedia` + `MediaRecorder`。在 App 內時，**只有論壇網域**能取得麥克風，第一次錄音時 App 會詢問使用者授權（App 端實作見 `lib/util/tp_web_view.dart` 的 `_canGrant`）。

| 環境 | 錄出的格式 |
|---|---|
| iOS（WKWebView／Safari） | `audio/mp4`（AAC） |
| Android WebView／Chrome | `audio/webm`（Opus） |

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
- 超過 24 小時沒被問題或回答引用的檔案會被刪除。

`POST /questions`（JSON）：`media_ids` 最多 5 項；`client_request_id` 用來去重，問題回報帶草稿 ID，避免同一份回報被發兩次。

注意事項：

- **發文者身分以後端的工作階段 token 判斷**，不要信任前端或 App `userinfo` 傳來的使用者 ID（無法驗證真偽）。
- 前端的 60 秒限制可以被繞過，長度與大小要由後端檢查。
- `context.extra`（裝置資訊、瀏覽過的頁面）後端只回傳給發問者本人與管理員；其他人只看得到 `page_route`、`page_title`。

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
        description: '',
        image: null, // 可換成任一 PNG data URL 測試截圖帶入
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

開啟 `http://localhost:3000/new?source=app-report&demo=mock`（mock 只回覆 `report_draft`，所以搭配 `demo=mock` 不連後端），應直接進入新問題聊天室，分類為「App 使用」，有截圖時出現在待傳附件。

在 App 內實測：

1. 在任一畫面點左下角回報按鈕（問號）。
2. 應直接進入論壇「我要發問」的新問題聊天室，截圖在輸入列的待傳附件，可以移除。
3. 打字或錄音說明後送出，確認問題附有截圖，`context.page_route` 是按回報按鈕（問號）時的畫面。
4. 重新整理頁面，應不再帶入（草稿只能讀一次）。
5. 在論壇頁面內按回報按鈕（問號），應再開一層「我要發問」。

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
