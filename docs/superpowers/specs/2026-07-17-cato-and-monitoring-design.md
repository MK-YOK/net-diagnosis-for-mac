# 設計: Cato 検知 と 継続監視 の追加

net-diagnosis-for-mac（Mac のローカルネット診断 read-only プレイブック）に 2 機能を追加する設計。
2026-07-17 に実際に起きた間欠ネット障害の調査から生まれた要件。

## 背景（この設計が生まれた実インシデント）

症状: Google Meet の音声が乱れる → ネット全体が重い。半日で悪化↔回復を繰り返す **間欠障害**。

消去法での切り分け:
- **Cato VPN** — 第一容疑者だったが切っても症状継続で **シロ**。ただし毎回 `route -n get default` が `utun4`(Cato) を指し、切り分けの起点として毎度チェックした。→ 検知＆可視化する価値がある。
- **電源タワー(EMI)** — 一度「真犯人」と断定したが再発。→ **断定しすぎた反省**。
- **ルーター不調** — 電源抜き差しで毎回一時回復、数時間で再発。

教訓は 2 つ:
1. **スナップショット診断では間欠障害を捕まえられない** → 継続監視が要る。
2. **層で切り分け、断定しすぎない** → Cato も「犯人」でなく「まず経路にいることを可視化して消去法の起点にする」扱いにする。

## スコープ

- ローカル経路の診断（この Mac → ルーター/GW → 外部）に限る。既存スコープを踏襲。
- 破壊的・変更操作は追加しない。物理操作（ルーター再起動 / Cato 切断）は **推奨するだけ、実行は user**。
- 同一リポ内で完結。別リポには分けない。

## 共通ライブラリ: `scripts/lib/net-common.sh`（新規）

役割の違う実行入口（run.sh / net-monitor.sh / net-cato-check.sh）が同じ判定ロジックを使い回すための共有ライブラリ。ping 解析と閾値・経路判定が 2 箇所でドリフトするのを防ぐ。

現在 [net-log-run.sh](../../../scripts/net-log-run.sh) 内に埋まっている `ping_loss()` / `ping_avg()` をここへ移し、各スクリプトが `source` する。

提供する関数:
- `ping_loss <host> <count>` — ロス率(%)を返す（既存ロジックを移設）
- `ping_avg <host> <count>` — 平均 RTT(ms) を返す（既存ロジックを移設）
- `default_route_class` — デフォルト経路の分類を `cato` / `vpn` / `direct` の 1 語で返す（下記 Cato 検知ロジック）。
- 閾値デフォルトの読み込み（`net-monitor.conf` を source、無ければ組み込みフォールバック）

スタイル規約は既存踏襲: 冒頭に「何をする / read-only / 副作用なし」コメントブロック、`set -uo pipefail`。

---

## 機能 1: Cato 検知 — `scripts/net-cato-check.sh`（新規）

### 振る舞い（report + 比較を推奨）

Cato を検知したら診断冒頭付近で **可視化し、重い場合の切り分け手順を推奨する**。断定も自動実行もしない（ルーター再起動と同じ思想）。

出力例（Cato 経由時）:
```
[cato] デフォルト経路は Cato VPN 経由です (utun4, inet 10.41.41.58)
       重い場合はまず Cato を手動で切って before/after を比較してください（切断は user 操作）。
```

### 検知ロジック（層の事実と固有名を分離）

`utun*` は Cato 専用ではないため、「トンネルが経路を握っている」事実と「それが Cato である」特定を分ける:

1. `route -n get default` の interface が `utun*` か → **トンネルがデフォルト経路を握っている**（層の事実）
2. `pgrep -f CatoClient` が当たるか → 当たれば **Cato と特定**
3. 補足: `ifconfig utunN` の inet を表示（例 `10.41.41.58`）

判定結果（`default_route_class` の戻り値）:
| 条件 | 分類 | 表示 |
|---|---|---|
| default route が utun* かつ CatoClient あり | `cato` | 「Cato VPN 経由です」 |
| default route が utun* だが CatoClient なし | `vpn` | 「VPN トンネル(utun)が経路を握っています（Cato ではなさそう）」 |
| default route が utun* でない | `direct` | 表示なし（直結） |

### 実行順

run.sh の順序を **interface → cato → connectivity → wifi** に変更。
理由: まず IP がある事を確認（interface）→ 次にその経路を誰が握っているか（cato）→ そこから外部への到達性（connectivity）。IP すら無ければ Cato 云々の前段階。

---

## 機能 2: 継続監視 — `scripts/net-monitor.sh`（新規）

### 動作モード（フォアグラウンド監視）

```bash
./scripts/net-monitor.sh [duration]
```

- **duration 指定** (例 `30m`) → その時間で自動終了。**省略** → Ctrl-C まで無期限。
- 数秒おきに ping し続ける（tick 方式、下記）。
- **正常時は基本静か** — 生存表示のみ（例「監視中… 12分経過、異常なし」）。
- **異常検知時だけ** タイムスタンプ付き 1 行を出す（現行犯逮捕）。
- 終了時（時間切れ or Ctrl-C）に **サマリ**（監視時間 / 検知回数 / 最悪スパイク値 など）。

既存の「read-only・background collection しない・後始末不要」の思想と親和的なフォアグラウンド方式を採用。launchd 常駐は managed な社用 Mac のポリシー懸念もあり不採用。

### tick の仕組み

ping のロス率は 1 発では出ないので、1 周期（tick）ごとに小バッチで測る:

- 1 tick = GW に `PING_COUNT` 発 + 外部(1.1.1.1)に `PING_COUNT` 発 ping（`net-common.sh` の `ping_loss`/`ping_avg` を流用）。約 5 秒で 1 周。
- その tick の avg / loss を閾値と比較 → 超えたら異常行を出す。連続実行なので実質「数秒おきに測り続ける」。

### 監視対象（GW + 外部、層別判定）

GW と外部(1.1.1.1)の両方を監視し、どちらが崩れたかで層を切り分ける:
- **GW だけ崩れる** → ルーター/ローカル経路寄り
- **両方崩れる** → ISP/WAN 寄り

### 異常行の内容

タイムスタンプ + 崩れた対象 + 実測値 + **その時点の default route 分類**（`cato`/`vpn`/`direct`）。
間欠障害と Cato の相関を現行犯で取れるようにする。

例:
```
14:23:07  GW spike avg=312ms loss=0%   [route=cato]
14:31:12  GW loss=40% avg=180ms        [route=cato]
14:52:40  EXT spike avg=410ms loss=20% [route=direct]
```

### 閾値と設定ファイル: `scripts/net-monitor.conf`（新規・コミットする）

bash で source する形。デフォルト値をリポと一緒に運ぶ:

```sh
# 監視の閾値と tick 設定（編集して恒久的に変えられる）
GW_SPIKE_MS=50       # GW ping avg がこれを超えたら異常
GW_LOSS_PCT=0        # GW loss がこれを超えたら異常
EXT_SPIKE_MS=150     # 外部(1.1.1.1) avg
EXT_LOSS_PCT=0       # 外部 loss
PING_COUNT=5         # 1 tick あたりの ping 発数
```

上書きの優先順位（bash `: "${VAR:=default}"` 方式）:
1. コマンドライン / 環境変数（その場限りの一時変更。例 `GW_SPIKE_MS=30 ./scripts/net-monitor.sh`）
2. `net-monitor.conf`（恒久的なデフォルト）
3. スクリプト組み込みのフォールバック（conf を消しても動く安全網）

閾値は `net-common.sh` 側で読み込み、将来スナップショット診断でも同じ基準を使い回せるようにする。

### 監視ログ

異常行は画面表示に加え `logs/monitor-YYYYMMDD.log` にも残す（後で振り返れる）。
`logs/` は従来通り gitignore。スナップショットの `history.csv` とは **別ファイル**（history=定点観測 1 行、monitor=イベント駆動の異常ログ、で性質が違うので混ぜない）。

---

## `history.csv` への列追加

現在 16 カラム。**17 カラム目 `default_route`（enum: `cato`/`vpn`/`direct`）を追加**する。
run 時点で経路を誰が握っていたかを記録し、「重かった run のとき Cato は経路を握っていたか？」を時系列で相関検証できるようにする（今日の「容疑者だが実はシロ」を思い込みでなくデータで確認する）。

新しいヘッダ（17 カラム）:
```
timestamp,interface,link_status,has_ip,gateway_ip,gateway_loss_pct,gateway_avg_ms,dns_ok,dns_query_ms,ext_ip_loss_pct,ext_ip_avg_ms,ext_host_loss_pct,ext_host_avg_ms,wifi_rssi,wifi_noise,wifi_channel,default_route
```

**後方互換**: [net-history-report.sh](../../../scripts/net-history-report.sh) は 16 列の旧行を欠損として無害に扱う（`default_route` 列が無い行は「不明」と表示、集計を壊さない）。現時点で history.csv は行ゼロ（未 run）なのでリスクは低いが、将来のために report 側で対応する。

---

## CLAUDE.md への追記

解釈・判断レイヤに以下を足す:
- **Cato の扱い**: 「重い時はまず Cato を手動で切って before/after を比較。ただし Cato は経路を握っていても犯人とは限らない（過去にシロ実績）。断定せず消去法の起点として扱う」。
- **継続監視の使いどころ**: 「単発 run で矛盾する（悪い↔治った）間欠障害には `net-monitor.sh` を使い、現行犯で層（GW/外部）と Cato 相関を捕まえる」。
- 断定しすぎないトーンを維持（EMI/Cato で 2 回外した教訓）。

## 変更ファイル一覧

新規:
- `scripts/lib/net-common.sh` — 共有ライブラリ（ping ヘルパ + 経路分類 + 閾値読込）
- `scripts/net-cato-check.sh` — Cato 検知（report + 比較推奨）
- `scripts/net-monitor.sh` — 継続監視（フォアグラウンド tick 方式）
- `scripts/net-monitor.conf` — 監視の閾値/設定（コミットする）

変更:
- `scripts/run.sh` — 実行順に cato を挿入（interface → cato → connectivity → wifi）
- `scripts/net-log-run.sh` — ping ヘルパを net-common.sh に移設して source、`default_route` 列を追記
- `scripts/net-history-report.sh` — 17 列対応＋旧 16 列行の後方互換
- `CLAUDE.md` — 解釈ガイド追記

## 非目標（YAGNI）

- launchd 常駐 / background collection（思想と社用 Mac ポリシーに反する）。
- Cato の自動切断や自動 before/after 計測（user 操作を伴うステートフルフロー、read-only 思想外）。
- ISP/WAN 側の診断（既存スコープ外のまま）。
