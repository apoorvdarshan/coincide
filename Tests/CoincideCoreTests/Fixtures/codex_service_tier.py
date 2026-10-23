"""Private offline service-tier app-server peer: no providers, auth, or network."""
import json
import os
import sys
import time

root = sys.argv[1]
thread_id = 'tier-thread'
turn = 0
effective = 'native-config-default'

def options():
    with open(os.path.join(root, 'options.json'), encoding='utf-8') as source:
        return json.load(source)

def emit(value):
    print(json.dumps(value, ensure_ascii=False), flush=True)

def complete(status='completed'):
    emit({'method': 'turn/completed', 'params': {'threadId': thread_id, 'turn': {'id': 'tier-turn-' + str(turn), 'status': status}}})

for line in sys.stdin:
    frame = json.loads(line)
    with open(os.path.join(root, 'wire.jsonl'), 'a', encoding='utf-8') as target:
        target.write(json.dumps(frame, ensure_ascii=False) + '\n')
    method, identifier = frame.get('method'), frame.get('id')
    if identifier is None:
        assert method == 'initialized'
        continue
    config, params = options(), frame.get('params') or {}
    if method == 'initialize':
        effective = config.get('initialTier', effective)
        emit({'id': identifier, 'result': {'userAgent': 'coincide/0.163.0'}})
    elif method == 'model/list':
        if config.get('holdCatalog'):
            open(os.path.join(root, 'catalog-entered'), 'w').close()
            while not os.path.exists(os.path.join(root, 'release-catalog')):
                time.sleep(0.005)
            config = options()
        if config.get('catalogError'):
            emit({'id': identifier, 'error': {'code': -32603, 'message': 'PRIVATE-TIER-ERROR-MUST-NOT-LEAK'}})
        else:
            emit({'id': identifier, 'result': {'data': config.get('models', []), 'nextCursor': None}})
    elif method in ('thread/start', 'thread/resume'):
        if method == 'thread/resume':
            thread_id = params['threadId']
        emit({'id': identifier, 'result': {'thread': {'id': thread_id, 'historyMode': params.get('historyMode', 'paginated')},
                                          'serviceTier': effective}})
    elif method == 'turn/start':
        turn += 1
        if 'serviceTier' in params:
            effective = params['serviceTier'] if params['serviceTier'] is not None else 'native-config-default'
        emit({'id': identifier, 'result': {'turn': {'id': 'tier-turn-' + str(turn)}}})
        emit({'method': 'item/completed', 'params': {'threadId': thread_id, 'turnId': 'tier-turn-' + str(turn),
              'item': {'id': 'tier-result-' + str(turn), 'type': 'agentMessage', 'text': effective}}})
        if not config.get('keepRunning'):
            complete()
    elif method == 'turn/steer':
        assert 'serviceTier' not in params
        emit({'id': identifier, 'result': {'turnId': params['expectedTurnId']}})
    elif method == 'turn/interrupt':
        emit({'id': identifier, 'result': {}})
        complete('interrupted')
    else:
        emit({'id': identifier, 'error': {'code': -32601, 'message': 'Unexpected private tier-fixture method'}})
