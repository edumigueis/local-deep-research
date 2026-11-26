#!/usr/bin/env python3
"""End-to-end smoke test: register/login, run one research, save timing + report.

Uses the same HTTP routes as the web UI (CSRF token + session cookie).
Usage:
  python scripts/research_test.py --url http://localhost:5000 \
      --user tester --password '...' --query "..." --out results/local
Exit code 0 only if the research completed AND returned at least one source.
"""
import argparse
import json
import pathlib
import sys
import time

import requests


def csrf(s, base):
    r = s.get(f"{base}/auth/csrf-token", timeout=30)
    r.raise_for_status()
    return r.json()["csrf_token"]


def form_post(s, base, path, data):
    return s.post(f"{base}{path}", data=data, timeout=120,
                  headers={"X-CSRFToken": csrf(s, base)}, allow_redirects=False)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://localhost:5000")
    ap.add_argument("--user", required=True)
    ap.add_argument("--password", required=True)
    ap.add_argument("--query", required=True)
    ap.add_argument("--mode", default="quick")
    ap.add_argument("--timeout", type=int, default=3600, help="seconds")
    ap.add_argument("--out", default="results")
    ap.add_argument("--label", default="")
    a = ap.parse_args()
    base = a.url.rstrip("/")
    out = pathlib.Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    s = requests.Session()

    # Register (fails harmlessly if the account already exists), then log in.
    form_post(s, base, "/auth/register", {
        "username": a.user, "password": a.password,
        "confirm_password": a.password, "acknowledge": "true"})
    r = form_post(s, base, "/auth/login",
                  {"username": a.user, "password": a.password})
    chk = s.get(f"{base}/auth/check", timeout=30)
    if chk.status_code != 200 or not chk.json().get("authenticated", True):
        sys.exit(f"login failed: {r.status_code} / check {chk.status_code} {chk.text[:200]}")

    t0 = time.time()
    r = s.post(f"{base}/api/start_research", timeout=120,
               headers={"X-CSRFToken": csrf(s, base)},
               json={"query": a.query, "mode": a.mode,
                     "search_engine": "searxng"})
    if r.status_code >= 400:
        sys.exit(f"start_research failed: {r.status_code} {r.text[:500]}")
    rid = r.json()["research_id"]
    print(f"research {rid} started", flush=True)

    status, last = "", -1
    while time.time() - t0 < a.timeout:
        st = s.get(f"{base}/api/research/{rid}/status", timeout=60).json()
        status, prog = st.get("status"), st.get("progress")
        if prog != last:
            print(f"  [{time.time() - t0:6.0f}s] {status} {prog}%", flush=True)
            last = prog
        if status in ("completed", "failed", "error", "suspended", "cancelled"):
            break
        time.sleep(10)
    elapsed = time.time() - t0

    rep = s.get(f"{base}/api/report/{rid}", timeout=60)
    report = rep.json() if rep.ok else {"error": rep.text[:500]}
    sources = report.get("sources") or []
    result = {
        "label": a.label, "url": base, "query": a.query, "mode": a.mode,
        "research_id": rid, "status": status,
        "elapsed_seconds": round(elapsed, 1), "n_sources": len(sources),
        "finished_at": time.strftime("%Y-%m-%d %H:%M:%S"),
    }
    stamp = time.strftime("%Y%m%d-%H%M%S")
    (out / f"result-{stamp}.json").write_text(json.dumps(result, indent=2))
    (out / f"report-{stamp}.md").write_text(report.get("content") or json.dumps(report, indent=2), encoding="utf-8")
    (out / f"sources-{stamp}.json").write_text(json.dumps(sources, indent=2), encoding="utf-8")
    print(json.dumps(result, indent=2))
    sys.exit(0 if status == "completed" and sources else 1)


if __name__ == "__main__":
    main()
