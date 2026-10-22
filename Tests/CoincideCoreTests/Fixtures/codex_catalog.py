"""Offline model-catalog peer; never reads provider credentials or uses network."""
import json
import os
import sys
import time

options_path, wire_path = sys.argv[1:3]
model_requests = 0
did_gate = False
turn_number = 0
thread_id = 'catalog-thread'


def options():
    with open(options_path, encoding='utf-8') as source:
        return json.load(source)


def emit(frame):
    print(json.dumps(frame, ensure_ascii=False), flush=True)


for line in sys.stdin:
    frame = json.loads(line)
    with open(wire_path, 'a', encoding='utf-8') as log:
        log.write(json.dumps(frame) + '\n')
    method, identifier = frame.get('method'), frame.get('id')
    if identifier is None:
        continue
    config = options()
    if method == 'initialize':
        if config.get('initializeError'):
            emit({'id': identifier, 'error': {'code': -32603, 'message': 'synthetic-private-token'}})
        else:
            emit({'id': identifier, 'result': {'userAgent': config.get('userAgent', 'coincide/0.163.0')}})
    elif method == 'model/list':
        model_requests += 1
        if config.get('entered') and not did_gate:
            did_gate = True
            with open(config['entered'], 'w', encoding='utf-8') as marker:
                marker.write('owned catalog request')
            while not os.path.exists(config['release']):
                time.sleep(.005)
            config = options()
        if config.get('listError'):
            emit({'id': identifier, 'error': {'code': -32603, 'message': 'synthetic-private-token'}})
            continue
        params = frame.get('params') or {}
        if config.get('infinitePages'):
            result = {'data': [], 'nextCursor': 'page:' + str(model_requests)}
        elif config.get('rowOverflow'):
            result = {'data': [{'model': 'wire-' + str(i)} for i in range(101)]}
        elif config.get('byteOverflow'):
            result = {'data': [], 'unusedProviderField': 'x' * (8 * 1024 * 1024)}
        else:
            result = config.get('pages', {}).get(params.get('cursor') or '', {'data': []})
        emit({'id': identifier, 'result': result})
    elif method == 'config/read':
        if config.get('configReadError'):
            emit({'id': identifier, 'error': {'code': -32603, 'message': 'synthetic-private-token'}})
            continue
        settings = config.get('cliConfig', {'model': None, 'model_reasoning_effort': None})
        if model_requests and 'changedCliConfig' in config:
            settings = config['changedCliConfig']
        emit({'id': identifier, 'result': {'config': settings, 'layers': None, 'origins': {}}})
    elif method == 'thread/start':
        emit({'id': identifier, 'result': {'thread': {'id': thread_id,
              'historyMode': (frame.get('params') or {}).get('historyMode', 'paginated')}}})
    elif method == 'thread/resume':
        thread_id = frame['params']['threadId']
        emit({'id': identifier, 'result': {'thread': {'id': thread_id, 'historyMode': 'paginated'}}})
    elif method == 'turn/start':
        turn_number += 1
        emit({'id': identifier, 'result': {'turn': {'id': 'catalog-turn-' + str(turn_number)}}})
    elif method == 'turn/steer':
        emit({'id': identifier, 'result': {'turnId': frame['params']['expectedTurnId']}})
    elif method == 'turn/interrupt':
        emit({'id': identifier, 'result': {}})
        emit({'method': 'turn/completed', 'params': {'threadId': thread_id,
              'turn': {'id': 'catalog-turn-' + str(turn_number), 'status': 'interrupted'}}})
    else:
        emit({'id': identifier, 'error': {'code': -32601, 'message': 'Unexpected catalog-fixture method'}})
