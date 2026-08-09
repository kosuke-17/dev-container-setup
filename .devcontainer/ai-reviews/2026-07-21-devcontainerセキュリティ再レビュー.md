# .devcontainer セキュリティ再レビュー（2026-07-21）

対象: `.devcontainer/devcontainer.json` / `Dockerfile` / `init-firewall.sh` / `README.md`
前提: 2026-07-18 レビューの指摘（fail-close 化・SSH 閉鎖・DNS 限定・IPv6 遮断・`.devcontainer` read-only 上書きマウント・ホストサブネット許可削除）は反映済みであることを確認した上での再レビュー。
脅威モデル: 前回同様、コンテナ内の Claude（`--dangerously-skip-permissions`）が悪意ある動作をする前提。

> **対応状況（2026-08-09 追記）**: High-1 / High-2 は修正済み。
> `fail_close` にルールのフラッシュを追加し、エラー終了を `die` 関数経由に統一（High-1）。
> 一時 443 許可に `-m owner --uid-owner 0` を付与（High-2。`xt_owner` 非対応環境では警告付きで全開放にフォールバック）。
> Docker コンテナ上で、正常系の一時許可撤回と、GitHub API 取得失敗を注入した異常系での全遮断（`-P OUTPUT DROP` かつルール0件）を実測して確認した。
> Medium 以下（DNSトンネリング・共有CDN/GitHub経由 exfil・`.git` 経由の間接改変・Low 各項）は未対応。

## 総合評価

前回の主要な穴は塞がれており設計思想は健全。ただし **fail-close の実装に抜けがあり、失敗時に「443 全宛先 ACCEPT」が残存する**穴が現存する。また node ユーザーが sudo 再実行で一時全開放ウィンドウを任意に再現できる。

## 🔴 High-1: fail-close が不完全 — 失敗時に 443 全宛先 ACCEPT が残存

`init-firewall.sh:100` の一時許可 `iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT` が、撤回（164行目）前の失敗で残る。

1. `trap fail_close ERR` はポリシーを DROP にするだけで**ルールをフラッシュしない**。ポリシー DROP は残存 ACCEPT ルールに勝てないため、trap 発火後も任意宛先 HTTPS exfil が可能。
2. **明示的な `exit 1` では ERR trap は発火しない**（bash 仕様）。110/115/122/155 行目の `exit 1` 経路はいずれも 443 開放後にあり、trap すら通らない。

README の「trap ERR により fail-close」という記述は現実装では成立していない。
176-181 行の自己検証失敗（example.com に到達できた場合）の `exit 1` も同様に素通し。

**対策**: fail_close に `iptables -F` を追加し、`exit 1` を die 関数（fail_close してから exit）経由に統一する。

## 🔴 High-2: node が sudo 再実行で「443 全開放ウィンドウ」を任意に再現できる

sudoers（Dockerfile:89）により node は承認なしで `sudo init-firewall.sh` を再実行でき、実行のたびに ipset 構築完了までの数秒間 443 が全宛先に開く。バックグラウンドで exfil 用 curl をループさせつつ再実行すれば確実に突ける。

**対策**: 一時許可を root プロセス限定にする（スクリプト内の curl/dig は root で動くため機能維持）:

```bash
iptables -A OUTPUT -p tcp --dport 443 -m owner --uid-owner 0 -j ACCEPT
# 撤回側も同じ指定で -D
```

High-1 でルールが残存した場合の被害も「root のみ」に縮小され、多層防御になる。

## 🟠 Medium

- **DNS トンネリングはリゾルバ限定でも成立**: 再帰リゾルバ経由で攻撃者ドメインの権威サーバへクエリは転送されるため（iodine 等）、リゾルバ限定は直接接続型を塞ぐだけ。帯域が細く実害は限定的だが「塞げた」と認識しないこと。スクリプトコメント・README の記述修正推奨。
- **`.git` rw による間接的ホスト侵害経路**: ro マウントで直接改変は防げているが、Claude が悪意あるコミットを `.git` に仕込み、ホスト側で `git reset --hard` / `checkout` させれば ro マウントの外でファイルが差し替わる。かつ `.devcontainer/` は **untracked のまま**（前回推奨未対応）で差分検知不能。→ コミットし、コンテナ作業後の reset/checkout 前に `git log -p .devcontainer` を確認する運用に。
- **共有 CDN 経由 exfil**（claude.ai / sentry.io / statsig.com の edge IP 共有）と **GitHub 経由 exfil**（gist/repo push）は前回同様の残存リスク（IP フィルタの原理的限界）。fine-grained PAT 運用推奨は継続。

## 🟡 Low

- `CLAUDE_CODE_VERSION=latest` 未固定（前回指摘、未対応）
- `Dockerfile:33` `chown -R node:node /usr/local/share` は広すぎ → `npm-global` のみに絞る
- zsh-in-docker の `wget | sh`・git-delta .deb のチェックサム未検証
- `init-firewall.sh:89` の `INPUT --sport 53` 許可は ESTABLISHED で賄えるため冗長（削除可）
- README:35「失敗すると起動が止まる」は不正確（waitFor はエラー表示まで。コンテナは動き続ける）

## 推奨対応順

1. fail_close にフラッシュ追加 + `exit 1` を die 経由に統一（High-1）
2. 一時 443 許可に `-m owner --uid-owner 0`（High-2）
3. `.devcontainer/` をコミット + リビルド前 diff 確認の運用化
4. DNS トンネリング記述の修正
5. Low 各項

1・2 は `init-firewall.sh` 内の数行で完結する。
