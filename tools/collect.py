#!/usr/bin/env python3
"""Rebuild the Nova free server list from public config aggregators.

The list users get when they install Nova and press Connect. It is rebuilt on a
schedule because these servers are volunteer-run and short-lived: a list edited
by hand is mostly dead within a week, which is what the previous 18-entry list
had become (11 of 13 distinct servers refused TCP outright).

Two rules the app relies on:

  * TLS only. ProxyProfile.encryptedOnly would drop a plaintext entry on the
    device anyway, but shipping one at all puts someone who just pressed
    Connect on a tunnel that a censor can read. Filtered here as well.
  * Nothing is published without being tested. Reachability is measured, not
    assumed, and every surviving entry answered within this run.

Domain-addressed servers on Cloudflare's TLS ports are kept and ranked first.
Their domains are the ones Iran filters within days, and they are exactly the
case Nova's clean-IP fronting rescues: the app dials a Cloudflare address it
found on the user's own network and sends the domain only as the TLS name.
Dropping them for failing a probe run from outside Iran would throw away the
entries most likely to still work inside it.
"""
import asyncio, base64, ipaddress, json, os, re, ssl, sys, time, uuid as uuidlib
from urllib.parse import urlparse, parse_qs
from urllib.request import urlopen, Request

SOURCES = [
    "https://raw.githubusercontent.com/iboxz/free-v2ray-collector/main/main/mix",
    "https://raw.githubusercontent.com/iboxz/free-v2ray-collector/main/main/vless",
    "https://raw.githubusercontent.com/iboxz/free-v2ray-collector/main/main/trojan",
    "https://raw.githubusercontent.com/barry-far/V2ray-Config/main/All_Configs_Sub.txt",
    "https://raw.githubusercontent.com/Epodonios/v2ray-configs/main/All_Configs_Sub.txt",
    "https://raw.githubusercontent.com/mahdibland/V2RayAggregator/master/sub/sub_merge.txt",
    "https://raw.githubusercontent.com/miladtahanian/Config-Collector/main/mixed_iran.txt",
    "https://raw.githubusercontent.com/9Knight9n/v2ray-aggregator/main/merged_24h.txt",
    "https://raw.githubusercontent.com/rtwo2/FastNodes/main/sub/continents/Asia.txt",
    "https://raw.githubusercontent.com/rtwo2/FastNodes/main/sub/continents/Europe.txt",
]

CF_TLS_PORTS = {443, 2053, 2083, 2087, 2096, 8443}

# RIR delegation data for Iran, refreshed each run. A server hosted inside the
# country a user is trying to reach past is worse than no server: it carries
# their traffic through the jurisdiction they are avoiding, it can be pulled or
# watched by the same people running the filter, and it circumvents nothing. The
# public lists carry them, so they have to be taken out here.
IR_CIDR_URL = ("https://raw.githubusercontent.com/ipverse/rir-ip/master/"
               "country/ir/ipv4-aggregated.txt")

# Cloudflare's published ranges. The list is only worth building out of servers
# that sit behind them, for a reason that is specific to Iran rather than
# general good practice:
#
#   Cloudflare's addresses are, most of the time, reachable from Iranian
#   networks. The filtering works on the TLS server name instead, and that is
#   the one attack Nova can actually answer: the SNI-block bypass fragments the
#   name across TLS records so the DPI never sees it whole.
#
#   A server on Akamai, or on any ordinary datacentre address, has no such
#   answer. It may work on one ISP this afternoon and be gone tomorrow, and a
#   Reality server on a clean address is the same bet with a shorter fuse: it
#   connects until the DPI notices the address, which is hours, not days.
#
# Those servers test green and fail when someone actually needs them, which is
# the worst possible outcome for a list handed to people with nothing else.
CF_V4_CIDRS = [
    "173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22", "103.31.4.0/22",
    "141.101.64.0/18", "108.162.192.0/18", "190.93.240.0/20", "188.114.96.0/20",
    "197.234.240.0/22", "198.41.128.0/17", "162.158.0.0/15", "104.16.0.0/13",
    "104.24.0.0/14", "172.64.0.0/13", "131.0.72.0/22",
]
_cf_nets = [ipaddress.ip_network(c) for c in CF_V4_CIDRS]


def is_cloudflare(ip):
    try:
        a = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return any(a in n for n in _cf_nets)


# Only WebSocket. It is what Cloudflare proxies, so it is the only transport
# that can hide behind those addresses at all; tcp, grpc and Reality either
# cannot be fronted or bring their own handshake the DPI can find.
ALLOWED_TRANSPORTS = {"ws"}
MAX_OUT = int(os.environ.get("NOVA_MAX_OUT", "400"))
PROBE_TIMEOUT = float(os.environ.get("NOVA_PROBE_TIMEOUT", "4"))
CONCURRENCY = int(os.environ.get("NOVA_CONCURRENCY", "200"))


_ir_nets = []


def load_iran_ranges():
    """Iranian IPv4 ranges. A run without them does not publish.

    Failing open here would quietly ship domestic servers the moment the source
    moved or the fetch timed out, and nothing downstream would notice, so an
    empty list is treated as a broken run rather than as "no Iranian ranges
    exist"."""
    body = fetch(IR_CIDR_URL, timeout=30)
    nets = []
    for line in body.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            nets.append(ipaddress.ip_network(line))
        except ValueError:
            continue
    return nets


def is_iranian(ip):
    try:
        a = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return any(a in n for n in _ir_nets)


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def fetch(url, timeout=45):
    try:
        req = Request(url, headers={"User-Agent": "nova-freelist/1.0"})
        with urlopen(req, timeout=timeout) as r:
            return r.read().decode("utf-8", "ignore")
    except Exception as e:
        log(f"  source failed: {url} ({e})")
        return ""


def maybe_b64(text):
    """Subscription bodies are served either as plain links or base64. Decode
    only when the result actually looks like links, so a plain body that merely
    decodes without error is not mangled into noise."""
    s = text.strip()
    if "://" in s[:200]:
        return s
    try:
        d = base64.b64decode(s + "=" * (-len(s) % 4)).decode("utf-8", "ignore")
        return d if "://" in d else s
    except Exception:
        return s


def is_ip(host):
    try:
        ipaddress.ip_address(host)
        return True
    except ValueError:
        return False


_UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
                      r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")


def usable_credential(scheme, raw):
    """Rejects an entry Nova would not be able to parse.

    Some published links carry a decorated userinfo ("Telegram<flag> @Name@host"),
    which leaves a UUID field that is not a UUID. sing-box will happily dial such
    a server and it may even answer, so testing alone does not catch them, but
    Nova's own parser refuses the link and the user simply sees a server fewer.
    Anything that cannot survive the app's parser has no business being
    published, whether or not it works."""
    cred = (raw or "").strip()
    if not cred:
        return False
    # Only VLESS is checked. Its credential is a UUID by definition, so a value
    # that is not one is a mangled link. A trojan password is free-form, and
    # rejecting one merely because it contains "@" threw away three servers the
    # app parses perfectly well.
    if scheme == "vless":
        return bool(_UUID_RE.match(cred))
    return True


def parse_link(line):
    line = line.strip()
    if not line.startswith(("vless://", "trojan://")):
        return None
    try:
        u = urlparse(line)
        q = parse_qs(u.query)
        g = lambda k: (q.get(k) or [""])[0]
        if not u.hostname or not u.port:
            return None
        if not usable_credential(u.scheme, u.username):
            return None
        sec = g("security").lower()
        # Reality is deliberately excluded now. It is not weak, it is just
        # unfrontable: its handshake impersonates a real site directly from the
        # server's own address, so it lives exactly as long as that address
        # stays unnoticed and there is nothing Nova can do for it afterwards.
        if sec != "tls":
            return None
        net = (g("type") or "tcp").lower()
        if net not in ALLOWED_TRANSPORTS:
            return None
        return {
            "link": line,
            "proto": u.scheme,
            "host": u.hostname,
            "port": u.port,
            "sec": sec,
            "net": net,
            "sni": g("sni") or g("host") or "",
            "uid": u.username or "",
            "domain": not is_ip(u.hostname),
        }
    except Exception:
        return None


async def probe(n, sem):
    """One TCP connect, and a TLS handshake where the server should offer one.

    A connect proves something is listening; the handshake proves it is still a
    TLS server and not a parked address that accepts and drops. Reality servers
    are checked at the connect level only, since their handshake is deliberately
    indistinguishable from the site they impersonate."""
    async with sem:
        t = time.monotonic()
        try:
            fut = asyncio.open_connection(n["host"], n["port"])
            reader, writer = await asyncio.wait_for(fut, timeout=PROBE_TIMEOUT)
            n["tcp_ms"] = int((time.monotonic() - t) * 1000)
            # The address actually dialled, which is what the country check
            # needs: the link may name a domain, and only the address it
            # resolves to says where the server is.
            try:
                peer = writer.get_extra_info("peername")
                if peer:
                    n["ip"] = peer[0]
            except Exception:
                pass
            writer.close()
            try:
                await writer.wait_closed()
            except Exception:
                pass
        except Exception:
            n["tcp_ms"] = None
            return False
        if n["sec"] == "reality":
            return True
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        try:
            fut = asyncio.open_connection(
                n["host"], n["port"], ssl=ctx,
                server_hostname=(n["sni"] or None) if not is_ip(n["sni"] or n["host"]) else None)
            reader, writer = await asyncio.wait_for(fut, timeout=PROBE_TIMEOUT)
            writer.close()
            try:
                await writer.wait_closed()
            except Exception:
                pass
            n["tls_ok"] = True
        except Exception:
            n["tls_ok"] = False
        return True


def rank(n):
    """Domain on a Cloudflare TLS port first: those are what the clean-IP
    fronting rescues once their domain is filtered. Then plain latency."""
    front = 0 if (n["domain"] and n["port"] in CF_TLS_PORTS) else 1
    return (front, n["tcp_ms"] if n["tcp_ms"] is not None else 10**6)


def label(n, i):
    kind = "CF" if (n["domain"] and n["port"] in CF_TLS_PORTS) else n["proto"].upper()
    return f"Nova Free {i:03d} | {kind} | {n['tcp_ms']}ms"


async def main():
    log("fetching sources")
    raw = []
    for url in SOURCES:
        body = fetch(url)
        if not body:
            continue
        got = maybe_b64(body).splitlines()
        log(f"  {len(got):6d} lines  {url.split('/')[3]}/{url.split('/')[4]}")
        raw += got
    log(f"total lines: {len(raw)}")

    parsed = [p for p in (parse_link(l) for l in raw) if p]
    log(f"vless/trojan with TLS: {len(parsed)}")

    seen, uniq = set(), []
    for p in parsed:
        k = (p["proto"], p["host"], p["port"], p["uid"])
        if k in seen:
            continue
        seen.add(k)
        uniq.append(p)
    log(f"unique: {len(uniq)}")
    if not uniq:
        log("!! no candidates parsed; refusing to write an empty list")
        return 1

    global _ir_nets
    _ir_nets = load_iran_ranges()
    log(f"Iranian ranges loaded: {len(_ir_nets)}")
    if len(_ir_nets) < 100:
        log("!! Iranian range list looks wrong; refusing to publish unfiltered")
        return 1

    log(f"probing {len(uniq)} servers")
    sem = asyncio.Semaphore(CONCURRENCY)
    await asyncio.gather(*(probe(n, sem) for n in uniq))
    up = [n for n in uniq if n["tcp_ms"] is not None]
    alive = [n for n in up if n["sec"] == "reality" or n.get("tls_ok")]
    log(f"reachable: {len(up)}   completed a TLS handshake: {len(alive)}")

    # Everything published has to actually resolve into Cloudflare. The link
    # saying "cdn.example.com" proves nothing; only the address dialled does.
    behind = [n for n in alive if is_cloudflare(n.get("ip", ""))]
    log(f"behind Cloudflare: {len(behind)} of {len(alive)}")
    alive = behind

    domestic = [n for n in alive if is_iranian(n.get("ip", ""))]
    if domestic:
        for n in domestic:
            log(f"  dropped (hosted in Iran): {n['host']} -> {n.get('ip')}")
    alive = [n for n in alive if not is_iranian(n.get("ip", ""))]
    log(f"after dropping {len(domestic)} domestic servers: {len(alive)}")

    # A run that finds almost nothing is far more likely to be this machine's
    # network than the whole internet's, and overwriting a good list with the
    # wreckage would take the free list down for everyone.
    if len(alive) < 20:
        log(f"!! only {len(alive)} servers passed; refusing to publish")
        return 1

    alive.sort(key=rank)
    # Everything that survived the cheap probes goes to the core-backed filter.
    # The handshake is a weak signal on its own: a parked Cloudflare hostname
    # passes it and proxies nothing, and on a 58-server sample only 12 carried
    # traffic. sub.txt is written from the verified subset, not from this.
    open("candidates.txt", "w", encoding="utf-8").write(
        "\n".join(n["link"] for n in alive) + "\n")
    log(f"wrote {len(alive)} candidates for core verification")
    if os.environ.get("NOVA_PROBE_ONLY"):
        return 0
    out = alive[:MAX_OUT]
    fronted = sum(1 for n in out if n["domain"] and n["port"] in CF_TLS_PORTS)
    log(f"writing {len(out)} ({fronted} Cloudflare-fronted candidates)")

    lines = []
    for i, n in enumerate(out, 1):
        base = n["link"].split("#")[0]
        lines.append(f"{base}#{label(n, i).replace(' ', '%20').replace('|', '%7C')}")
    open("sub.txt", "w", encoding="utf-8").write("\n".join(lines) + "\n")

    json.dump({
        "generated_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "sources": len(SOURCES), "candidates": len(uniq),
        "reachable": len(up), "published": len(out), "fronted": fronted,
    }, open("sub-status.json", "w"), indent=2)
    log("done")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
