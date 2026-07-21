# .devcontainer

このリポジトリをコンテナ内で Claude Code のサンドボックスとして動かすための devcontainer 定義。
ホストの `~/.claude` を丸ごとマウントせず、egress firewall で通信先を絞ることで
`claude --dangerously-skip-permissions`（`yolo` エイリアス）を安全に使えるようにしている。

## 構成

```
.devcontainer/
├── devcontainer.json            # コンテナ設定（マウント・拡張機能・起動コマンド）
├── Dockerfile                   # Node 20 ベース。Claude Code CLI・gh・ripgrep等を導入
├── init-firewall.sh             # 起動時に適用するegress firewall（デフォルト拒否）
└── docs/
    └── devcontainer-guide.html  # 初心者向け解説資料（1行ずつ「なぜ」を追う）
```

deck-orchestrate 等の skill・agent はリポジトリ相対パス（`.claude/skills/`、`input/`、`output/`）で
完結しており、ホストの絶対パスに依存しない。そのためこのリポジトリの devcontainer.json / Dockerfile は
ユーザー名を含まず、テンプレート（`.example`）なしでそのままコミットできる。

初めてこのディレクトリを読む場合は `docs/devcontainer-guide.html` をブラウザで開くと、
devcontainer.json / Dockerfile / init-firewall.sh を順に、なぜそう書いてあるかまで解説している。

## 前提

- Docker（Docker Desktop など）が起動していること
- VS Code + 拡張機能 [Dev Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)

## 使い方

1. VS Code でこのリポジトリのルート（`generate-deck/`）を開く
2. コマンドパレットから `Dev Containers: Reopen in Container` を実行
3. 初回はイメージビルドが走る（Node 20 + Claude Code CLI + zsh/powerlevel10k + git-delta 等を導入）
4. コンテナ起動後、`postStartCommand` として `init-firewall.sh` が自動実行される（失敗すると起動が止まる）
5. コンテナ内ターミナルで `claude` または `yolo`（`claude --dangerously-skip-permissions` のエイリアス）を実行

初回はコンテナ内で `claude` の認証（OAuthログイン）が必要。認証情報は下記のボリュームに永続化されるため、次回以降のリビルドでは再ログイン不要。

## 何をしているか

### ワークスペースのマウント

`workspaceMount` / `workspaceFolder` は指定せず、Dev Containers のデフォルトである
`/workspaces/generate-deck` にホストのリポジトリをそのままバインドマウントする。
skill・CLAUDE.md がリポジトリ相対パス前提なので、絶対パスをホストと揃える必要がない。

### 認証情報・履歴の永続化（`mounts`）

| マウント                                    | 内容                           | 目的                                                                                                                       |
| -------------------------------------------- | ------------------------------ | -------------------------------------------------------------------------------------------------------------------------- |
| `claude-deck-bashhistory-${devcontainerId}` | `/commandhistory`              | シェル履歴をリビルド後も保持                                                                                               |
| `claude-deck-config-${devcontainerId}`      | `/home/node/.claude`           | Claude Code の認証トークン・設定を保持                                                                                     |
| `~/.claude/CLAUDE.md`（read-only bind）      | `/home/node/.claude/CLAUDE.md` | グローバルCLAUDE.md（projects-wiki参照ルール等）だけを共有。`~/.claude` 丸ごとマウントはホストの認証情報が漏れるため行わない。projects-wiki自体はマウントしていないため、その参照ルールはコンテナ内では実行できない点に注意 |

### 非rootユーザー（`remoteUser: node`）

`--dangerously-skip-permissions` はrootユーザーでは拒否されるため、`node` ユーザーで実行する。

### egress firewall（`init-firewall.sh`）

コンテナ起動のたびに iptables/ipset でデフォルト拒否のfirewallを構築し、以下のみ許可する:

- GitHub の IP レンジ（`api.github.com/meta` から動的取得）
- 個別に許可した既知ドメイン: `registry.npmjs.org` / `api.anthropic.com` / `claude.ai` / `console.anthropic.com`（OAuthトークン交換用）/ `platform.claude.com` / `sentry.io` / `statsig.anthropic.com` / `statsig.com` / `raw.githubusercontent.com` / VS Code Marketplace 関連ドメイン
- DNS（コンテナに設定されたリゾルバ宛のみ）、localhost、ESTABLISHED/RELATED な戻り通信

適用後に `https://example.com` へ到達できない（拒否される）ことと `https://api.github.com` へ到達できることを自己検証し、
どちらかが失敗すると `postStartCommand` がエラー終了してコンテナ起動が止まる（`waitFor: postStartCommand`）。
途中でエラーが起きた場合も `trap ERR` により即座に全ポリシーをDROPする fail-close 構成になっている。

`--cap-add=NET_ADMIN` / `--cap-add=NET_RAW`（`runArgs`）は、このfirewall構築（iptables/ipset操作）に必要な権限。

## 通信を許可するドメインを追加したい場合

`init-firewall.sh` の `for domain in ...` リストにドメインを追加し、コンテナを再起動する
（`postStartCommand` は起動のたびに実行されるため再ビルド不要、コンテナ再起動のみでよい）。

## トラブルシューティング

- **`postStartCommand` が失敗してコンテナが起動しない**: firewall検証（`example.com` に到達できない／`api.github.com` に到達できる）のいずれかで失敗している。追加が必要な通信先がないか `init-firewall.sh` を確認する
- **Claude Code の認証が毎回リセットされる**: `claude-deck-config-${devcontainerId}` ボリュームが正しくマウントされているか、コンテナを削除して作り直していないか確認する
- **output/ に生成物が反映されない**: `output/` はホストと同じ相対パスでバインドマウントされているはず。コンテナ内 `pwd` が `/workspaces/generate-deck` になっているか確認する
