#!/usr/bin/env python3
"""Keeps only the servers that actually carry traffic, by dialling each one.

Reachability is not usefulness. A TCP connect and a TLS handshake both succeed
against a parked hostname that proxies nothing, and the public lists this is
built from are full of those: on a 58-server sample that passed both cheap
checks, 12 carried traffic. Anything published on the strength of a handshake
would be a list that looks large and fails on the phone.

So sing-box decides. Each candidate becomes an outbound in a measuring config,
and the Clash API is asked to fetch a real URL through it. Only servers that
answer are kept.

Two details that cost real debugging time and are easy to reintroduce:

  * The Clash API discards a literal "http://" test URL and substitutes https,
    which doubles every number. Passing "HTTP://" upper-case survives the
    substitution. Nova's own MeasureRunner does the same thing.
  * Its `timeout` is parsed as an int16, so anything over 32767 wraps.
"""
import asyncio, ipaddress, json, os, subprocess, sys, tempfile, time
import urllib.parse, urllib.request
from urllib.parse import urlparse, parse_qs, unquote

BATCH = int(os.environ.get("NOVA_BATCH", "200"))
TEST_URL = "HTTP://www.gstatic.com/generate_204"
TIMEOUT_MS = 12000


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def is_ip(h):
    try:
        ipaddress.ip_address(h)
        return True
    except ValueError:
        return False


def singbox_flow(raw):
    """The flow sing-box accepts, or "" for none.

    Xray ships variants sing-box does not know, and an unrecognised flow is
    FATAL: the core refuses to start, so one bad server in a batch of 200 takes
    the other 199 with it. That is exactly what happened here, twice, and it is
    why two whole batches came back as "nothing answered".

    The `-udp443` suffix is a client-side Xray switch that does not change the
    wire protocol, so the base flow is the faithful translation."""
    f = (raw or "").strip()
    if not f:
        return ""
    if f == "xtls-rprx-vision":
        return f
    if f.startswith("xtls-rprx-vision"):
        return "xtls-rprx-vision"
    return ""


def outbound(link, tag):
    """Share link -> sing-box outbound. Mirrors the subset Nova publishes:
    vless/trojan over tcp/ws/grpc with TLS or Reality. Returns None for anything
    outside it, so an entry Nova could not use is never published."""
    u = urlparse(link)
    q = parse_qs(u.query)
    g = lambda k: unquote((q.get(k) or [""])[0])
    if u.scheme not in ("vless", "trojan") or not u.hostname or not u.port:
        return None
    sec = g("security").lower()
    if sec not in ("tls", "reality", "xtls"):
        return None
    net = (g("type") or "tcp").lower()
    if net not in ("tcp", "ws", "grpc", "httpupgrade"):
        return None

    sni = g("sni") or g("host") or (u.hostname if not is_ip(u.hostname) else "")
    ob = {"type": u.scheme, "tag": tag, "server": u.hostname, "server_port": u.port}
    if u.scheme == "vless":
        ob["uuid"] = unquote(u.username or "")
        flow = singbox_flow(g("flow"))
        if flow:
            ob["flow"] = flow
    else:
        ob["password"] = unquote(u.username or "")

    tls = {"enabled": True, "server_name": sni,
           "insecure": g("allowInsecure") in ("1", "true")}
    fp = g("fp")
    if fp:
        tls["utls"] = {"enabled": True, "fingerprint": fp}
    alpn = g("alpn")
    if alpn:
        tls["alpn"] = [a for a in alpn.split(",") if a]
    if sec == "reality":
        pbk = g("pbk")
        if not pbk:
            return None
        tls["reality"] = {"enabled": True, "public_key": pbk, "short_id": g("sid")}
        tls.setdefault("utls", {"enabled": True, "fingerprint": "chrome"})
    ob["tls"] = tls

    if net == "ws":
        ws = {"type": "ws", "path": g("path") or "/"}
        host = g("host")
        if host:
            ws["headers"] = {"Host": host}
        ob["transport"] = ws
    elif net == "grpc":
        ob["transport"] = {"type": "grpc", "service_name": g("serviceName")}
    elif net == "httpupgrade":
        ob["transport"] = {"type": "httpupgrade", "path": g("path") or "/",
                           "host": g("host") or sni}
    return ob


def build_config(links, clash_port):
    obs, tags = [], {}
    for i, l in enumerate(links):
        tag = "node-%d" % i
        try:
            ob = outbound(l, tag)
        except Exception:
            ob = None
        if ob:
            obs.append(ob)
            tags[tag] = l
    if not obs:
        return None, {}
    cfg = {
        "log": {"level": "error"},
        # A resolver is required. Without it every domain-addressed server fails
        # instantly and the run looks like a dead internet, which is exactly the
        # bug that broke Nova 1.16.0 on device.
        "dns": {
            "servers": [{"tag": "local", "address": "https://1.1.1.1/dns-query",
                         "detour": "direct"}],
            "final": "local",
            "strategy": "prefer_ipv4",
        },
        "outbounds": obs + [{"type": "direct", "tag": "direct"}],
        "experimental": {
            "clash_api": {"external_controller": "127.0.0.1:%d" % clash_port}
        },
    }
    return cfg, tags


def prune_rejected(core, cfg, tags, max_drops=25):
    """Drop outbounds the core refuses, so one bad entry cannot void a batch.

    `sing-box check` names the offender as `initialize outbound[N]`, so the
    config is re-checked until it is accepted. Normalising known-bad fields up
    front is the first line of defence; this is the one that survives whatever
    the aggregators publish next."""
    import re, subprocess, tempfile, json as _json, os as _os
    for _ in range(max_drops):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            _json.dump(cfg, f)
            path = f.name
        try:
            r = subprocess.run([core, "check", "-c", path], capture_output=True,
                               env=dict(_os.environ,
                                        ENABLE_DEPRECATED_LEGACY_DNS_SERVERS="true"))
            if r.returncode == 0:
                return cfg, tags, True
            m = re.search(rb"initialize outbound\[(\d+)\]", r.stderr)
            if not m:
                log("  core rejected the config: %s"
                    % r.stderr.decode("utf-8", "ignore").strip()[-200:])
                return cfg, tags, False
            i = int(m.group(1))
            if i >= len(cfg["outbounds"]):
                return cfg, tags, False
            bad = cfg["outbounds"].pop(i)
            tags.pop(bad.get("tag"), None)
            log("  dropped %s (%s): core will not initialise it"
                % (bad.get("server"), bad.get("tag")))
        finally:
            _os.unlink(path)
    return cfg, tags, False


async def measure(clash_port, tags, concurrency=16):
    sem = asyncio.Semaphore(concurrency)
    out = {}

    async def one(tag):
        async with sem:
            url = ("http://127.0.0.1:%d/proxies/%s/delay?timeout=%d&url=%s"
                   % (clash_port, urllib.parse.quote(tag), TIMEOUT_MS,
                      urllib.parse.quote(TEST_URL, safe="")))

            def get():
                try:
                    with urllib.request.urlopen(url, timeout=TIMEOUT_MS / 1000 + 5) as r:
                        return json.loads(r.read().decode())
                except Exception:
                    return None

            d = await asyncio.get_running_loop().run_in_executor(None, get)
            if d and isinstance(d.get("delay"), int) and d["delay"] > 0:
                out[tag] = d["delay"]

    await asyncio.gather(*(one(t) for t in tags))
    return out


async def wait_api(port, timeout=40):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            def get():
                with urllib.request.urlopen("http://127.0.0.1:%d/version" % port,
                                            timeout=2) as r:
                    return r.status
            if await asyncio.get_running_loop().run_in_executor(None, get) == 200:
                return True
        except Exception:
            pass
        await asyncio.sleep(0.5)
    return False


async def main():
    src, dst = sys.argv[1], sys.argv[2]
    core = os.environ.get("NOVA_CORE", "./sing-box")
    links = [l.strip() for l in open(src, encoding="utf-8") if l.strip()]
    log("verifying %d candidates through %s" % (len(links), core))

    kept, all_ms, tested, skipped = [], [], 0, 0
    for start in range(0, len(links), BATCH):
        slice_ = links[start:start + BATCH]
        bno = start // BATCH
        # Retry on a fresh port when the core does not come up. Giving up after
        # one attempt silently dropped a whole batch: 200 servers recorded as
        # "did not answer" without being dialled, which was 54% of the
        # disagreement against Nova's own measuring path. A skipped batch is not
        # a verdict, so it must never look like one.
        got, tags = None, {}
        for attempt in range(3):
            port = 24100 + bno * 4 + attempt
            cfg, tags = build_config(slice_, port)
            if not cfg:
                break
            if attempt == 0:
                cfg, tags, ok = prune_rejected(core, cfg, tags)
                if not ok:
                    log("  batch %d: config still rejected after pruning" % bno)
            with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
                json.dump(cfg, f)
                path = f.name
            env = dict(os.environ, ENABLE_DEPRECATED_LEGACY_DNS_SERVERS="true")
            proc = subprocess.Popen([core, "run", "-c", path],
                                    stdout=subprocess.DEVNULL,
                                    stderr=subprocess.PIPE, env=env)
            try:
                if await wait_api(port):
                    got = await measure(port, tags)
                    break
                err = b""
                try:
                    err = proc.stderr.read(400) if proc.stderr else b""
                except Exception:
                    pass
                log("  batch %d: core did not start on :%d (attempt %d)%s"
                    % (bno, port, attempt + 1,
                       " " + err.decode("utf-8", "ignore").strip()[:200] if err else ""))
            finally:
                proc.terminate()
                try:
                    proc.wait(timeout=10)
                except Exception:
                    proc.kill()
                os.unlink(path)

        if got is None:
            skipped += len(tags)
            log("  batch %d: FAILED after 3 attempts, %d servers not tested"
                % (bno, len(tags)))
            continue
        for tag, ms in got.items():
            kept.append(tags[tag])
            all_ms.append(ms)
        tested += len(tags)
        log("  batch %d: tested %d, kept %d of %d"
            % (bno, len(tags), len(kept), tested))

    all_ms.sort()
    log("tested %d, carry traffic: %d" % (tested, len(kept)))
    if skipped:
        # Never let an untested batch pass as a clean run: the servers in it are
        # unknown, not dead, and a list built as though they were dead loses good
        # servers every time a core fails to start.
        log("!! %d servers could not be tested; not publishing a partial run" % skipped)
        return 1
    if all_ms:
        log("median %dms, best %dms" % (all_ms[len(all_ms) // 2], all_ms[0]))
    # Never overwrite a good list with a bad run: an empty or tiny result is far
    # more likely to be this runner's network than the whole internet's.
    if len(kept) < 20:
        log("!! only %d verified; refusing to publish" % len(kept))
        return 1
    open(dst, "w", encoding="utf-8").write("\n".join(kept) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
