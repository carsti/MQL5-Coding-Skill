"""Bounded stdio client for the pinned CLI's actual skills/list discovery.

Invoked inside workflow_process.run_owned; all descendants belong to that job.
No model request, credential value, or global configuration write is made here.
"""
from __future__ import annotations
import json
import queue
import subprocess
import sys
import threading
import time


def request_skills(command: list[str], cwd: str, seconds: float = 25) -> dict:
    process = subprocess.Popen(command, cwd=cwd, stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=sys.stderr,
                               creationflags=0x08000000 if sys.platform == 'win32' else 0)
    responses: queue.Queue = queue.Queue()
    deadline = time.monotonic() + seconds

    def read():
        size = 0
        try:
            while True:
                line = process.stdout.readline(1048577)
                if not line:
                    responses.put(RuntimeError('Discovery stream ended')); return
                size += len(line)
                if len(line) > 1048576 or size > 4194304:
                    responses.put(RuntimeError('Discovery output limit')); return
                responses.put(json.loads(line))
        except (OSError, ValueError, UnicodeError):
            responses.put(RuntimeError('Invalid discovery response'))

    reader = threading.Thread(target=read, daemon=True); reader.start()

    def send(value):
        process.stdin.write((json.dumps(value) + '\n').encode()); process.stdin.flush()

    def receive(identifier):
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0: raise RuntimeError('Discovery deadline')
            try: value = responses.get(timeout=remaining)
            except queue.Empty: raise RuntimeError('Discovery deadline') from None
            if isinstance(value, Exception): raise value
            if not isinstance(value, dict): raise RuntimeError('Invalid discovery root')
            if value.get('id') != identifier: continue
            if 'error' in value or 'result' not in value: raise RuntimeError('Discovery request failed')
            return value['result']

    try:
        send({'id': 1, 'method': 'initialize', 'params': {'clientInfo': {'name': 'mql5-evaluation', 'version': '1'}}})
        receive(1); send({'method': 'initialized', 'params': {}})
        send({'id': 2, 'method': 'skills/list', 'params': {'cwds': [cwd], 'forceReload': True}})
        result = receive(2)
        process.stdin.close()
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired: raise RuntimeError('Discovery shutdown deadline') from None
        if process.returncode != 0: raise RuntimeError('Discovery server failed')
        return result
    finally:
        if process.poll() is None:
            process.terminate()
            try: process.wait(timeout=2)
            except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=2)
        if not process.stdin.closed: process.stdin.close()
        reader.join(timeout=2)
        process.stdout.close()


if __name__ == '__main__':
    try:
        # Remaining arguments are an already constructed argument vector, not shell text.
        result = request_skills(sys.argv[2:], sys.argv[1])
        sys.stdout.write(json.dumps(result, ensure_ascii=True) + '\n')
    except (OSError, RuntimeError, ValueError, IndexError, subprocess.SubprocessError):
        sys.stderr.write('CLI skill discovery failed; inspect retained bounded evidence.\n')
        sys.exit(2)
