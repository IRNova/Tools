#!/usr/bin/env python3
"""Turns the verified servers into the list Nova ships, and names them.

Ranking puts domain-addressed servers on Cloudflare's TLS ports first. Their
domains are what Iran filters within days, and they are the case Nova's clean-IP
fronting rescues: the app dials a Cloudflare address found on the user's own
network and sends the domain only as the TLS name. A server whose address is
already an IP needs no rescue, so it sorts after.
"""
import ipaddress, json, sys, time
from urllib.parse import urlparse, parse_qs, unquote, quote

CF_TLS_PORTS = {443, 2053, 2083, 2087, 2096, 8443}
# The pool the app draws from, not what the user sees. The app sweeps this and
# stops once it has 30 servers that carry traffic, so the pool only has to be
# comfortably larger than 30 for that search to succeed quickly.
MAX_OUT = 200


def is_ip(h):
    try:
        ipaddress.ip_address(h)
        return True
    except ValueError:
        return False


def info(link):
    u = urlparse(link)
    q = parse_qs(u.query)
    sni = unquote((q.get("sni") or q.get("host") or [""])[0])
    domain = not is_ip(u.hostname or "")
    return {
        "link": link,
        "proto": u.scheme,
        "port": u.port or 0,
        "fronted": domain and (u.port or 0) in CF_TLS_PORTS,
        "sni": sni,
    }


def main():
    src, dst = sys.argv[1], sys.argv[2]
    links = [l.strip() for l in open(src, encoding="utf-8") if l.strip()]
    nodes = [info(l) for l in links]
    # Stable order: fronted first, then by protocol and port so the file does
    # not churn between runs when nothing meaningful changed.
    nodes.sort(key=lambda n: (0 if n["fronted"] else 1, n["proto"], n["port"]))
    out = nodes[:MAX_OUT]

    lines = []
    for i, n in enumerate(out, 1):
        base = n["link"].split("#")[0]
        # Everything published is Cloudflare-fronted WebSocket now, so the
        # label carries the protocol, the only thing that still varies.
        kind = n["proto"].upper()
        lines.append("%s#%s" % (base, quote("Nova Free %03d | %s" % (i, kind))))
    open(dst, "w", encoding="utf-8").write("\n".join(lines) + "\n")

    fronted = sum(1 for n in out if n["fronted"])
    json.dump({
        "generated_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "verified": len(links),
        "published": len(out),
        "cloudflare_fronted": fronted,
    }, open("sub-status.json", "w"), indent=2)
    print("published %d (%d Cloudflare-fronted)" % (len(out), fronted), file=sys.stderr)


if __name__ == "__main__":
    main()
