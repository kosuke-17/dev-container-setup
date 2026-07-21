# .devcontainer セキュリティレビュー（2026-07-18）

対象: `.devcontainer/devcontainer.json` / `Dockerfile` / `init-firewall.sh` / `README.md`
目的: 「`claude --dangerously-skip-permissions` を承認なしで安全に動かせる完全に安全な環境か」の評価。
脅威モデル: プロンプトインジェクション等で、コンテナ内の Claude が悪意ある動作をする前提で評価する（Vault には Web クリップ記事を ingest する運用があるため、これは現実的な前提）。

## 総合評価

**「ホストPCの他領域には手が届かない」という点ではよくできているが、「完全に安全」ではない。**
大きな穴が2系統残っている:

1. **将来のコンテナを乗っ取る経路** — `.devcontainer/` 自体が書き込み可能な状態でコンテナにマウントされているため、コンテナ内の Claude が `devcontainer.json` を書き換えれば、次回リビルド時に任意のホストディレクトリ（`~/.ssh` や `~` 全体）をマウントさせられる
2. **データ持ち出し経路（exfiltration）** — SSH全開放・DNS全開放・IPv6未制御・fail-open な firewall により、egress 制限は複数の方法で迂回できる

また「PC は無事でも Vault は全損しうる」（rw マウント + `.git` ごと削除可能）というデータ面のリスクは設計上受容していることになるので、バックアップ前提の運用が必要。

### 良くできている点

- 非rootユーザー実行（`--dangerously-skip-permissions` の要件も満たす）
- ホストの `~/.claude` を丸ごとマウントせず、`CLAUDE.md` のみ read-only で共有（ホストの認証トークンはコンテナに渡らない）
- デフォルト拒否の egress firewall + 起動時の自己検証（example.com 不達 / api.github.com 到達）
- sudo を firewall スクリプト1本（root所有・node書き込み不可）に限定
- 認証情報は名前付きボリュームに隔離
- Vault をホストと同一絶対パスにマウントし、skill の絶対パス前提を維持

---

## 指摘事項（重要度順）

### 🔴 High-1: `.devcontainer/` がコンテナから書き換え可能 → 次回リビルドでホスト侵害に昇格できる

Vault 全体が rw でマウントされているため、`.devcontainer/devcontainer.json` / `Dockerfile` / `init-firewall.sh` もコンテナ内から編集できる。悪意ある動作をした Claude が

- `devcontainer.json` の `mounts` に `~/.ssh` や `${localEnv:HOME}` を追加する
- `postStartCommand` を差し替える / `init-firewall.sh` を無害化する

と仕込んだ場合、**次に「Rebuild Container」した瞬間に発動**する。VS Code の「設定が変わったのでリビルドしますか？」に習慣的に Yes と答える運用だと気づけない。

**対策**: `.devcontainer/` を read-only bind で上書きマウントする（rw の workspaceMount の上に重ねられる）:

```jsonc
// devcontainer.json の mounts に追加
"source=${localWorkspaceFolder}/.devcontainer,target=/Users/xxx/Documents/Obsidian Vault/.devcontainer,type=bind,readonly"
```

加えて `.devcontainer/` を git 管理下に入れ（現在 untracked）、リビルド前に diff が見える状態にする。

### 🔴 High-2: firewall が fail-open（失敗すると全開放のまま動き続ける）

`init-firewall.sh` は最初に全ルールをフラッシュし（この時点でポリシーはACCEPT）、**DROP ポリシー設定は GitHub meta 取得の後**（115行目）にある。`set -e` なので GitHub API 取得失敗・DNS解決の異常などで途中終了すると、**firewall が一切ない状態でコンテナが動き続ける**。`waitFor: postStartCommand` はエラーを表示するだけで、コンテナ自体は使える。

さらに sudoers により node ユーザー（= Claude 自身）が承認なしでこのスクリプトを再実行できるため、「途中で失敗させて全開放にする」試行が可能な設計になっている。

**対策**: fail-close にする。スクリプト冒頭に:

```bash
fail_close() {
  iptables -P INPUT DROP; iptables -P OUTPUT DROP; iptables -P FORWARD DROP
  echo "ERROR: firewall setup failed — all traffic dropped" >&2
}
trap fail_close ERR
```

あるいはフラッシュ直後に先に DROP ポリシーを設定してから許可ルールを積む順に変える（lo と DNS を先に許可すれば構築中も動く）。

### 🔴 High-3: SSH（TCP 22）が全宛先に開放されている

```
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
```

任意のサーバへ SSH できる = **ssh のポートフォワードで任意の通信をトンネルできる**ため、ドメイン許可リストは事実上迂回可能。意図が GitHub への git+ssh なら、GitHub の IP レンジ（既に ipset に入っている）に限定すべき。

**対策**:

```bash
# 全開放の2行を削除し、allowed-domains 宛のみ許可（124行目のルールで22番もカバーされる）
```

HTTPS で git を使うなら 22 番の許可自体を削除してよい。

### 🔴 High-4: DNS（UDP 53）が全宛先に開放されている

任意の DNS サーバへクエリを送れるため、**DNSトンネリングによるデータ持ち出し**が可能（攻撃者のネームサーバへのクエリにデータを載せる古典的手法）。名前解決は Docker 内蔵 DNS（127.0.0.11）経由で足りる。

**対策**:

```bash
iptables -A OUTPUT -p udp --dport 53 -d 127.0.0.11 -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j REJECT
```

（Docker の embedded DNS は nat テーブルで転送されるため、復元している DOCKER_OUTPUT ルールとの整合は要動作確認。）

### 🟠 Medium-1: IPv6 が一切制御されていない

スクリプトは iptables（IPv4）のみ。Docker ネットワークで IPv6 が有効な環境では**全 egress が素通し**になる。現状の Docker Desktop デフォルトでは無効なことが多いが、設定依存の安全性は「完全に安全」とは言えない。

**対策**: `ip6tables -P INPUT DROP / OUTPUT DROP / FORWARD DROP` を無条件に追加（要 `ip6tables` パッケージ確認）。

### 🟠 Medium-2: IPベース許可リストの構造的限界（共有CDN）

`claude.ai` / `sentry.io` / `statsig.com` は Cloudflare 等の共有 CDN 配下にあり、許可した edge IP は**同じ IP で配信されている無数の他ドメインにも到達できる**（SNI を変えるだけ）。つまり実質「Cloudflare 経由の任意サイト」への exfil 経路が残る。IP フィルタの原理的限界なので、厳密にやるなら SNI ベースのフィルタリングプロキシ（Squid の SSL peek 等）が必要。まずは残存リスクとして認識しておくべき。

### 🟠 Medium-3: ホスト側サービスに到達できる（bridge サブネット /24 全許可）

`HOST_NETWORK` への INPUT/OUTPUT 全許可により、**ホストで listen しているサービス（ローカルLLM、開発用DB、内部APIなど認証なしで動かしがちなもの）へ bridge ゲートウェイ経由でアクセスできる**。同一 bridge 上の他コンテナにも到達可能。

**対策**: 必要なのは通常「戻り通信」だけなので、この2行は削除するか、必要な特定ポートに限定する。

### 🟠 Medium-4: GitHub 全体への書き込みが exfil 経路になる（設計上の受容事項）

GitHub の全 IP レンジが許可されており、コンテナ内で `gh` 認証すれば、その認証情報で**私有データを public gist / repo に push して持ち出す**ことが可能。GitHub を使う以上ゼロにはできないが、被害範囲は絞れる。

**対策**: コンテナ内の GitHub 認証は、対象リポジトリのみに限定した fine-grained PAT（gist 権限なし）を使う。ホストと同じ広い権限のトークンを持ち込まない。

### 🟠 Medium-5: Vault 全体が消失しうる（データ面のブラスト半径）

rw マウントなので、Claude は Vault の全ノート削除・改竄ができ、**`.git` ディレクトリも書き込み可能なので履歴ごと消せる**。gitignore された生成物や push していないコミットは復元不能。また Vault 内のノートに書かれた秘密情報（APIキー等をメモしていれば）はすべて読める。

**対策**: (1) リモートへの定期 push を習慣化、(2) Time Machine 等ホスト側バックアップの対象であることを確認、(3) 秘密情報を Vault のノートに書かない運用。

### 🟡 Low（まとめて）

- **`CLAUDE_CODE_VERSION=latest` が未固定** — ビルドごとに中身が変わる。バージョン固定推奨
- **zsh-in-docker を curl | sh 実行** — ビルド時のサプライチェーン信頼。バージョンは固定済みだがチェックサム検証はない
- **node が `/usr/local/share/npm-global` に書ける** — Claude が `claude` バイナリ自体を差し替え可能（自己改竄。sandbox 外への影響はないが検知しにくくなる）
- **`CLAUDE.md` の単一ファイル bind** — ホスト側でエディタが rename 保存すると inode が変わり、コンテナ側に反映されなくなることがある
- **`sentry.io` / `statsig.*` の許可** — テレメトリを送らない運用なら削って許可リストを最小化できる

---

## 推奨対応の優先順位

| 優先度 | 対応 | 効果 |
|---|---|---|
| 1 | firewall を fail-close 化（trap ERR） | 全開放状態の発生を根絶 |
| 2 | SSH 全開放を削除（allowed-domains に統合） | 最大の迂回路を閉鎖 |
| 3 | DNS を 127.0.0.11 宛に限定 | DNSトンネリング exfil を閉鎖 |
| 4 | `.devcontainer/` を read-only 上書きマウント + git 管理 | 次回リビルド経由のホスト侵害を遮断 |
| 5 | ip6tables で IPv6 を DROP | 環境依存の素通りを排除 |
| 6 | HOST_NETWORK 全許可を削除 | ホスト内サービスへの横展開を遮断 |
| 7 | fine-grained PAT / バックアップ運用 | 被害範囲の限定 |

1〜6 は `.devcontainer` 内の修正だけで完結する。7 は運用ルール。

## 結論

現状は Anthropic のリファレンス実装に忠実で、**「ホストの認証情報・ファイルシステムには直接手が届かない」レベルは達成している**。ただし「完全に安全」を「悪意ある動作をしても (a) ホストに被害が及ばず (b) データを持ち出せない」と定義するなら、(a) は High-1（.devcontainer 書き換え→リビルド）で、(b) は High-3/4・Medium-2（SSH/DNS/共有CDN）で破られる。上表 1〜6 を適用すれば、残存リスクは「共有CDN経由の exfil」と「GitHub 経由の exfil」の2点に絞られ、そこは PAT の権限最小化と Vault に秘密を置かない運用でカバーする、という整理になる。
