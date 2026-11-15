"""AHKDeck MCP stdio 客户端 —— 每个脚本自己的实机测试都从这里起宿主。

端点：`.build/AHKDeck.exe --mcp-stdio`（临时实例）。只结束本进程自己拉起的那个实例，
绝不动用户手开的主程序，也不读写全局 `~/.workbuddy/mcp.json`。

用法：
  python tools/mcp_client.py probe                    # 握手 + 工具表 + 脚本清单
  python tools/mcp_client.py close-loop <脚本名>      # 跑一个脚本的实机闭环

脚本级测试请写在自己的 `scripts/<名>/test/run.py` 里，`from mcp_client import MCP`
（`sys.path` 指到 tools/），**不要**在这里堆某个脚本的业务断言。
"""
import json
import os
import queue
import subprocess
import sys
import threading
import time

_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EXE = os.path.join(_ROOT, ".build", "AHKDeck.exe")


class MCP:
    def __init__(self, timeout=40):
        self.p = subprocess.Popen(
            [EXE, "--mcp-stdio"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding="utf-8", errors="replace", bufsize=1,
        )
        self.q = queue.Queue()
        self.rid = 0
        self.timeout = timeout
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()
        self.err_lines = []

    def _read_stdout(self):
        for line in self.p.stdout:
            line = line.strip()
            if line:
                self.q.put(line)
        self.q.put(None)

    def _read_stderr(self):
        for line in self.p.stderr:
            self.err_lines.append(line.rstrip())

    def request(self, method, params=None):
        self.rid += 1
        obj = {"jsonrpc": "2.0", "id": self.rid, "method": method}
        if params is not None:
            obj["params"] = params
        self.p.stdin.write(json.dumps(obj, ensure_ascii=False) + "\n")
        self.p.stdin.flush()
        deadline = time.time() + self.timeout
        while time.time() < deadline:
            try:
                line = self.q.get(timeout=0.5)
            except queue.Empty:
                continue
            if line is None:
                raise RuntimeError("stdout closed before response: " + method)
            try:
                data = json.loads(line)
            except json.JSONDecodeError:
                continue
            if data.get("id") == self.rid:
                return data
        raise TimeoutError("no response for " + method)

    def notify(self, method, params=None):
        obj = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            obj["params"] = params
        self.p.stdin.write(json.dumps(obj, ensure_ascii=False) + "\n")
        self.p.stdin.flush()

    def call(self, name, args=None):
        r = self.request("tools/call", {"name": name, "arguments": args or {}})
        if "error" in r:
            return {"tool_error": r["error"]}
        res = r.get("result", {})
        texts = []
        for c in res.get("content", []):
            if c.get("type") == "text":
                texts.append(c.get("text", ""))
        raw = "\n".join(texts)
        try:
            return json.loads(raw)
        except (json.JSONDecodeError, TypeError):
            return {"raw": raw, "isError": res.get("isError", False)}

    def initialize(self):
        r = self.request("initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "ahkdeck-ui-migration", "version": "1.0"},
        })
        self.notify("notifications/initialized")
        return r

    def close(self):
        try:
            self.p.stdin.close()
        except Exception:
            pass
        try:
            self.p.wait(timeout=3)
        except Exception:
            self.p.terminate()
            try:
                self.p.wait(timeout=3)
            except Exception:
                self.p.kill()


def text_of(v):
    if isinstance(v, dict):
        return json.dumps(v, ensure_ascii=False)
    return str(v)


def main():
    if len(sys.argv) < 2:
        print("need a command")
        return 2
    cmd = sys.argv[1]
    m = MCP()
    try:
        init = m.initialize()
        print("INITIALIZE:", json.dumps(init.get("result", {}), ensure_ascii=False)[:400])
        if cmd == "probe":
            tl = m.request("tools/list")
            names = [t["name"] for t in tl.get("result", {}).get("tools", [])]
            print("TOOLS:", names)
            print("LIST_SCRIPTS:", text_of(m.call("list_scripts"))[:1500])
        elif cmd == "close-loop":
            script = sys.argv[2]
            args = sys.argv[3:]
            print("LIST_SCRIPTS:", text_of(m.call("list_scripts"))[:800])
            print("RUN_SCRIPT:", text_of(m.call("run_script", {"script": script, "args": args}))[:800])
            time.sleep(1.2)
            print("SESSION_OUTPUT:", text_of(m.call("get_session_output", {}))[:2500])
            print("STOP_ALL:", text_of(m.call("stop_all"))[:800])
            print("STDERR_TAIL:", m.err_lines[-8:])
        else:
            print("unknown command")
            return 2
    finally:
        m.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
