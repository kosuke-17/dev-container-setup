#!/bin/bash
set -euo pipefail  # Exit on error, undefined vars, and pipeline failures
IFS=$'\n\t'       # Stricter word splitting

# fail-close: スクリプトが途中で失敗したら、firewall未構築のまま起動が続かないよう
# 即座に全ポリシーをDROPにする（旧版は成功時のみDROPを設定していたため、
# GitHub API取得失敗等で早期終了すると全開放のまま動き続ける穴があった）。
fail_close() {
    echo "ERROR: firewall setup failed midway - dropping all traffic to fail closed" >&2
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT DROP
    command -v ip6tables >/dev/null 2>&1 && {
        ip6tables -P INPUT DROP
        ip6tables -P FORWARD DROP
        ip6tables -P OUTPUT DROP
    }
}
trap fail_close ERR

# 1. Extract Docker DNS info BEFORE any flushing
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# Flush existing rules and delete existing ipsets
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# 2. Selectively restore ONLY internal Docker DNS resolution
if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
    echo "No Docker DNS rules to restore"
fi

# IPv6 は制御対象外だったため無条件で遮断する（iptables(IPv4)ルールだけでは
# IPv6が有効な環境でegressが素通りしてしまう）
if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -F
    ip6tables -X
    ip6tables -P INPUT DROP
    ip6tables -P FORWARD DROP
    ip6tables -P OUTPUT DROP
    echo "IPv6 traffic fully disabled"
else
    echo "WARNING: ip6tables not found - IPv6 is not explicitly blocked"
fi

# 先にデフォルト拒否ポリシーを設定してから、必要な穴だけを開けていく
# （旧版はこのDROP設定がスクリプト末尾にあり、途中で失敗すると全開放のまま
#   起動し続ける fail-open な構成だった）
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# Allow localhost
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Allow established/related connections (戻り通信)
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# DNSはコンテナに設定されたリゾルバ宛のみ許可する。
# 任意の外部DNSサーバへのクエリを許すとDNSトンネリングによる
# データ持ち出し経路になるため、全宛先への許可はしない。
# リゾルバのIPは環境によって異なる（Linux上のDocker Engineでは内蔵DNSの
# 127.0.0.11、Docker Desktop for Macではホスト側VMのIP等）ため、
# /etc/resolv.conf から実際のnameserverを動的に取得して許可する。
DNS_SERVERS=$(awk '/^nameserver/ {print $2}' /etc/resolv.conf)
if [ -z "$DNS_SERVERS" ]; then
    echo "ERROR: No nameserver found in /etc/resolv.conf" >&2
    exit 1
fi
while read -r dns; do
    if [[ ! "$dns" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "ERROR: Invalid nameserver IP in /etc/resolv.conf: $dns" >&2
        exit 1
    fi
    echo "Allowing DNS resolver: $dns"
    iptables -A OUTPUT -p udp --dport 53 -d "$dns" -j ACCEPT
    iptables -A INPUT -p udp --sport 53 -s "$dns" -j ACCEPT
done <<< "$DNS_SERVERS"

# SSH(22番)の全宛先向け許可は行わない。任意サーバへのSSHポートフォワードで
# egress制限を丸ごと迂回できてしまうため。GitHub向けSSH(git@github.com)が
# 必要な場合は、後段で allowed-domains に追加されるGitHub IPレンジ宛の
# 通信としてまとめて許可される（ポート番号を問わない）。

# 許可ドメイン群のIP取得中(GitHub API呼び出し・DNS解決)は、まだ
# allowed-domains ipsetが空のため、一時的にHTTPS(443)のみ全宛先へ許可する。
# ipset構築が終わり次第この一時許可は撤回し、allowed-domains宛のみに絞る。
iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT

# Create ipset with CIDR support
ipset create allowed-domains hash:net

# Fetch GitHub meta information and aggregate + add their IP ranges
echo "Fetching GitHub IP ranges..."
gh_ranges=$(curl -s https://api.github.com/meta)
if [ -z "$gh_ranges" ]; then
    echo "ERROR: Failed to fetch GitHub IP ranges"
    exit 1
fi

if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null; then
    echo "ERROR: GitHub API response missing required fields"
    exit 1
fi

echo "Processing GitHub IPs..."
while read -r cidr; do
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "ERROR: Invalid CIDR range from GitHub meta: $cidr"
        exit 1
    fi
    echo "Adding GitHub range $cidr"
    ipset add -exist allowed-domains "$cidr"
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git + .pages)[]' | aggregate -q)

# Resolve and add other allowed domains
# claude.ai / console.anthropic.com はOAuthログインのトークン交換に必要
for domain in \
    "registry.npmjs.org" \
    "api.anthropic.com" \
    "claude.ai" \
    "console.anthropic.com" \
    "platform.claude.com" \
    "sentry.io" \
    "statsig.anthropic.com" \
    "statsig.com" \
    "raw.githubusercontent.com" \
    "marketplace.visualstudio.com" \
    "vscode.blob.core.windows.net" \
    "update.code.visualstudio.com"; do
    echo "Resolving $domain..."
    ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
    if [ -z "$ips" ]; then
        # レコードが消えたドメイン（例: statsig.anthropic.com）で全体を止めない。
        # 解決できない=到達もできないので許可リスト追加は不要
        echo "WARNING: Failed to resolve $domain - skipping"
        continue
    fi

    while read -r ip; do
        if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "ERROR: Invalid IP from DNS for $domain: $ip"
            exit 1
        fi
        echo "Adding $ip for $domain"
        ipset add -exist allowed-domains "$ip"
    done < <(echo "$ips")
done

# allowed-domains宛の通信を許可し、ipset構築のために一時的に開けていた
# HTTPS全宛先許可は撤回する（以後はallowed-domains宛のみに絞る）
iptables -D OUTPUT -p tcp --dport 443 -j ACCEPT
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# ホストと同一サブネットへの全許可は行わない。ホスト上で認証なしにlistenして
# いるサービス（ローカルLLM、開発用DB等）への横展開経路になるため。
# コンテナ⇔ホスト間で戻り通信が必要な分はESTABLISHED,RELATEDルールで賄える。

# Explicitly REJECT all other outbound traffic for immediate feedback
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

echo "Firewall configuration complete"
echo "Verifying firewall rules..."
if curl --connect-timeout 5 https://example.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - was able to reach https://example.com"
    exit 1
else
    echo "Firewall verification passed - unable to reach https://example.com as expected"
fi

# Verify GitHub API access
if ! curl --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - unable to reach https://api.github.com"
    exit 1
else
    echo "Firewall verification passed - able to reach https://api.github.com as expected"
fi

# ここまで到達すれば構築は成功しているため、以降の予期しないエラーで
# fail-closeが誤発火しないようtrapを解除する
trap - ERR
