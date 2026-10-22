"""Codex peer with two completed turns whose start acknowledgements arrive late."""
import json
import sys
import time

pending = []
turn = 0
completion_only = len(sys.argv) > 1 and sys.argv[1] == 'completion-only'

def emit(frame):
    print(json.dumps(frame), flush=True)

def notify(method, params):
    emit({'method': method, 'params': {'threadId': 'pipeline-thread', **params}})

for line in sys.stdin:
    frame = json.loads(line)
    method = frame.get('method')
    ident = frame.get('id')
    if method == 'initialize':
        emit({'id': ident, 'result': {}})
    elif method == 'thread/start':
        emit({'id': ident, 'result': {'thread': {'id': 'pipeline-thread'}}})
    elif method == 'turn/start':
        turn += 1
        native = 'turn-' + str(turn)
        if not completion_only or turn >= 3:
            notify('turn/started', {'turn': {'id': native}})
        if turn < 3:
            pending.append((ident, native))
            notify('turn/completed', {'turn': {'id': native, 'status': 'completed'}})
        else:
            emit({'id': ident, 'result': {'turn': {'id': native}}})
            time.sleep(.03)
            for old_id, old_turn in reversed(pending):
                emit({'id': old_id, 'result': {'turn': {'id': old_turn}}})
            notify('item/agentMessage/delta', {'turnId': native, 'itemId': 'marker', 'delta': 'ACKS_DONE'})
    elif method == 'turn/interrupt':
        if frame['params']['turnId'] != 'turn-3':
            emit({'id': ident, 'error': {'message': 'Interrupt targeted a completed turn'}})
        else:
            emit({'id': ident, 'result': {}})
            notify('turn/completed', {'turn': {'id': 'turn-3', 'status': 'interrupted'}})
