#!/bin/bash
set -e
: "${T3_SETUP_PASSWORD:?T3_SETUP_PASSWORD is required - it gates the pairing page}"

# From 0.1.11 the T3 server alone peaks at about 450 MB while starting, so under 1 GB
# (Railway's Free plan allows 0.5 GB) the kernel kills it every few seconds and the logs
# never say why. Say it on the page instead, and keep the healthcheck up.
lim=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo max)
if [ "$lim" != max ] && [ "$lim" -lt 900000000 ] 2>/dev/null; then
  mb=$((lim / 1048576))
  echo "T3 Code needs 1 GB of memory and this service has ${mb} MB: serving a notice page instead. Raise the memory limit to 1 GB or more, then redeploy."
  unset T3_SETUP_PASSWORD
  exec setpriv --reuid=1000 --regid=1000 --init-groups env PORT="${PORT:-8080}" MB="$mb" node -e '
    const msg = `T3 Code could not start: it needs 1 GB of memory and this service has ${process.env.MB} MB (Railway'"'"'s Free plan allows 0.5 GB). Below 1 GB the T3 server is killed for memory as it starts, over and over. Use the Hobby plan or higher, set the memory limit in the service settings to 1 GB or more, then redeploy. Your data on the volume is untouched.`;
    require("http").createServer((q, r) => {
      if (q.url === "/healthcheck") { r.end("ok"); return; }
      r.writeHead(503, {"content-type": "text/plain; charset=utf-8"}); r.end(msg + "\n");
    }).listen(+process.env.PORT, "::");'
fi

# /home/t3 is the Railway volume: empty (bar lost+found) and root-owned on first boot.
H=/home/t3
[ -f "$H/.bashrc" ] || cp -an /etc/skel/. "$H/"
mkdir -p "$H/workspace"
[ "$(stat -c %u "$H")" = 1000 ] && [ "$(stat -c %u "$H/workspace")" = 1000 ] || chown -R t3:t3 "$H"

as_t3() { setpriv --reuid=1000 --regid=1000 --init-groups env HOME="$H" USER=t3 LOGNAME=t3 SHELL=/bin/bash "$@"; }

# Codex 0.168+ copies itself (~420 MB) into ~/.codex/packages on first start, which takes
# about 1 GB of memory and gets it killed on a 0.5 GB service. Off unless the config says otherwise.
as_t3 codex-no-daemon "$H/.codex/config.toml" || echo "codex: could not write daemon_auto_start"

# Optional keys, applied once so a login done in the app is never overwritten.
if [ -n "${OPENAI_API_KEY:-}" ] && [ ! -f "$H/.codex/auth.json" ]; then
  printenv OPENAI_API_KEY | as_t3 codex login --with-api-key >/dev/null 2>&1 || echo "codex: API-key login failed"
fi
[ -n "${GH_TOKEN:-}" ] && { as_t3 gh auth setup-git >/dev/null 2>&1 || true; }

# nginx on $PORT. /railway-pair (password page) mints pairing links; everything else
# is the T3 server, which authenticates every API call, WebSocket and terminal itself.
cat > /etc/nginx/conf.d/t3.conf <<CFG
server {
  listen ${PORT} default_server;
  listen [::]:${PORT} default_server;
  client_max_body_size 200m;
  location = /healthcheck { proxy_pass http://127.0.0.1:3773/.well-known/t3/environment; }
  location = /railway-pair { proxy_pass http://127.0.0.1:3774; proxy_set_header Host \$http_host; }
  location / {
    proxy_pass http://127.0.0.1:3773;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$http_connection;
    proxy_set_header Host \$http_host;
    proxy_buffering off;
    proxy_read_timeout 1d;
    proxy_send_timeout 1d;
  }
}
CFG
nginx

as_t3 node /opt/railway-pair.mjs &
unset T3_SETUP_PASSWORD

# Railway counts the kernel cache of files this container touched as its memory and
# never frees it without pressure (one npm install = hundreds of MB). Drop it every 15 min.
( while sleep 900; do nice -n 19 drop-file-cache "$H" /tmp || true; done ) &

echo "== T3 Code $(t3 --version 2>/dev/null) on :${PORT}. Pair a device at https://<your-domain>/railway-pair"
cd "$H/workspace"
# 0.0.0.0 = T3's "remote-reachable" policy (it is, via the domain); nginx still fronts it.
# `t3 serve` prints a one-time admin pairing token + QR at boot; keep it out of the logs.
exec setpriv --reuid=1000 --regid=1000 --init-groups env HOME="$H" USER=t3 LOGNAME=t3 SHELL=/bin/bash \
  t3 serve --host 0.0.0.0 --port 3773 "$H/workspace" \
  > >(sed -u -e '/^Token: /d' -e 's/token=[^ "&]*/token=<redacted>/g' -e 's/token%3[Dd][^ "&]*/token%3D<redacted>/g' -e '/^[ █▀▄]*$/d') 2>&1
