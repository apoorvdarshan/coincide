"""Owned offline app-server fixture. No provider, account, network, or shell calls."""
import json
import os
import sys
import threading
import time

root = sys.argv[1]
lock = threading.RLock()
thread_id = 'plan-thread'
turn_index = 0
seen_signal = None

def options():
    with open(os.path.join(root, 'options.json'), encoding='utf8') as file:
        return json.load(file)

def emit(value):
    with lock:
        print(json.dumps(value, ensure_ascii=False), flush=True)

def notify(method, native_turn, **fields):
    emit({'method': method, 'params': dict(fields, threadId=thread_id, turnId=native_turn)})

def item(method, turn, identifier, text):
    notify(method, turn, item={'type': 'plan', 'id': identifier, 'text': text})

def terminal(status='completed'):
    emit({'method': 'turn/completed', 'params': {'threadId': thread_id, 'turn': {'id': 'plan-turn-' + str(turn_index), 'status': status}}})

def signals():
    global seen_signal
    while True:
        signal = options().get('signal')
        if signal and signal != seen_signal:
            seen_signal = signal
            if signal == 'finish':
                terminal()
            elif signal == 'late-original':
                item('item/completed', 'plan-turn-1', 'late-native-item', 'Original run late plan')
                emit({'method': 'item/completed', 'params': {'threadId': 'foreign-thread', 'turnId': 'plan-turn-1',
                      'item': {'type': 'plan', 'id': 'foreign-item', 'text': 'Foreign output must stay absent'}}})
                item('item/completed', 'unowned-turn', 'unowned-item', 'Unowned output must stay absent')
        time.sleep(0.005)

threading.Thread(target=signals, daemon=True).start()
for line in sys.stdin:
    frame = json.loads(line)
    with open(os.path.join(root, 'wire.jsonl'), 'a', encoding='utf8') as wire:
        wire.write(json.dumps(frame, ensure_ascii=False) + '\n')
    method, identifier = frame.get('method'), frame.get('id')
    if identifier is None:
        assert method == 'initialized'
        continue
    config, params = options(), frame.get('params') or {}
    if method == 'initialize':
        emit({'id': identifier, 'result': {'userAgent': config.get('userAgent', 'coincide/0.163.0')}})
    elif method == 'config/read':
        emit({'id': identifier, 'result': {'config': config.get('cliConfig', {'model': 'wire-model', 'model_reasoning_effort': 'high'})}})
    elif method == 'model/list':
        emit({'id': identifier, 'result': {'data': [{'id': 'catalog-wire-model', 'model': 'wire-model', 'isDefault': True,
              'defaultReasoningEffort': 'high', 'supportedReasoningEfforts': [{'reasoningEffort': 'high', 'description': 'Native'}]}], 'nextCursor': None}})
    elif method in ('thread/start', 'thread/resume'):
        thread_id = params.get('threadId', thread_id)
        response_thread = {'id': thread_id}
        if params.get('historyMode') is not None:
            assert params['historyMode'] == 'paginated'
            response_thread['historyMode'] = params['historyMode']
        emit({'id': identifier, 'result': {'thread': response_thread}})
    elif method == 'turn/start':
        turn_index += 1
        turn = 'plan-turn-' + str(turn_index)
        notify('turn/started', turn, turn={'id': turn})
        emit({'id': identifier, 'result': {'turn': {'id': turn}}})
        scenario = config.get('scenario', 'normal')
        if scenario == 'orphan-delta':
            notify('item/plan/delta', turn, itemId='missing-start', delta='Cannot guess a prefix')
            continue
        if scenario == 'oversized':
            item('item/started', turn, 'plan-item', 'x' * (2 * 1048576 + 1))
            continue
        item('item/started', turn, 'plan-item', '')
        notify('item/plan/delta', turn, itemId='plan-item', delta='# Partial e\u0301 ')
        notify('item/plan/delta', turn, itemId='plan-item', delta='stream')
        final = '# Final e\u0301 plan ' + str(turn_index) + '\n\nImplement exact source.\n'
        item('item/completed', turn, 'plan-item', final)
        item('item/completed', turn, 'plan-item', final)
        notify('item/plan/delta', turn, itemId='plan-item', delta='Delayed delta must not append')
        notify('turn/plan/updated', turn, explanation='Observed task list', plan=[{'step': 'Read sources', 'status': 'completed'}, {'step': 'Run checks', 'status': 'in_progress'}])
        if scenario == 'conflicting-final':
            item('item/completed', turn, 'plan-item', 'Changed final snapshot')
            continue
        if scenario == 'oversized-todos':
            notify('turn/plan/updated', turn, plan=[{'step': 'Too many', 'status': 'pending'}] * 513)
            continue
        if not config.get('holdTurn'):
            terminal()
    elif method == 'turn/steer':
        assert 'collaborationMode' not in params
        emit({'id': identifier, 'result': {'turnId': params['expectedTurnId']}})
    elif method == 'turn/interrupt':
        emit({'id': identifier, 'result': {}})
        terminal('interrupted')
    else:
        emit({'id': identifier, 'error': {'code': -32601, 'message': 'Unexpected owned plan-fixture request'}})
