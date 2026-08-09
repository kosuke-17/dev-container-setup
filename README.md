# dev-container-setup

`claude --dangerously-skip-permissions`（通称 yolo モード）を、ホストPCから隔離した
コンテナ内で動かすための **devcontainer テンプレート**。

任意のリポジトリのルートに `.devcontainer/` をコピーして使う。

## これは何を防ぎ、何を防がないか

**防げること**

- ホストの `~/.ssh` / `~/.claude` / その他ホストファイルへの直接アクセス（マウントしていない）
- ホストの Claude 認証トークンのコンテナへの流出（`~/.claude` は丸ごとマウントせず、`CLAUDE.md` だけ read-only 共有）
- コンテナ内からの設定ファイル自己書き換え → 次回リビルドでの権限昇格（`.devcontainer` を read-only で上書きマウント）
- 許可していないドメインへの通信（iptables/ipset によるデフォルト拒否の egress firewall、IPv6 は全遮断）

**防げないこと（重要）**

- ipset 構築中の一時的な HTTPS 全開放ウィンドウ（`sudo init-firewall.sh` の再実行で任意に再現できる）
- fail-close の取りこぼし（`exit 1` 経路では ERR trap が発火しない）
- 共有CDN・GitHub 経由のデータ持ち出し（IPベース許可リストの原理的限界）
- ワークスペース自体の破壊（rw マウントなので `.git` ごと消せる）

**「完全に安全な環境」ではない。** 詳細は `.devcontainer/ai-reviews/` の2本のセキュリティレビューに
一次情報としてまとめてある。導入前に必ず読むこと。

## 使い方

1. この repo の `.devcontainer/` をサンドボックス化したいリポジトリのルートにコピーする
2. `.devcontainer/devcontainer.json` の `★要編集` コメント箇所を調整する
3. VS Code で `Dev Containers: Reopen in Container` を実行
4. コンテナ内で `claude` または `yolo` を実行

詳しい手順・設計意図・残存リスクは [`.devcontainer/README.md`](.devcontainer/README.md) を参照。
1行ずつ「なぜそう書いてあるか」を追う解説資料が
[`.devcontainer/docs/devcontainer-guide.html`](.devcontainer/docs/devcontainer-guide.html) にある（ブラウザで開く）。

## 前提

- Docker（Docker Desktop など）
- VS Code + [Dev Containers 拡張](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)

## 由来

Anthropic が公開している Claude Code のリファレンス devcontainer をベースに、
AIによるセキュリティレビュー（`.devcontainer/ai-reviews/`）の指摘を反映したもの。

## ライセンス

MIT
