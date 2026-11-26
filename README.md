# local-deep-research

Private research assistant: [Local Deep Research](https://github.com/LearningCircuit/local-deep-research)
(web UI + agent) + SearXNG (web search) + Ollama (local LLM), on one Docker network.
Only LDR is published, on `127.0.0.1:5000`.

## Local

```bash
./deploy.sh up          # create .env, start services, configure SearXNG, pull the model
# open http://localhost:5000, create an account, then:
./deploy.sh harden      # disable public sign-ups
./deploy.sh down
```

`deploy.sh up` also patches the SearXNG config it generates on first start:
JSON output on (LDR needs it), and the Yandex and Seznam engines on, because the
default ones (DuckDuckGo, Startpage, Brave) answer automated traffic with CAPTCHAs.
The research strategy is locked to `source-based` (`LDR_SEARCH_STRATEGY` in `.env`),
since the upstream default needs a model with tool calling.

Smoke test through the same HTTP routes as the UI (register, login, research, report):

```bash
python scripts/research_test.py --user tester --password '<pw>' \
  --query "What are the main differences between IaaS, PaaS and SaaS?" --out results/local
```

## AWS (test deploy)

Needs AWS CLI v2 with credentials and `ssh`. Region `us-east-2` (the only one the
account's SCP allows).

```bash
./cloud.sh run          # up + test + down, down always runs
./cloud.sh up           # key pair, SG (SSH from your IP only), instance + user-data
./cloud.sh test         # wait for the stack, SSH tunnel, one research -> results/aws-*/
./cloud.sh tunnel       # demo: http://localhost:5001
./cloud.sh down         # terminate, delete key pair and SG, log the cost
```

Without GPU quota it uses `t3.xlarge` (CPU) with `qwen2.5:3b`; with quota,
`g4dn.xlarge` on the Deep Learning Base GPU AMI with `--gpu`.
Cost guards: the instance terminates itself after `MAX_HOURS` (default 2), and
`up` refuses to start if the estimated spend would pass `BUDGET_USD` (default 10).
Estimated spend per run is logged in `results/cost-log.csv`.
