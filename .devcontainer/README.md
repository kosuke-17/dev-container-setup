# .devcontainer

任意のリポジトリをコンテナ内で Claude Code のサンドボックスとして動かすための devcontainer 定義。
ホストの `~/.claude` を丸ごとマウントせず、egress firewall で通信先を絞ることで
`claude --dangerously-skip-permissions`（`yolo` エイリアス）を扱いやすくすることを狙っている。

> **これは「完全に安全」な環境ではない。** 既知の未対応な穴が残っている。
> 何が防げていて何が防げていないかは `ai-reviews/` の2本のレビューを必ず読むこと。
> 特に 2026-07-21 の再レビューで指摘された High-1 / High-2 は**未修正**。

## 構成

```
.devcontainer/
├── devcontainer.json            # コンテナ設定（マウント・拡張機能・起動コマンド・ポート転送）
├── Dockerfile                   # Node 20 ベース。Claude Code CLI・gh・ripgrep等を導入
├── init-firewall.sh             # 起動時に適用するegress firewall（デフォルト拒否）
├── ai-reviews/                  # このdevcontainerに対するセキュリティレビュー（残存リスクの一次情報）
└── docs/
    └── devcontainer-guide.html  # 初心者向け解説資料（1行ずつ「なぜ」を追う）
```

初めてこのディレクトリを読む場合は `docs/devcontainer-guide.html` をブラウザで開くと、
devcontainer.json / Dockerfile / init-firewall.sh を順に、なぜそう書いてあるかまで解説している。

## 前提

- Docker（Docker Desktop など）が起動していること
- VS Code + 拡張機能 [Dev Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)

## 導入手順

1. この `.devcontainer/` ディレクトリを、サンドボックス化したいリポジトリのルートにコピーする
2. `devcontainer.json` の `★要編集` コメントが付いた箇所を、導入先に合わせて調整する
   - `name`: VS Code のウィンドウ表示名
   - ボリューム名のプレフィックス（任意。`docker volume ls` での判別用）
   - `~/.claude/CLAUDE.md` の read-only bind（ホストに無いならこの行を削除する）
   - `forwardPorts` / `postCreateCommand`（dev サーバーや依存インストールが必要な場合）
3. 通信を許可したいドメインがあれば `init-firewall.sh` の `for domain in ...` に追加する
4. `.devcontainer/` を **git 管理下に置く**（後述。untracked のままだと改変を検知できない）

## 使い方

1. VS Code で導入先リポジトリのルートを開く
2. コマンドパレットから `Dev Containers: Reopen in Container` を実行
3. 初回はイメージビルドが走る（Node 20 + Claude Code CLI + zsh/powerlevel10k + git-delta 等を導入）
4. コンテナ起動後、`postStartCommand` として `init-firewall.sh` が自動実行される
5. コンテナ内ターミナルで `claude` または `yolo`（`claude --dangerously-skip-permissions` のエイリアス）を実行

初回はコンテナ内で `claude` の認証（OAuthログイン）が必要。認証情報は名前付きボリュームに永続化されるため、次回以降のリビルドでは再ログイン不要。

## 何をしているか

### ワークスペースのマウント

`workspaceMount` / `workspaceFolder` は指定せず、Dev Containers のデフォルトである
`/workspaces/<リポジトリ名>` にホストのリポジトリをそのままバインドマウントする。
skill・CLAUDE.md がホストの絶対パスを前提にしている場合だけ、`workspaceMount` で
ホストと同一の絶対パスに固定する必要がある。

### 認証情報・履歴の永続化（`mounts`）

| マウント                                          | 内容                           | 目的                                                                                                     |
| ------------------------------------------------- | ------------------------------ | -------------------------------------------------------------------------------------------------------- |
| `claude-sandbox-bashhistory-${devcontainerId}`    | `/commandhistory`              | シェル履歴をリビルド後も保持                                                                             |
| `claude-sandbox-claude-config-${devcontainerId}`  | `/home/node/.claude`           | Claude Code の認証トークン・設定を保持                                                                   |
| `~/.claude/CLAUDE.md`（read-only bind）           | `/home/node/.claude/CLAUDE.md` | グローバルCLAUDE.mdだけを共有。`~/.claude` 丸ごとマウントはホストの認証情報が漏れるため行わない          |
| `.devcontainer`（read-only bind）                 | `<workspace>/.devcontainer`    | rw の workspace マウントの上に read-only で重ね、コンテナ内からの自己書き換えを防ぐ                      |

グローバルCLAUDE.md が外部ディレクトリ（Obsidian Vault 等）を参照するルールを含む場合、
その参照先はマウントされていないためコンテナ内では実行できない点に注意。

### 非rootユーザー（`remoteUser: node`）

`--dangerously-skip-permissions` はrootユーザーでは拒否されるため、`node` ユーザーで実行する。

### egress firewall（`init-firewall.sh`）

コンテナ起動のたびに iptables/ipset でデフォルト拒否のfirewallを構築し、以下のみ許可する:

- GitHub の IP レンジ（`api.github.com/meta` から動的取得）
- 個別に許可した既知ドメイン: `registry.npmjs.org` / `api.anthropic.com` / `claude.ai` / `console.anthropic.com`（OAuthトークン交換用）/ `platform.claude.com` / `sentry.io` / `statsig.anthropic.com` / `statsig.com` / `raw.githubusercontent.com` / VS Code Marketplace 関連ドメイン / `fonts.googleapis.com` / `fonts.gstatic.com`
- DNS（コンテナに設定されたリゾルバ宛のみ）、localhost、ESTABLISHED/RELATED な戻り通信

IPv6 は制御対象外にできないため `ip6tables` で全遮断する。
適用後に `https://example.com` へ到達できない（拒否される）ことと `https://api.github.com` へ到達できることを自己検証する。

`--cap-add=NET_ADMIN` / `--cap-add=NET_RAW`（`runArgs`）は、このfirewall構築（iptables/ipset操作）に必要な権限。

## 既知の残存リスク（重要）

`ai-reviews/2026-07-21-devcontainerセキュリティ再レビュー.md` の指摘のうち、以下は**未修正のまま**:

- **fail-close が不完全**: `trap fail_close ERR` はポリシーを DROP にするだけでルールをフラッシュしないため、
  ipset 構築中の一時許可 `--dport 443 -j ACCEPT` が失敗時に残存しうる。さらに明示的な `exit 1` では
  ERR trap が発火しない（bash 仕様）。つまり「途中で失敗したら必ず全遮断される」とは言い切れない。
- **`sudo init-firewall.sh` の再実行で一時全開放ウィンドウを再現できる**: node ユーザーは承認なしに
  再実行でき、そのたび ipset 構築完了までの数秒間 443 が全宛先に開く。
- **DNS トンネリング**: リゾルバ宛に限定しても、再帰リゾルバ経由で攻撃者の権威サーバへは到達する。
- **共有CDN経由 / GitHub経由の exfiltration**: IPベース許可リストの原理的限界。
  コンテナ内の GitHub 認証は対象リポジトリのみに限定した fine-grained PAT（gist 権限なし）を使うこと。
- **ワークスペースは rw**: コンテナ内から `.git` を含めて全削除・改竄が可能。リモートへの定期 push と
  ホスト側バックアップを前提に運用する。

`.devcontainer/` は必ず git 管理下に置き、コンテナ作業後に `git log -p .devcontainer` で
改変がないことを確認してからリビルドすること（read-only マウントは直接改変を防ぐが、
`.git` 経由で仕込まれたコミットまでは防げない）。

## 通信を許可するドメインを追加したい場合

`init-firewall.sh` の `for domain in ...` リストにドメインを追加し、コンテナを再起動する
（`postStartCommand` は起動のたびに実行されるため再ビルド不要、コンテナ再起動のみでよい）。

## トラブルシューティング

- **`postStartCommand` が失敗する**: firewall検証（`example.com` に到達できない／`api.github.com` に到達できる）のいずれかで失敗している。追加が必要な通信先がないか `init-firewall.sh` を確認する。なお `waitFor: postStartCommand` はエラーを表示するだけで、コンテナ自体は使える状態で残る点に注意
- **コンテナ作成時に `~/.claude/CLAUDE.md` のマウントで失敗する**: ホストにそのファイルが存在しない。作成するか、`devcontainer.json` の該当マウント行を削除する
- **Claude Code の認証が毎回リセットされる**: `claude-sandbox-claude-config-${devcontainerId}` ボリュームが正しくマウントされているか、コンテナを削除して作り直していないか確認する
- **`npm run dev` は動くのにホストのブラウザから見えない**: `devcontainer.json` の `forwardPorts` にポート番号が含まれているか確認する。VS Code の「ポート」タブでも手動転送できる
- **外部からフォントやパッケージを取得できない**: `init-firewall.sh` の許可リストにそのドメインが含まれているか確認する
