import http.server, json, threading, subprocess, os, time, pathlib, sys
import tempfile
import queue
extension = pathlib.Path(os.environ.get('PI_EXEC_EXTENSION', pathlib.Path(__file__).resolve().parents[1] / 'extension.ts'))
base = pathlib.Path(tempfile.mkdtemp(prefix='pi-exec-test-'))
case = sys.argv[1]
folder = base / case
folder.mkdir()
for f in ['session.jsonl', 'events.jsonl']:
    (folder / f).unlink(missing_ok=True)

def log(event, **kw):
    with (folder / 'events.jsonl').open('a') as f:
        f.write(json.dumps(dict(time=int(time.time() * 1000), event=event, **kw)) + '\n')

class Handler(http.server.BaseHTTPRequestHandler):

    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        msgs = body['messages']
        log('model_request', messages=msgs)
        completed = any((m.get('role') == 'user' and 'Task exec-1:' in str(m.get('content')) for m in msgs))
        tool = any((m.get('role') == 'tool' for m in msgs))
        visible_output = '\n'.join(str(m.get('content')) for m in msgs if m.get('role') in ['tool', 'user'])
        if case == 'status' and completed and not any(str(m.get('tool_call_id', '')).startswith('status_') for m in msgs):
            delta = {'tool_calls': [{'index': i, 'id': f'status_{i}', 'type': 'function', 'function': {'name': 'exec_status', 'arguments': json.dumps({'taskId': 'exec-1'})}} for i in range(2)]}
            finish = 'tool_calls'
        elif case == 'foreground' and tool and 'UNIQUE_COMPLETION_8291' in visible_output:
            delta = {'content': 'VERIFIED_COMPLETION_8291'}
            finish = 'stop'
        elif completed and (case in ['cancel', 'tree', 'timeout'] or 'UNIQUE_COMPLETION_8291' in visible_output) and (case != 'multiple' or 'SECOND_COMPLETE' in visible_output):
            delta = {'content': 'VERIFIED_COMPLETION_8291'}
            finish = 'stop'
        elif case == 'abort' and completed:
            # The wake turn stalls here so exec-2's completion queues behind it:
            # that queued follow-up is what used to keep Pi busy past an abort.
            time.sleep(5)
            delta = {'content': 'WAKE_TURN_FINISHED'}
            finish = 'stop'
        elif case == 'rpc' and any('RPC_NEW_PROMPT' in str(m.get('content')) for m in msgs):
            delta = {'content': 'RPC_NEW_PROMPT_ACCEPTED'}
            finish = 'stop'
        elif tool and case in ['cancel', 'tree'] and (not any((m.get('role') == 'tool' and 'cancelled' in str(m.get('content')) for m in msgs))):
            delta = {'tool_calls': [{'index': 0, 'id': 'call_cancel', 'type': 'function', 'function': {'name': 'exec_cancel', 'arguments': json.dumps({'taskId': 'exec-1'})}}]}
            finish = 'tool_calls'
        elif tool:
            delta = {'content': 'INITIAL_TURN_FINISHED'}
            finish = 'stop'
        else:
            command = 'sleep 1; echo UNIQUE_COMPLETION_8291' + ('; exit 7' if case == 'failure' else '')
            if case == 'yield':
                command = 'sleep 11; echo UNIQUE_COMPLETION_8291'
            if case == 'rpc':
                command = 'sleep 3; echo UNIQUE_COMPLETION_8291'
            if case == 'abort':
                command = 'sleep 1; echo UNIQUE_COMPLETION_8291'
            if case in ['timeout', 'cancel']:
                command = 'exec sleep 20'
            if case == 'foreground':
                command = 'echo UNIQUE_COMPLETION_8291'
            if case == 'truncate':
                command = "seq 1 2000; echo UNIQUE_COMPLETION_8291"
            if case == 'logcap':
                command = "head -c 70000000 /dev/zero; echo UNIQUE_COMPLETION_8291"
            if case == 'tree':
                command = '(sleep 2; touch child-survived) & wait'
            delta = {'tool_calls': [{'index': 0, 'id': 'call_exp', 'type': 'function', 'function': {'name': 'bash', 'arguments': json.dumps(dict(command=command, background=case not in ['yield', 'foreground'], **{'timeout': 0.2} if case == 'timeout' else {}))}}]}
            finish = 'tool_calls'
            if case in ['multiple', 'abort']:
                second = 'sleep 3; echo SECOND_COMPLETE' if case == 'abort' else 'sleep 1.05; echo SECOND_COMPLETE'
                delta['tool_calls'].append({'index': 1, 'id': 'call_second', 'type': 'function', 'function': {'name': 'bash', 'arguments': json.dumps({'command': second, 'background': True})}})
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        for d, fin in [({'role': 'assistant'}, None), (delta, None), ({}, finish)]:
            self.wfile.write(('data: ' + json.dumps({'id': 'chatcmpl-test', 'object': 'chat.completion.chunk', 'created': int(time.time()), 'model': 'mock', 'choices': [{'index': 0, 'delta': d, 'finish_reason': fin}]}) + '\n\n').encode())
        self.wfile.write(b'data: [DONE]\n\n')
        self.wfile.flush()
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
(folder / 'models.json').write_text(json.dumps({'providers': {'mock': {'baseUrl': f'http://127.0.0.1:{server.server_port}/v1', 'api': 'openai-completions', 'apiKey': 'test', 'models': [{'id': 'mock', 'name': 'Mock', 'reasoning': False, 'input': ['text'], 'contextWindow': 128000, 'maxTokens': 1000, 'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0}}]}}}))
env = dict(os.environ, PI_CODING_AGENT_DIR=str(folder), PI_OFFLINE='1', PI_TELEMETRY='0')
cmd = [os.environ.get('PI_BIN', 'pi'), '-p', '--mode', 'json', '--session', str(folder / 'session.jsonl'), '--no-extensions', '--no-skills', '--no-prompt-templates', '--no-context-files', '--offline', '-e', str(extension)]
cmd += ['--provider', 'mock', '--model', 'mock', '--tools', 'bash,exec_cancel,exec_status', 'Run the command in background then finish this turn. Process the automatic result when it arrives.']
log('launch', command=cmd)
if case in ['rpc', 'abort']:
    cmd.remove('-p')
    cmd[cmd.index('--mode') + 1] = 'rpc'
    cmd.pop()
    events = queue.Queue()
    seen = []
    with (folder / 'stderr').open('w') as stderr:
        process = subprocess.Popen(cmd, env=env, cwd=folder, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr, text=True)
        def read_events():
            for line in process.stdout:
                events.put(json.loads(line))
        threading.Thread(target=read_events, daemon=True).start()
        def send(message):
            process.stdin.write(json.dumps(message) + '\n')
            process.stdin.flush()
        def until(predicate, timeout=10):
            deadline = time.monotonic() + timeout
            while True:
                event = events.get(timeout=max(0.01, deadline - time.monotonic()))
                seen.append(event)
                assert event.get('success') is not False, event
                assert event.get('type') != 'extension_error', event
                if predicate(event):
                    return event
        try:
            if case == 'abort':
                # Regression guard for the Paseo stop path: Pi acks `abort` only
                # once the run has settled, and an aborted run keeps going when
                # the follow-up queue still holds an exec completion. Paseo
                # therefore sends `clear_queue` first (lib/paseo patch); this
                # asserts that combination really does ack promptly against the
                # pinned Pi build.
                send({'id': 'first', 'type': 'prompt', 'message': 'Start background work.'})
                until(lambda event: event.get('type') == 'agent_settled')
                until(lambda event: event.get('type') == 'agent_start')
                time.sleep(3.5)
                start = time.monotonic()
                send({'id': 'drain', 'type': 'clear_queue'})
                until(lambda event: event.get('command') == 'clear_queue')
                send({'id': 'stop', 'type': 'abort'})
                until(lambda event: event.get('command') == 'abort', timeout=20)
                ack = time.monotonic() - start
                log('abort_ack_seconds', seconds=ack)
                assert ack < 2, (ack, seen)
                starts = sum(1 for event in seen if event.get('type') == 'agent_start')
                time.sleep(3)
                while not events.empty():
                    seen.append(events.get_nowait())
                assert sum(1 for event in seen if event.get('type') == 'agent_start') == starts, seen
                print('PASS', case, folder, f'ack={ack:.2f}s')
                sys.exit(0)
            send({'id': 'first', 'type': 'prompt', 'message': 'Start background work.'})
            until(lambda event: event.get('type') == 'agent_settled')
            assert not any('exec-completion' in str(event) for event in seen), seen
            send({'id': 'second', 'type': 'prompt', 'message': 'RPC_NEW_PROMPT'})
            until(lambda event: event.get('type') == 'message_end' and 'RPC_NEW_PROMPT_ACCEPTED' in str(event))
            assert not any('exec-completion' in str(event) for event in seen), seen
            until(lambda event: event.get('type') == 'message_end' and 'VERIFIED_COMPLETION_8291' in str(event))
            until(lambda event: event.get('type') == 'agent_settled')
            assert any('Task exec-1: completed' in str(event) for event in seen)
        finally:
            process.terminate()
            process.wait(timeout=10)
            (folder / 'stdout.jsonl').write_text('\n'.join(json.dumps(event) for event in seen))
            server.shutdown()
    print('PASS', case, folder)
    sys.exit(0)
try:
    p = subprocess.run(cmd, env=env, cwd=folder, stdin=subprocess.DEVNULL, stdout=(folder / 'stdout.jsonl').open('w'), stderr=(folder / 'stderr').open('w'), timeout=45)
    log('exit', code=p.returncode)
    print(case, p.returncode)
except subprocess.TimeoutExpired:
    log('harness_timeout')
    raise
server.shutdown()
output = (folder / 'stdout.jsonl').read_text()
assert 'VERIFIED_COMPLETION_8291' in output, (folder, (folder / 'stderr').read_text())
expected = {'success': 'completed', 'failure': 'failed', 'timeout': 'timed_out', 'cancel': 'cancelled', 'yield': 'completed', 'foreground': 'completed', 'multiple': 'completed', 'tree': 'cancelled', 'status': 'completed', 'truncate': 'completed', 'logcap': 'completed'}[case]
assert f'Task exec-1: {expected}' in output, output
assert p.returncode == 0
if case == 'foreground':
    assert 'exec-completion' not in output
if case == 'multiple':
    assert 'Task exec-2: completed' in output
events = [json.loads(line) for line in output.splitlines()]
notifications = [event['message'] for event in events if event.get('type') == 'message_end' and event.get('message', {}).get('customType') == 'exec-completion']
for notification in notifications:
    assert len(notification['content'].encode()) <= 8192
if case == 'multiple':
    assert len(notifications) == 1, notifications
    assert len(notifications[0]['details']['tasks']) == 2
if case == 'status':
    results = [event['result'] for event in events if event.get('type') == 'tool_execution_end' and event.get('toolName') == 'exec_status']
    assert len(results) == 2
    assert all('UNIQUE_COMPLETION_8291' not in str(result) and 'Bytes:' in str(result) for result in results)
if case in ['truncate', 'logcap']:
    content = notifications[0]['content']
    assert 'UNIQUE_COMPLETION_8291' in content
    assert len(content.splitlines()) <= 84
    path = pathlib.Path(notifications[0]['details']['tasks'][0]['outputPath'])
    if case == 'logcap':
        assert path.stat().st_size == 64 * 1024 * 1024
        assert 'Log truncated' in content
    else:
        assert path.read_text().startswith('1\n2\n')
if case == 'tree':
    time.sleep(2.5)
    assert not (folder / 'child-survived').exists()
print('PASS', case, folder)
