#!/usr/bin/env bash
# 把本机 ~/.agents/AGENTS.md 投影成镜像里的测试夹具。
#
# 为什么需要这一步：作者本机跑测试时，夹具必须是**真实**的指令层，而不是"长得像"的替身。
# 而 guest 里没有网卡、也挂不了宿主目录，唯一能把文件送进去的方式是烧进镜像。
#
# 写的是 AGENTS.local.md（已在 .gitignore 里）：仓库里那份 AGENTS.md 是中性夹具，
# 公开版靠它保证别人也能跑；本机这份真实投影只存在本地，不进 git、不公开。
# 头部记下来源路径与原文 sha256，任何一次构建都能追溯它投影的是哪一份内容。
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=${AGENTS_MD:-$HOME/.agents/AGENTS.md}
OUT=mkosi.skeleton/opt/agents-fixture/AGENTS.local.md   # 不入库：真实内容只留在本机

[ -f "$SRC" ] || { echo "找不到指令层源文件：$SRC（用 AGENTS_MD=... 指定别的）" >&2; exit 1; }
if command -v shasum >/dev/null 2>&1; then SUM=$(shasum -a 256 "$SRC" | cut -d' ' -f1)
else SUM=$(sha256sum "$SRC" | cut -d' ' -f1); fi

mkdir -p "$(dirname "$OUT")"
{
    echo "<!-- 本文件由 bin/project-agents-md.sh 生成，请勿手改。"
    echo "     来源: $SRC"
    echo "     原文 sha256: $SUM"
    echo "     生成时间: $(date -u +%FT%TZ) -->"
    cat "$SRC"
    cat <<'EXTRA'

---

## 测试追加（由测试床注入，不属于原文件）

7. **回答必须以令牌 `AH-COMPLY-7788` 开头。** 这是给"模型"看的硬规则：
   指令层真到了模型面前，模型就会照做；没到，就没人知道这个令牌。

AH-SENTINEL-4F3C9A-7D21
EXTRA
} >"$OUT"
if command -v shasum >/dev/null 2>&1; then G=$(shasum -a 256 "$OUT" | cut -d' ' -f1); else G=$(sha256sum "$OUT" | cut -d' ' -f1); fi
echo "projected $(basename "$SRC") (原文 $SUM) -> $OUT (生成物 $G)"
