"""Deterministic protocol peer. Never contacts a model or reads user settings."""
import json
import sys
import time

mode = sys.argv[1]
held = []

def emit(value):
    # Split UTF-8 bytes and frame boundaries to exercise the transport.
    data = (json.dumps(value, ensure_ascii=False) + '\n').encode()
    for chunk in (data[:7], data[7:]):
        sys.stdout.buffer.write(chunk)
        sys.stdout.buffer.flush()

for line in sys.stdin:
    frame = json.loads(line)
    method = frame.get('method')
    ident = frame.get('id')
    params = frame.get('params', {})
    if mode == 'hang':
        continue
    if mode == 'malformed':
        print('not json', flush=True)
        break
    if mode == 'exit':
        break
    if mode == 'reverse':
        held.append(frame)
        if len(held) == 2:
            for pending in reversed(held):
                emit({'id': pending['id'], 'result': pending['params']})
            held.clear()
        continue
    if mode == 'codex':
        if method == 'initialize':
            assert params['clientInfo']['name'] == 'coincide'
            emit({'id': ident, 'result': {'userAgent': 'fixture/1'}})
        elif method == 'model/list':
            emit({'id': ident, 'result': {'data': [{'id': 'fixture', 'model': 'fixture-model', 'displayName': 'Fixture Model'}]}})
        elif method in ('thread/start', 'thread/resume'):
            emit({'id': ident, 'result': {'thread': {'id': params.get('threadId', 'thread-1')}}})
        elif method == 'turn/start':
            assert params['approvalPolicy'] == 'on-request'
            assert params['sandboxPolicy']['type'] == 'readOnly'
            emit({'id': ident, 'result': {'turn': {'id': 'turn-1'}}})
            emit({'method': 'turn/started', 'params': {'threadId': 'thread-1', 'turn': {'id': 'turn-1'}}})
            emit({'method': 'item/commandExecution/requestApproval', 'id': 'approval-1', 'params': {'threadId': 'thread-1', 'command': 'echo fixture'}})
        elif ident == 'approval-1':
            assert frame['result']['decision'] == 'accept'
            emit({'method': 'item/agentMessage/delta', 'params': {'threadId': 'thread-1', 'itemId': 'message-1', 'delta': 'hello 🌍'}})
            emit({'method': 'item/completed', 'params': {'threadId': 'thread-1', 'item': {'id': 'message-1', 'type': 'agentMessage', 'text': 'hello 🌍'}}})
            emit({'method': 'turn/completed', 'params': {'threadId': 'thread-1', 'turn': {'id': 'turn-1', 'status': 'completed'}}})
        elif method == 'turn/interrupt':
            emit({'id': ident, 'result': {}})
            emit({'method': 'turn/completed', 'params': {'threadId': 'thread-1', 'turn': {'id': 'turn-1', 'status': 'interrupted'}}})
        continue
    if ident is not None:
        emit({'id': ident, 'result': params})
