# 設計: Cato 検知 と 継続監視 の追加

net-diagnosis-for-mac（Mac のローカルネット診断 read-only プレイブック）に 2 機能を追加する設計。
2026-07-17 に実際に起きた間欠ネット障害の調査から生まれた要件。

> **改訂メモ**: 初版に対し Codex (gpt-5.5) クロスレビューで 8 件の指摘を受け、実機で裏取りのうえ全件反映済み（下記「レビュー反映」参照）。特に、Cato 接続中は `route -n get default` に `gateway:` 行が出ず、既存 net-log-run.sh の GW 判定が空になり GW ping がスキップされていた既存バグが判明したため、物理 GW を独立取得する設計に変更した。

## 背景（この設計が生まれた実インシデント）

症状: Google Meet の音声が乱れる → ネット全体が重い。半日で悪化↔回復を繰り返す **間欠障害**。

消去法での切り分け:
- **Cato VPN** — 第一容疑者だったが切っても症状継続で **シロ**。ただし毎回 `route -n get default` が `utun*`(Cato) を指し、切り分けの起点として毎度チェックした。→ 検知＆可視化する価値がある。
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

役割の違う実行入口（run.sh / net-monitor.sh / net-cato-check.sh）が同じ判定ロジックを使い回すための共有ライブラリ。ping 解析・GW 判定・経路分類が複数箇所でドリフトするのを防ぐ。

各スクリプトは自分の位置を基準に source する（相対パス解決）:
```sh
cd "$(dirname "$0")" || exit 1
. "./lib/net-common.sh"      # scripts/ からの相対
```

提供する関数:

- `ping_loss`（stdin パーサ・**現行のまま**）— ping 出力を stdin で受けロス率(%)を返す。
- `ping_avg`（stdin パーサ・**現行のまま**）— ping 出力を stdin で受け平均 RTT(ms) を返す。
  - **注意**: これらは ping を実行しない。現行 [net-log-run.sh](../../../scripts/net-log-run.sh) の `ping_loss()`/`ping_avg()` は「stdin の ping 出力を parse するフィルタ」であり、そのまま移設する。
- `ping_probe <host> <count>` — **新規**。指定ホストへ 1 回だけ ping し、その **同一サンプル**から `loss avg` の 2 値を返す（内部で `ping_loss`/`ping_avg` に食わせる）。loss と avg を別々の ping から取ると値がずれるため、監視・診断はこの関数を使う。
  - 100% ロス時は avg が空になる。`ping_probe` は avg を空のとき `n/a` として返し、呼び出し側は「avg=n/a を閾値超え=正常と誤判定しない」（ロス側の判定で異常を捕まえる）。
- `physical_gateway` — **新規**。VPN が default route を握っていても **物理 LAN ルーター**の IP を独立に取得する（下記「物理 GW の独立取得」）。
- `default_route_class` — デフォルト経路の分類を `cato` / `vpn` / `direct` / `unknown` の 1 語で返す（下記「Cato 検知ロジック」）。
- 閾値デフォルトの読み込み（`net-monitor.conf` を source、無ければ組み込みフォールバック。優先順位は「閾値と設定ファイル」参照）。

スタイル規約は既存踏襲: 冒頭に「何をする / read-only / 副作用なし」コメントブロック、`set -uo pipefail`。

### 物理 GW の独立取得（`physical_gateway`）

**なぜ必要か（実機確認済みの既存バグ）**: Cato 接続中、`route -n get default` は `interface: utun5` を返すが **`gateway:` 行を出さない**。そのため現行 [net-log-run.sh:37](../../../scripts/net-log-run.sh:37) の `GATEWAY=$(... /gateway:/ ...)` は空になり、[:40](../../../scripts/net-log-run.sh:40) の `[ -n "$GATEWAY" ]` で **GW ping が丸ごとスキップ**される。つまり Cato 常駐機では GW 層の計測が無効化されていた。

`physical_gateway` は default route が VPN でも物理ルーターを返す:
1. アクティブなハードウェア I/F（`utun*` を除く、`status: active` かつ inet を持つ `en*`）を特定
2. `ipconfig getoption <iface> router` でその I/F の router を取得（実機で `en0` → `192.168.0.1` 確認済み）
3. 取得できなければ `net-monitor.conf` の `GATEWAY`（任意設定）にフォールバック

> 実装注: `ipconfig getoption` が空 router を返す I/F はスキップし、router が取れた最初の active `en*` を採る。

これにより **GW 層＝物理ルーター**で一貫し、Cato の ON/OFF によらず「GW だけ崩れる＝ルーター寄り」の切り分けが成立する。default route 上の VPN gateway とは意味が違うので混同しない。

---

## 機能 1: Cato 検知 — `scripts/net-cato-check.sh`（新規）

### 振る舞い（report + 比較を推奨）

Cato を検知したら診断冒頭付近で **可視化し、重い場合の切り分け手順を推奨する**。断定も自動実行もしない（ルーター再起動と同じ思想）。

出力例（Cato 経由時）:
```
[cato] デフォルト経路は Cato 経由の可能性が高い (utun5, inet 10.41.31.48)
       重い場合はまず Cato を手動で切って before/after を比較してください（切断は user 操作）。
```
※ inet が無い utun もあるため、取れないときは `inet n/a` と表示する。

### 検知ロジック（層の事実と固有名を分離）

`utun*` は Cato 専用ではないため、「トンネルが経路を握っている」事実と「それが Cato である」推定を分ける。**utun 番号は決め打ちせず、`route -n get default` の `interface:` から取得**する（実機では utun5 が default、utun4 は inet 無し）:

1. `route -n get default` の `interface:` が `utun*` か → **トンネルがデフォルト経路を握っている**（層の事実）
2. `pgrep -f CatoClient` が当たるか → 当たれば **Cato の可能性が高い**（helper/app/sysext のいずれかにマッチ。プロセス名変更や別プロセス誤一致の余地があるので「特定」ではなく「ほぼ Cato」と表現）
3. 補足: 経路を握る当の utun の `ifconfig` から `inet` を表示（**nullable。無ければ `n/a`**）

判定結果（`default_route_class` の戻り値）:
| 条件 | 分類 | 表示 |
|---|---|---|
| default route が utun* かつ CatoClient あり | `cato` | 「Cato 経由の可能性が高い」 |
| default route が utun* だが CatoClient なし | `vpn` | 「VPN トンネル(utun)が経路を握っています（Cato ではなさそう）」 |
| default route が utun* でない（物理 I/F） | `direct` | 表示なし（直結） |
| default route が取得できない / route 失敗 | `unknown` | 「デフォルト経路が取得できません（I/F down 等の可能性）」 |

`unknown` を独立させる理由: route が取れない状態（I/F down・route 取得失敗）を `direct` に丸めると誤記録になる。

### 実行順

run.sh の順序を **interface → cato → connectivity → wifi** に変更。
理由: まず IP がある事を確認（interface）→ 次にその経路を誰が握っているか（cato）→ そこから外部への到達性（connectivity）。IP すら無ければ Cato 云々の前段階。

---

## 機能 2: 継続監視 — `scripts/net-monitor.sh`（新規）

### 動作モード（フォアグラウンド監視）

```bash
./scripts/net-monitor.sh [duration]
```

- **duration 指定** → その時間で自動終了。**省略** → Ctrl-C まで無期限。
- **duration の書式**: `30m` / `45s` / `2h` のサフィックス付き、またはサフィックス無しは秒とみなす。パースは単純な正規表現（`^[0-9]+[smh]?$`）で行い、不正入力はエラーで即終了。
- 数秒おきに ping し続ける（tick 方式、下記）。
- **正常時は基本静か** — 生存表示のみ（例「監視中… 12分経過、異常なし」）。
- **異常検知時だけ** タイムスタンプ付き 1 行を出す（現行犯逮捕）。
- 終了時（時間切れ or Ctrl-C）に **サマリ**（監視時間 / 検知回数 / 最悪スパイク値 など）。Ctrl-C は trap で捕捉してサマリを出してから終了。

既存の「read-only・background collection しない・後始末不要」の思想と親和的なフォアグラウンド方式を採用。launchd 常駐は managed な社用 Mac のポリシー懸念もあり不採用。

### tick の仕組み

ping のロス率は 1 発では出ないので、1 周期（tick）ごとに小バッチで測る:

- 1 tick = `physical_gateway`（GW 層）と外部(1.1.1.1) の**両方**に対し `ping_probe <host> PING_COUNT` を実行し、それぞれの `loss avg` を得る。
- **並列実行**: GW と外部の ping はバックグラウンドで並行に打ち、両方を wait する。macOS の `ping` は約 1 秒間隔なので、5 発を直列だと 2 ホストで ~8-10 秒かかる。並列にして 1 tick ≈ 5-6 秒に収める。
  - 実装注: バックグラウンド subshell の結果は親シェル変数へ直接代入できないため、各 probe の `loss avg` は temp file 等に書き出して wait 後に回収する（取りこぼし防止）。
- その tick の avg / loss を閾値と比較 → 超えたら異常行を出す。avg=n/a（100% loss）は「正常」に倒さず、loss 側の閾値で異常判定する。

### 監視対象（GW + 外部、層別判定）

`physical_gateway` と外部(1.1.1.1)の両方を監視し、どちらが崩れたかで層を切り分ける:
- **GW だけ崩れる** → ルーター/ローカル経路寄り（GW は物理ルーターなので Cato の有無に影響されない）
- **両方崩れる** → ISP/WAN 寄り

### 異常行の内容

タイムスタンプ + 崩れた対象 + 実測値 + **その時点の経路分類**（`cato`/`vpn`/`direct`/`unknown`）。
間欠障害と Cato の相関を現行犯で取れるようにする。

例:
```
14:23:07  GW spike avg=312ms loss=0%    [route=cato]
14:31:12  GW loss=40% avg=n/a           [route=cato]
14:52:40  EXT spike avg=410ms loss=20%  [route=direct]
```

### 閾値と設定ファイル: `scripts/net-monitor.conf`（新規・コミットする）

bash で source する形。**guarded assignment（`: "${VAR:=...}"`）で書く**——plain な `VAR=50` だと、source 時に環境変数を上書きしてしまい下記の優先順位が壊れるため:

```sh
# 監視の閾値と tick 設定（編集して恒久的に変えられる）
: "${GW_SPIKE_MS:=50}"    # GW ping avg がこれを超えたら異常
: "${GW_LOSS_PCT:=0}"     # GW loss がこれを超えたら異常
: "${EXT_SPIKE_MS:=150}"  # 外部(1.1.1.1) avg
: "${EXT_LOSS_PCT:=0}"    # 外部 loss
: "${PING_COUNT:=5}"      # 1 tick あたりの ping 発数
: "${GATEWAY:=}"          # 物理GW明示指定（空なら physical_gateway で自動検出）
```

上書きの優先順位（すべて guarded assignment で実現）:
1. コマンドライン / 環境変数（その場限りの一時変更。例 `GW_SPIKE_MS=30 ./scripts/net-monitor.sh`）— 既に set 済みなので conf の `:=` は発火しない → env が勝つ
2. `net-monitor.conf`（恒久的なデフォルト）— env 未設定なら conf 値が入る
3. スクリプト組み込みのフォールバック — conf が無い/未設定なら、`net-common.sh` 側の `: "${VAR:=...}"` で最終フォールバック

読み込み順は「conf を source → net-common.sh 側で組み込みフォールバック」。閾値は `net-common.sh` 経由で読み込み、将来スナップショット診断でも同じ基準を使い回せるようにする。

### 監視ログ

異常行は画面表示に加え `logs/monitor-YYYYMMDD.log` にも残す（後で振り返れる）。
`logs/` は従来通り gitignore。スナップショットの `history.csv` とは **別ファイル**（history=定点観測 1 行、monitor=イベント駆動の異常ログ、で性質が違うので混ぜない）。

---

## `history.csv` への列追加

現在 16 カラム。**17 カラム目 `default_route`（enum: `cato`/`vpn`/`direct`/`unknown`）を追加**する。
run 時点で経路を誰が握っていたかを記録し、「重かった run のとき Cato は経路を握っていたか？」を時系列で相関検証できるようにする（今日の「容疑者だが実はシロ」を思い込みでなくデータで確認する）。

新しいヘッダ（17 カラム）:
```
timestamp,interface,link_status,has_ip,gateway_ip,gateway_loss_pct,gateway_avg_ms,dns_ok,dns_query_ms,ext_ip_loss_pct,ext_ip_avg_ms,ext_host_loss_pct,ext_host_avg_ms,wifi_rssi,wifi_noise,wifi_channel,default_route
```

**ヘッダ移行（初版で抜けていた点）**: 現行 [net-log-run.sh:16-17](../../../scripts/net-log-run.sh:16) はファイルが無い時だけヘッダを書く。既存の 16 列ヘッダのファイルに 17 列行を追記するとズレるため、`net-log-run.sh` で **既存ヘッダが旧 16 列形式なら新ヘッダへ書き換える（1 回きりの migrate）** 処理を入れる。現時点で `history.csv` は未生成（行ゼロ）なので実害は低いが、旧版を 1 回でも回したファイルのために対応する。

**後方互換（report 側）**: [net-history-report.sh](../../../scripts/net-history-report.sh) は行ごとの列数（`NF`）を見て、`default_route` 列が無い旧行は「不明」として扱い、集計を壊さない。

**gateway_avg_ms への波及**: `physical_gateway` を使うことで、Cato 接続中でも GW 列が空でなく実測値になる（従来は空だった）。これは既存バグの修正であり、history の GW 列がようやく Cato 環境でも意味を持つ。

---

## CLAUDE.md への追記

解釈・判断レイヤに以下を足す:
- **Cato の扱い**: 「重い時はまず Cato を手動で切って before/after を比較。ただし Cato は経路を握っていても犯人とは限らない（過去にシロ実績）。断定せず消去法の起点として扱う」。
- **GW の意味**: 「GW 層は物理ルーターを指す（`physical_gateway`）。Cato 接続中でも物理ルーターを計測しているので、GW 崩れ＝ルーター寄りの解釈は VPN の有無に依らず成立する」。
- **継続監視の使いどころ**: 「単発 run で矛盾する（悪い↔治った）間欠障害には `net-monitor.sh` を使い、現行犯で層（GW/外部）と Cato 相関を捕まえる」。
- 断定しすぎないトーンを維持（EMI/Cato で 2 回外した教訓）。

## 変更ファイル一覧

新規:
- `scripts/lib/net-common.sh` — 共有ライブラリ（`ping_loss`/`ping_avg` stdin パーサ + `ping_probe` + `physical_gateway` + `default_route_class` + 閾値読込）
- `scripts/net-cato-check.sh` — Cato 検知（report + 比較推奨）
- `scripts/net-monitor.sh` — 継続監視（フォアグラウンド tick 方式、GW/外部を並列 probe）
- `scripts/net-monitor.conf` — 監視の閾値/設定（guarded assignment、コミットする）

変更:
- `scripts/run.sh` — 実行順に cato を挿入（interface → cato → connectivity → wifi）
- `scripts/net-log-run.sh` — ping ヘルパを net-common.sh に移設して source、GW を `physical_gateway` 経由に、`default_route` 列を追記、旧 16 列ヘッダの migrate
- `scripts/net-history-report.sh` — 17 列対応＋旧 16 列行の後方互換（`NF` 判定）
- `CLAUDE.md` — 解釈ガイド追記

## 非目標（YAGNI）

- launchd 常駐 / background collection（思想と社用 Mac ポリシーに反する）。
- Cato の自動切断や自動 before/after 計測（user 操作を伴うステートフルフロー、read-only 思想外）。
- ISP/WAN 側の診断（既存スコープ外のまま）。

## レビュー反映（Codex gpt-5.5 クロスレビュー、全 8 件を実機裏取りのうえ採用）

1. **[High] VPN 経由時の GW 解釈** → `physical_gateway` を独立取得。実機で Cato 中は `route -n get default` に gateway 行が無く GW ping がスキップされる既存バグを確認、修正対象に。
2. **[High] ping ヘルパの性質** → `ping_loss`/`ping_avg` は stdin パーサのまま。loss/avg を同一サンプルから返す `ping_probe` を新設。
3. **[Med] env 優先順位の矛盾** → `net-monitor.conf` を guarded assignment（`: "${VAR:=...}"`）に。plain 代入だと env を上書きしてしまう点を修正。
4. **[Med] 16→17 ヘッダ移行漏れ** → `net-log-run.sh` に旧ヘッダ migrate、report は `NF` で後方互換。
5. **[Med] `default_route_class` に unknown 不足** → `unknown`（route 取得失敗）を追加。
6. **[Med] tick タイミング / duration 書式** → GW と外部を並列 probe、duration 書式（`30m`/`45s`/秒）を明記。
7. **[Low] 「Cato と特定」が強すぎ** → 「Cato の可能性が高い」に緩和（非断定トーンと整合）。
8. **[Low] utun の inet は nullable、番号決め打ち不可** → 経路を握る utun を route から取得、inet は `n/a` 許容（実機で utun5 が default・inet あり、utun4 は inet 無しを確認）。
