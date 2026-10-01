#!/usr/bin/env python3
"""make mcp-agent-eval's driver (scripts/mcp-agent-eval.sh prepares the apps and runs it).

  mcp-agent-eval.py <apps folder> <output folder>

<apps folder>/<all|main|off>/ holds a copy of the Debug app ("Yap Eval.app", its switches set that way) and the
month fixture it wrote (data/). Each question goes to each available agent with that copy's yap-mcp connected and
nothing else to use: Codex runs with its shell and apps off in a read-only sandbox, Claude Code with only the yap
tools allowed. An answer passes when it has every expected fact (any one spelling of each) and none of the
forbidden ones; an answer from an agent that used anything but the yap tools doesn't count. Writes results.md and
results.json to <output folder>; EVAL_RUNS=n asks everything n times, EVAL_JOBS=n runs n agents at once (4).
"""
import concurrent.futures, json, os, re, shutil, subprocess, sys, time

TOOLS = ["list_meetings", "get_meeting", "search_history", "get_dictation", "get_dictionary"]
SWITCH_ON = ["让 agent 读取 Yap 的数据", "让 agent 读取", "Let Agents Read Yap's Data", "Agent 访问", "Agent Access"]
DICTATIONS_SWITCH = ["包括听写历史", "Include Dictation History"]

# What a user of the month fixture (MCPEvalFixture.swift) would ask, and what the answer must contain.
# expect: every group must match (one of its spellings); forbid: none may appear.
QUESTIONS = [
    {"id": 1, "kind": "会议·按日期", "state": "all", "q": "上周四那场会议的待办分别是谁的？",
     "expect": [["Reed"], ["Shelley"], ["Marco"], ["webhook"], ["邮件", "email"], ["告警", "alert"]],
     "answer": "上周四 Billing migration 同步：Reed 做 Stripe webhook 重试（10 月 2 日前），Shelley 写给受影响客户的邮件草稿（周一前），Marco 加 failed charge 告警。"},
    {"id": 2, "kind": "会议·跨会议汇总", "state": "all", "q": "最近三场会议里关于 rollout 做了哪些决定？",
     "expect": [["50%"], ["1%"], ["暂停", "pause"]],
     "answer": "Rollout review #2：10 月 6 日 checkout canary 提到 50%，错误率连续 10 分钟超过 1% 就回滚；Billing 同步：billing migration 的 rollout 暂停到 webhook 重试上线；和 Reed 的 1:1 没有 rollout 的决定（只说 Marco 在盯）。"},
    {"id": 3, "kind": "听写·按 app 搜", "state": "all", "q": "我在 Slack 里说过 Kubernetes 升级什么时候做？",
     "expect": [["10 月 8", "10/8", "October 8", "Oct 8", "10-08", "10.8"], ["十点", "10 点", "22:00", "10 PM", "10pm", "晚上 10"]],
     "answer": "10 月 8 日周四晚上十点，先 staging 再 prod（更早一条说过先往后推）。"},
    {"id": 4, "kind": "词典", "state": "all", "q": "我的 Yap 词典里 Postgres 是怎么写的？",
     "expect": [["PostgreSQL"]],
     "answer": "PostgreSQL：替换规则把 postgres / post gress / postgre 写成 PostgreSQL，词表里也有 PostgreSQL。"},
    {"id": 5, "kind": "开关全关", "state": "off", "q": "上周四的会上 Reed 负责什么？",
     "expect": [SWITCH_ON], "forbid": ["webhook", "10 月 2", "Stripe"],
     "answer": "读不到：请在 Yap › 设置 › Agent 访问（MCP）里打开“让 agent 读取 Yap 的数据”。"},
    {"id": 6, "kind": "只开会议问听写", "state": "main", "q": "我在微信上跟我妈说周六几点到？",
     "expect": [DICTATIONS_SWITCH], "forbid": ["三点", "3 点", "15:00", "G1234", "下午 3"],
     "answer": "听写历史没有开放给 agent：请在 Yap › 设置 › Agent 访问（MCP）里打开“包括听写历史”。"},
    {"id": 7, "kind": "不存在的东西", "state": "all", "q": "我有没有在哪次会议上讨论过 Terraform？",
     "expect": [["没有", "没找到", "未找到", "找不到", "no meeting", "not found", "didn't find"]],
     "forbid": ["讨论过 Terraform。", "提到了 Terraform"],
     "answer": "没有：会议里搜不到 Terraform。"},
    {"id": 8, "kind": "会议·英文·说话人", "state": "all",
     "q": "In the onboarding design review, what did Shelley want to do with the setup tour, and which release is it for?",
     "expect": [["microphone"], ["1.12"]],
     "answer": "Drop the three-step setup tour and keep only the microphone permission screen (shortcut shown on Home), in 1.12."},
    {"id": 9, "kind": "听写·读全文", "state": "all", "q": "上周我用 Mail 给 Jenny 发的发票邮件里，发票号和金额是多少？",
     "expect": [["INV-2026-0917"], ["12,800", "12800"]],
     "answer": "INV-2026-0917，¥12,800（10 月 15 日到期）。"},
    {"id": 10, "kind": "听写·代码注释", "state": "all", "q": "我在 Cursor 里口述的 rate limiter 注释里，限流阈值是多少？",
     "expect": [["600"]],
     "answer": "每个 token 每分钟最多 600 次请求，超过返回 429。"},
]


def found(text, spelling):
    """Case-insensitive, and blind to spaces so "10 月 8" matches "10月8"."""
    text, spelling = text.lower(), spelling.lower()
    return spelling in text or spelling.replace(" ", "") in text.replace(" ", "")


def grade(question, answer, other_tools):
    missing = [group[0] for group in question["expect"] if not any(found(answer, s) for s in group)]
    forbidden = [s for s in question.get("forbid", []) if found(answer, s)]
    problems = (["missing " + ", ".join(missing)] if missing else []) + (
        ["says " + ", ".join(forbidden)] if forbidden else []) + (
        ["used " + ", ".join(other_tools)] if other_tools else [])
    return not problems, "; ".join(problems)


class Codex:
    name = "codex"

    def __init__(self, apps, out):
        self.homes = {}
        auth = os.path.expanduser("~/.codex/auth.json")
        if not shutil.which("codex"):
            self.skip = "codex isn't installed"
            return
        if not os.path.exists(auth) and not os.environ.get("OPENAI_API_KEY"):
            self.skip = "codex isn't signed in (no ~/.codex/auth.json, no OPENAI_API_KEY)"
            return
        self.skip = None
        self.version = subprocess.run(["codex", "--version"], capture_output=True, text=True).stdout.strip()
        # The user's model and effort, read (never written) from their config; the same for every run.
        config = open(os.path.expanduser("~/.codex/config.toml")).read() if os.path.exists(os.path.expanduser("~/.codex/config.toml")) else ""
        model = re.search(r'^model\s*=\s*"([^"]+)"', config, re.M)
        effort = re.search(r'^model_reasoning_effort\s*=\s*"([^"]+)"', config, re.M)
        self.model = os.environ.get("CODEX_MODEL") or (model.group(1) if model else None)
        self.effort = os.environ.get("CODEX_EFFORT") or (effort.group(1) if effort else "medium")
        for state in ["all", "main", "off"]:
            home = os.path.join(out, "codex-home", state)
            os.makedirs(home)
            if os.path.exists(auth):
                shutil.copy(auth, home)
            helper = os.path.join(apps, state, "Yap Eval.app/Contents/Helpers/yap-mcp")
            subprocess.run(["codex", "mcp", "add", "yap", "--", helper, "--data-dir", os.path.join(apps, state, "data")],
                           env=dict(os.environ, CODEX_HOME=home), check=True, capture_output=True)
            self.homes[state] = home

    def describe(self):
        return "%s, model %s, reasoning effort %s" % (self.version, self.model or "(default)", self.effort)

    def ask(self, question, folder):
        cwd = os.path.join(folder, "cwd")
        os.makedirs(cwd)
        command = ["codex", "exec", "--json", "--skip-git-repo-check", "--ephemeral", "-s", "read-only",
                   "-c", "model_reasoning_effort=%s" % self.effort]
        if self.model:
            command += ["-m", self.model]
        for feature in ["shell_tool", "unified_exec", "apps", "plugins", "browser_use", "computer_use", "memories",
                        "image_generation"]:
            command += ["--disable", feature]
        run = subprocess.run(command + [question["q"]], cwd=cwd, stdin=subprocess.DEVNULL, capture_output=True,
                             text=True, timeout=600, env=dict(os.environ, CODEX_HOME=self.homes[question["state"]]))
        open(os.path.join(folder, "events.jsonl"), "w").write(run.stdout)
        open(os.path.join(folder, "stderr.txt"), "w").write(run.stderr)
        calls, other, answer = [], [], ""
        for line in run.stdout.splitlines():
            try:
                event = json.loads(line)
            except ValueError:
                continue
            item = event.get("item") or {}
            if event.get("type") != "item.completed":
                if event.get("type") in ("error", "turn.failed"):
                    answer = answer or "(error) " + json.dumps(event, ensure_ascii=False)[:300]
                continue
            if item.get("type") == "mcp_tool_call":
                result = item.get("result") or {}
                # Codex marks a tool error (isError) as status "failed".
                calls.append({"tool": item.get("tool"), "arguments": item.get("arguments"),
                              "error": item.get("status") == "failed" or bool(item.get("error") or result.get("isError"))})
            elif item.get("type") == "agent_message":
                answer = item.get("text", "")
            elif item.get("type") not in ("reasoning", "todo_list"):
                other.append(item.get("type"))
        return calls, other, answer


class Claude:
    name = "claude"

    def __init__(self, apps, out):
        self.apps, self.out = apps, out
        if not shutil.which("claude"):
            self.skip = "claude isn't installed"
            return
        self.version = subprocess.run(["claude", "--version"], capture_output=True, text=True).stdout.strip()
        probe = subprocess.run(["claude", "-p", "Reply with the single word OK.", "--output-format", "json"],
                               cwd="/tmp", stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120)
        try:
            result = json.loads(probe.stdout)
            self.skip = None if not result.get("is_error") else (result.get("result") or "error").strip()
        except ValueError:
            self.skip = (probe.stdout + probe.stderr).strip()[:200] or "claude -p failed (exit %d)" % probe.returncode

    def describe(self):
        return "Claude Code %s, its default model" % self.version

    def ask(self, question, folder):
        cwd = os.path.join(folder, "cwd")
        os.makedirs(cwd)
        state = question["state"]
        config = os.path.join(folder, "mcp.json")
        json.dump({"mcpServers": {"yap": {"type": "stdio",
                                          "command": os.path.join(self.apps, state, "Yap Eval.app/Contents/Helpers/yap-mcp"),
                                          "args": ["--data-dir", os.path.join(self.apps, state, "data")]}}},
                  open(config, "w"))
        command = ["claude", "-p", question["q"], "--output-format", "stream-json", "--verbose", "--strict-mcp-config",
                   "--mcp-config", config, "--allowedTools", ",".join("mcp__yap__" + t for t in TOOLS),
                   "--disallowedTools", "Bash,Read,Edit,Write,Glob,Grep,WebFetch,WebSearch,Task,NotebookEdit"]
        run = subprocess.run(command, cwd=cwd, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=600)
        open(os.path.join(folder, "events.jsonl"), "w").write(run.stdout)
        open(os.path.join(folder, "stderr.txt"), "w").write(run.stderr)
        calls, other, answer, pending = [], [], "", {}
        for line in run.stdout.splitlines():
            try:
                event = json.loads(line)
            except ValueError:
                continue
            for part in (event.get("message") or {}).get("content") or []:
                if not isinstance(part, dict):
                    continue
                if part.get("type") == "tool_use":
                    if part.get("name", "").startswith("mcp__yap__"):
                        pending[part.get("id")] = len(calls)
                        calls.append({"tool": part["name"][len("mcp__yap__"):], "arguments": part.get("input"), "error": False})
                    else:
                        other.append(part.get("name"))
                elif part.get("type") == "tool_result" and part.get("tool_use_id") in pending:
                    calls[pending[part["tool_use_id"]]]["error"] = bool(part.get("is_error"))
            if event.get("type") == "result":
                answer = event.get("result") or ""
        return calls, other, answer


def main(apps, out):
    runs = int(os.environ.get("EVAL_RUNS", "1"))
    agents = [Codex(apps, out), Claude(apps, out)]
    for agent in agents:
        print("%s: %s" % (agent.name, "skipped: " + agent.skip if agent.skip else agent.describe()))
    jobs = [(agent, question, run) for agent in agents if not agent.skip for run in range(1, runs + 1)
            for question in QUESTIONS]
    if not jobs:
        print("no agent available; nothing was asked")
        return

    def ask(job):
        agent, question, run = job
        folder = os.path.join(out, agent.name, "run%d" % run, "q%02d" % question["id"])
        os.makedirs(folder)
        started = time.time()
        try:
            calls, other, answer = agent.ask(question, folder)
        except subprocess.TimeoutExpired:
            calls, other, answer = [], [], "(timed out)"
        passed, why = grade(question, answer, other)
        open(os.path.join(folder, "answer.md"), "w").write(answer + "\n")
        return {"agent": agent.name, "run": run, "id": question["id"], "kind": question["kind"], "state": question["state"],
                "question": question["q"], "calls": calls, "other_tools": other, "answer": answer, "passed": passed,
                "why": why, "seconds": round(time.time() - started)}

    with concurrent.futures.ThreadPoolExecutor(int(os.environ.get("EVAL_JOBS", "4"))) as pool:
        results = sorted(pool.map(ask, jobs), key=lambda r: (r["agent"], r["run"], r["id"]))
    json.dump(results, open(os.path.join(out, "results.json"), "w"), ensure_ascii=False, indent=1)

    switches = {"all": "both on", "main": "main only", "off": "off"}
    lines = ["# yap-mcp agent eval (%s)" % os.path.basename(out), ""]
    for agent in agents:
        lines.append("- %s: %s" % (agent.name, "skipped: " + agent.skip if agent.skip else agent.describe()))
    lines += ["", "| agent | run | # | kind | switches | tools called | calls | result | why |", "|---|---|---|---|---|---|---|---|---|"]
    for r in results:
        sequence = " → ".join(c["tool"] + (" (error)" if c["error"] else "") for c in r["calls"]) or "none"
        lines.append("| %s | %d | %d | %s | %s | %s | %d | %s | %s |" % (
            r["agent"], r["run"], r["id"], r["kind"], switches[r["state"]], sequence, len(r["calls"]),
            "pass" if r["passed"] else "**fail**", r["why"]))
    lines += [""]
    for agent in agents:
        mine = [r for r in results if r["agent"] == agent.name]
        if mine:
            switch_rows = [r for r in mine if r["state"] != "all"]
            lines.append("%s: %d/%d passed; switch questions %d/%d; %d tool calls, %d of them errors" % (
                agent.name, sum(r["passed"] for r in mine), len(mine), sum(r["passed"] for r in switch_rows),
                len(switch_rows), sum(len(r["calls"]) for r in mine), sum(c["error"] for r in mine for c in r["calls"])))
    lines += ["", "## Answers", ""]
    for r in results:
        question = next(q for q in QUESTIONS if q["id"] == r["id"])
        lines += ["### %s run %d, %d. %s" % (r["agent"], r["run"], r["id"], r["question"]), "",
                  "Expected: " + question["answer"], "",
                  "Calls: " + (", ".join("%s %s" % (c["tool"], json.dumps(c["arguments"], ensure_ascii=False)) for c in r["calls"]) or "none"), "",
                  "> " + r["answer"].replace("\n", "\n> "), ""]
    open(os.path.join(out, "results.md"), "w").write("\n".join(lines) + "\n")
    print("\n".join(line for line in lines if line.startswith("|") or ": " in line and "passed" in line))
    print("results: %s" % os.path.join(out, "results.md"))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
