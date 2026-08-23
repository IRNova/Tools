# Free server list

`sub.txt` is the list Nova ships with, so that someone who installs the app and
presses Connect has somewhere to go before they have a subscription of their own.

It is rebuilt automatically every four hours by
[`.github/workflows/free-list.yml`](../.github/workflows/free-list.yml). It is
not maintained by hand: these servers are volunteer-run and short-lived, and the
previous hand-made list had decayed to 13 distinct servers of which 11 refused
TCP outright.

## How an entry earns its place

1. **Collected** (`collect.py`) from public aggregators, then filtered to VLESS
   and Trojan with TLS. A plaintext entry is never published: someone who just
   pressed Connect must not end up on a tunnel a censor can read.
2. **Probed** for a TCP connect and, where one is expected, a TLS handshake.
3. **Dialled** (`singbox_verify.py`) through sing-box, and required to return a
   real HTTP response. This is the step that decides.
4. **Published** (`publish.py`), Cloudflare-fronted servers first.

Step 3 is the whole point. Reachability is not usefulness: a parked Cloudflare
hostname passes both cheap checks and proxies nothing, and on one sample only
12 of 58 handshake-passers carried traffic. A list published on the strength of
a handshake looks large and fails on the phone.

## Why Cloudflare-fronted servers rank first

Their domains are what Iran filters within days, while the Cloudflare addresses
behind them keep working. Nova 1.17.0 dials those servers through an address it
finds on the user's own network and sends the domain only as the TLS name, so a
filtered domain stops being fatal. A server already addressed by IP needs no
such rescue and sorts after.

## What the job refuses to do

- Publish if fewer than 20 servers verify.
- Publish a partial run. If a batch cannot be tested, its servers are unknown,
  not dead, and treating them as dead would shrink the list a little on every
  bad run until nothing was left.
- Publish an entry Nova itself cannot parse. Some upstream links carry a
  decorated userinfo that leaves a VLESS "UUID" that is not a UUID; sing-box
  will dial them and they may even answer, but the app refuses the link, so the
  user just sees a server fewer.

## Running it by hand

    python3 tools/collect.py                              # writes candidates.txt
    NOVA_CORE=./sing-box python3 tools/singbox_verify.py candidates.txt verified.txt
    python3 tools/publish.py verified.txt sub.txt

`sub-status.json` records what the last run found.
