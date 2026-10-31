#!/bin/bash
# 价格刷新包装：跑 17号 管线(run_all.py) → 精简 promoData.js → 放 kucun 仓库根 → push
# 错峰：由 launchd 在 10:25/13:25/17:25/21:25 调用，避开库存同步(:02/:17/:32/:47)的 9223 占用
# 仅写数据文件+push，不碰 index.html（页面结构归 18号 在 9017d43 已上线）
set -u
PIPE=/Users/mac/WorkBuddy/2026-09-11-21-21-56/price_promo_pipeline
KUCUN=/Users/mac/WorkBuddy/2026-08-24-14-47-23/kucun
KUCUNOS=/Users/mac/WorkBuddy/2026-08-31-14-14-00/kucunos
export KUCUNOS
PY=/Users/mac/.workbuddy/binaries/python/envs/default/bin/python3
LOCK=/tmp/kucun_promo_refresh.lock
LOG=/Users/mac/WorkBuddy/2026-08-24-14-47-23/kucun/refresh_promo.log
export HOME=/Users/mac
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export GIT_SSH_COMMAND="ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=3"

# macOS 无 flock，用 mkdir 原子锁（目录存在即视为占用）
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "$(date '+%F %T') SKIP: 上一次仍在跑" >> "$LOG"
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# 失败告警：桌面通知（最佳努力，不阻塞主流程）
alert() {
  local msg="$1"
  echo "ALERT $(date '+%F %T'): $msg" >> "$LOG"
  osascript -e "display notification \"$msg\" with title \"价格刷新失败\"" 2>/dev/null || true
}

echo "==================================================" >> "$LOG"
echo "价格刷新开始 $(date '+%F %T')" >> "$LOG"

# 保活 9223：复用 Claw 已加固的 ensure_chrome（端口通即复用、不通才拉起，绝不抢端口）
# 实测握手 + 端口通≠可用 兜底，防止 502 僵尸实例
"$PY" - <<'PYEOF' >> "$LOG" 2>&1
import sys, os
sys.path.insert(0, "/Users/mac/WorkBuddy/Claw")
import stock_pull as sp
try:
    ok = sp.ensure_chrome()
    if not ok:
        print("ensure_chrome 失败"); sys.exit(1)
    bws = sp.get_bws()          # 端口通≠可用，实测一次握手兜底
    bws.cmd("Browser.getVersion")
    print("9223 保活 OK")
except Exception as e:
    print("9223 健康检查失败:", e); sys.exit(1)
sys.exit(0)
PYEOF
if [ $? -ne 0 ]; then alert "9223 通道不可用，价格未刷新（详见 refresh_promo.log）"; exit 1; fi

cd "$PIPE" || { echo "$(date) cd 失败" >> "$LOG"; alert "价格管线目录缺失"; exit 1; }
"$PY" run_all.py >> "$LOG" 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then alert "run_all 失败 RC=$RC，保留旧 promoData.js"; exit $RC; fi

# 精简：剥 tiers/real/null → kucun/promoData.js
"$PY" - "$KUCUN" <<'PYEOF' >> "$LOG" 2>&1
import json, sys, os
kucun = sys.argv[1]
src = os.path.join('/Users/mac/WorkBuddy/2026-09-11-21-21-56/price_promo_pipeline/output/promoData.js')
h = open(src, encoding='utf-8').read()
def sliceVar(name):
    s = h.index('window.' + name + '='); eq = h.index('=', s) + 1
    i, d, ins, esc = eq, 0, False, False
    while i < len(h):
        c = h[i]
        if esc: esc = False
        elif c == '\\': esc = True
        elif c == '"': ins = not ins
        elif not ins:
            if c in '{[': d += 1
            elif c in '}]':
                d -= 1
                if d == 0: break
        i += 1
    return h[eq:i + 1]
PD = json.loads(sliceVar('PRICE_DATA')); PM = json.loads(sliceVar('PROMO_DATA'))
slim = {}
for k, v in PD.items():
    r = v.get('retail')
    if r is None: r = v.get('real')
    if r is None: continue
    slim[k] = {"retail": int(round(r))}
out = ('window.PRICE_DATA=' + json.dumps(slim, ensure_ascii=False, separators=(',', ':')) +
       ';window.PROMO_DATA=' + json.dumps(PM, ensure_ascii=False, separators=(',', ':')) + ';')
open(os.path.join(kucun, 'promoData.js'), 'w', encoding='utf-8').write(out)
# kucunos 同源共用同一份(同款 SKU 编码)，两份各自独立存，避免跨仓库联网依赖
# 注意：kucunos 写入失败不得阻塞 kucun 主链路（历史故障：兜底路径算错导致连续 4 次刷新全挂）
kucunos = os.environ.get('KUCUNOS') or '/Users/mac/WorkBuddy/2026-08-31-14-14-00/kucunos'
try:
    open(os.path.join(kucunos, 'promoData.js'), 'w', encoding='utf-8').write(out)
except Exception as e:
    print('WARN kucunos 写入失败(不阻塞 kucun):', e)
print('slim OK: PRICE_DATA', len(slim), 'PROMO_DATA', len(PM))
PYEOF
RC2=$?
if [ "$RC2" -ne 0 ]; then echo "$(date) 精简失败 RC=$RC2" >> "$LOG"; exit $RC2; fi

# kucun 推送
cd "$KUCUN" || exit 1
if git diff --quiet -- promoData.js 2>/dev/null; then
  echo "$(date) kucun promoData.js 无变化，跳过 push" >> "$LOG"
else
  git add promoData.js
  git commit -m "auto(kucun): 价格刷新 $(date '+%F %T')" >> "$LOG" 2>&1
  git push origin main >> "$LOG" 2>&1
  echo "$(date) kucun push 完成" >> "$LOG"
fi

# kucunos 推送（价格层由 18号 已在正本上线；这里只更新数据文件）
cd "$KUCUNOS" || exit 1
if git diff --quiet -- promoData.js 2>/dev/null; then
  echo "$(date) kucunos promoData.js 无变化，跳过 push" >> "$LOG"
else
  git add promoData.js
  git commit -m "auto(kucunos): 价格刷新 $(date '+%F %T')" >> "$LOG" 2>&1
  git push origin main >> "$LOG" 2>&1
  echo "$(date) kucunos push 完成" >> "$LOG"
fi
echo "价格刷新结束 $(date '+%F %T')" >> "$LOG"
