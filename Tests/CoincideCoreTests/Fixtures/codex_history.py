"""Offline Codex 0.163 app-server peer for conversation-history contracts.

The test supplies a private configuration and wire-log path. No subprocess,
network, repository, or user Codex state is accessed by this peer.
"""
import json
import os
import sys
import time

config_path, log_path = sys.argv[1:3]
threads = {}
turn_number = 0
pending_start_ack = None


def configuration():
    with open(config_path, encoding='utf-8') as source:
        return json.load(source)


def emit(frame):
    print(json.dumps(frame), flush=True)


def native_turn(identifier, status='completed'):
    return {'id': identifier, 'rootTurnId': None, 'items': [],
            'itemsView': 'summary', 'status': status, 'error': None,
            'startedAt': 1, 'completedAt': 2, 'durationMs': 1000}


def source_turns(config):
    return config.get('turns', [native_turn('native-3'),
                              native_turn('native-2', 'interrupted'),
                              native_turn('native-1', 'failed')])


def turns_for(identifier, config):
    return threads.get(identifier, {}).get('turns', source_turns(config))


def thread(identifier, config):
    stored = threads.get(identifier, {})
    status = config.get('threadStatus', 'idle')
    status = {'type': status} if isinstance(status, str) else status
    result = {
        'id': identifier, 'environments': None, 'extra': None,
        'sessionId': 'fixture-session', 'forkedFromId': stored.get('source'),
        'parentThreadId': None, 'preview': 'Offline history fixture',
        'ephemeral': False, 'section': None, 'sectionEnteredAt': None,
        'projectId': None, 'historyMode': stored.get('historyMode', config.get('historyMode', 'paginated')),
        'modelProvider': 'openai', 'model': 'fixture-model',
        'reasoningEffort': None, 'createdAt': 1, 'updatedAt': 2,
        'recencyAt': 2, 'status': status, 'path': None,
        'cwd': config['cwd'], 'cliVersion': '0.163.0',
        'originator': 'coincide', 'source': 'cli',
        'canAcceptDirectInput': True, 'threadSource': None,
        'agentNickname': None, 'agentRole': None, 'gitInfo': None,
        'name': None, 'daybreakEnabled': None,
        # Thread snapshots use chronological order; turns/list is descending.
        'turns': list(reversed(turns_for(identifier, config))),
    }
    return result


def page(identifier, params, config):
    cursor = params.get('cursor') or ''
    if config.get('infinitePages'):
        number = int(cursor or '0')
        return {'data': [native_turn('page-turn-' + str(number))],
                'nextCursor': str(number + 1), 'backwardsCursor': None}
    if 'pages' in config and identifier not in threads:
        return config['pages'].get(cursor, {'data': [], 'nextCursor': None,
                                           'backwardsCursor': None})
    turns = turns_for(identifier, config)
    start = int(cursor.removeprefix('offset:')) if cursor else 0
    limit = params.get('limit') or 100
    selected = turns[start:start + limit]
    next_cursor = 'offset:' + str(start + limit) if start + limit < len(turns) else None
    return {'data': selected, 'nextCursor': next_cursor, 'backwardsCursor': None}


for line in sys.stdin:
    frame = json.loads(line)
    if pending_start_ack and os.path.exists(pending_start_ack['release']):
        emit(pending_start_ack['frame'])
        pending_start_ack = None
    with open(log_path, 'a', encoding='utf-8') as log:
        log.write(json.dumps(frame) + '\n')
        log.flush()
    method, identifier = frame.get('method'), frame.get('id')
    if identifier is None:
        continue
    params = frame.get('params') or {}
    config = configuration()
    gate = config.get('gates', {}).get(method)
    if gate:
        with open(gate['entered'], 'w', encoding='utf-8') as marker:
            marker.write(method)
        while not os.path.exists(gate['release']):
            time.sleep(.005)
        config = configuration()
    if method in config.get('methodErrors', {}):
        emit({'id': identifier, 'error': config['methodErrors'][method]})
        continue
    if method in config.get('disconnectMethods', []):
        sys.exit(0)
    result = None
    if method == 'initialize':
        result = {'userAgent': config.get('userAgent', 'coincide/0.163.0 (macos; arm64)'),
                  'codexHome': config['cwd'], 'platformFamily': 'unix',
                  'platformOs': 'macos'}
    elif method == 'thread/read':
        result = {'thread': thread(params['threadId'], config), 'readState': None}
        result['thread'].update(config.get('readOverrides', {}))
    elif method == 'thread/turns/list':
        result = page(params['threadId'], params, config)
    elif method == 'thread/goal/get':
        status = config.get('goalStatus')
        goal = None if status is None else {
            'threadId': config.get('goalThreadID', params['threadId']),
            'objective': 'Offline fixture goal', 'status': status,
            'tokenBudget': None, 'tokensUsed': 0, 'timeUsedSeconds': 0,
            'createdAt': 1, 'updatedAt': 2}
        result = config.get('goalReply', {'goal': goal})
    elif method in ('thread/fork', 'thread/revert'):
        source = params['threadId']
        turns = turns_for(source, config)
        selected = turns
        boundary = params.get('lastTurnId') or params.get('beforeTurnId')
        if boundary:
            matches = [index for index, item in enumerate(turns) if item['id'] == boundary]
            if not matches:
                emit({'id': identifier, 'error': {'code': -32602, 'message': 'Unknown native boundary'}})
                continue
            offset = matches[0] + (1 if 'beforeTurnId' in params else 0)
            selected = turns[offset:]
        target = config.get('forkThreadID', 'native-fork') if method == 'thread/fork' else source
        threads[target] = {'turns': config.get('forkTurns', selected) if method == 'thread/fork' else selected,
                           'source': source if method == 'thread/fork' else None}
        result = {'thread': thread(target, config)}
        result['thread'].update(config.get('mutationOverrides', {}))
    elif method in ('thread/resume', 'thread/start'):
        target = params.get('threadId', 'native-source')
        if method == 'thread/start':
            # Model a legacy-default peer so the test requires an explicit
            # paginated historyMode request.
            threads[target] = {'turns': source_turns(config),
                               'historyMode': params.get('historyMode', config.get('historyMode', 'legacy'))}
        result = {'thread': thread(target, config)}
    elif method == 'turn/start':
        turn_number += 1
        native_id = 'explicit-turn-' + str(turn_number)
        result = {'turn': native_turn(native_id)}
        completion = {'method': 'turn/completed', 'params': {
            'threadId': params['threadId'], 'turn': native_turn(native_id)}}
        delayed = config.get('delayedFirstStartAcknowledgement') if turn_number == 1 else None
        if delayed:
            # Keep reading history RPCs while this already-completed start awaits
            # acknowledgement. A later request flushes it after explicit release.
            pending_start_ack = {'frame': {'id': identifier, 'result': result},
                                 'release': delayed['release']}
            emit(completion)
            with open(delayed['entered'], 'w', encoding='utf-8') as marker:
                marker.write('completed-before-start-ack')
        elif config.get('completionBeforeStartAcknowledgement'):
            emit(completion)
            emit({'id': identifier, 'result': result})
        else:
            emit({'id': identifier, 'result': result})
            emit(completion)
        continue
    elif method == 'model/list':
        result = {'data': []}
    else:
        emit({'id': identifier, 'error': {'code': -32601, 'message': 'Fixture method unsupported'}})
        continue
    if method in config.get('responseOverrides', {}):
        result = config['responseOverrides'][method]
    emit({'id': identifier, 'result': result})
