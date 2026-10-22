"""Offline steering peers. Only private test configuration/wire files are used.

No provider executable, credentials, subprocess, or network is accessed.
"""
import json
import os
import select
import sys

dialect, options_path, wire_path = sys.argv[1:4]
turn = 0
last_signal = None
pending = []
input_bytes = bytearray()
input_lines = []
steering_segments_pending = False


def options():
    with open(options_path, encoding='utf-8') as source:
        return json.load(source)


def emit(value):
    print(json.dumps(value, ensure_ascii=False), flush=True)


def response(identifier, result):
    emit({'id': identifier, 'result': result})


def control(identifier, result=None):
    emit({'type': 'control_response', 'response': {
        'subtype': 'success', 'request_id': identifier, 'response': result or {}}})


def native_turn():
    return 'native-turn-' + str(turn)


def finish(interrupted=False, reason=None):
    if dialect == 'codex':
        emit({'method': 'turn/completed', 'params': {
            'threadId': 'native-source', 'turn': {'id': native_turn(),
                'status': 'interrupted' if interrupted else 'completed'}}})
    else:
        emit({'type': 'result', 'session_id': 'native-source',
              'is_error': interrupted, 'result': 'Owned offline reply',
              'terminal_reason': reason or ('aborted_tools' if interrupted else 'end_turn')})


def signal(name):
    if name == 'complete':
        finish()
    elif name == 'abort_tools':
        finish(reason='aborted_tools')
    elif name == 'abort_streaming':
        finish(reason='aborted_streaming')
    elif name == 'agent_assistant':
        emit({'type': 'assistant', 'session_id': 'native-source', 'parent_tool_use_id': None,
              'message': {'id': 'agent-launch', 'content': [
                  {'type': 'tool_use', 'id': 'foreground-agent', 'name': 'Agent', 'input': {}}]}})
    elif name == 'agent_stream':
        emit({'type': 'stream_event', 'session_id': 'native-source', 'parent_tool_use_id': None,
              'event': {'type': 'content_block_start', 'index': 0, 'content_block': {
                  'type': 'tool_use', 'id': 'foreground-agent', 'name': 'Task'}}})
    elif name == 'agent_system':
        emit({'type': 'system', 'subtype': 'task_started', 'session_id': 'native-source',
              'task_id': 'foreground-task', 'tool_use_id': 'foreground-agent'})
    elif name == 'agent_finished':
        emit({'type': 'user', 'session_id': 'native-source', 'parent_tool_use_id': None,
              'message': {'role': 'user', 'content': [{
                  'type': 'tool_result', 'tool_use_id': 'foreground-agent', 'content': 'Agent completed'}]}})
        emit({'type': 'system', 'subtype': 'task_notification', 'session_id': 'native-source',
              'task_id': 'foreground-task', 'status': 'completed'})
    elif name == 'agent_system_finished':
        emit({'type': 'system', 'subtype': 'task_notification', 'session_id': 'native-source',
              'task_id': 'foreground-task', 'status': 'completed'})
    elif name == 'token_delta':
        emit({'type': 'stream_event', 'session_id': 'native-source', 'parent_tool_use_id': None,
              'event': {'type': 'content_block_delta', 'index': 0, 'delta': {
                  'type': 'text_delta', 'text': 'Capability-neutral token'}}})


while True:
    config = options()
    current_signal = config.get('signal')
    if current_signal != last_signal:
        last_signal = current_signal
        signal(current_signal.get('name') if isinstance(current_signal, dict) else current_signal)
    for item in list(pending):
        if os.path.exists(item['release']):
            response(item['id'], item['result'])
            pending.remove(item)
    if not input_lines:
        if not select.select([sys.stdin], [], [], .005)[0]:
            continue
        chunk = os.read(sys.stdin.fileno(), 65536)
        if not chunk:
            break
        input_bytes.extend(chunk)
        while b'\n' in input_bytes:
            line, _, remainder = input_bytes.partition(b'\n')
            input_lines.append(line)
            input_bytes = bytearray(remainder)
        if not input_lines:
            continue
    line = input_lines.pop(0)
    frame = json.loads(line)
    with open(wire_path, 'a', encoding='utf-8') as log:
        log.write(json.dumps(frame) + '\n')
    config = options()
    if dialect == 'codex':
        method, identifier, params = frame.get('method'), frame.get('id'), frame.get('params') or {}
        if identifier is None:
            continue
        if method == 'initialize':
            response(identifier, {'userAgent': config.get('userAgent', 'coincide/0.163.0 (macos; arm64)')})
        elif method == 'model/list':
            response(identifier, {'data': []})
        elif method in ('thread/start', 'thread/resume'):
            response(identifier, {'thread': {'id': 'native-source', 'historyMode': 'paginated'}})
        elif method == 'turn/start':
            turn += 1
            response(identifier, {'turn': {'id': native_turn()}})
            emit({'method': 'turn/started', 'params': {'threadId': 'native-source', 'turn': {'id': native_turn()}}})
        elif method == 'turn/steer':
            mode = config.get('mode', 'success')
            if mode in ('rejected', 'unsupported', 'internal'):
                response_code = {'rejected': -32602, 'unsupported': -32601, 'internal': -32603}[mode]
                emit({'id': identifier, 'error': {'code': response_code,
                    'message': 'Private peer value must never be exposed: synthetic-private-token'}})
            elif mode == 'disconnect':
                sys.exit(0)
            else:
                result = {'turnId': 'different-native-turn' if mode == 'wrongAck' else params['expectedTurnId']}
                if config.get('ackRelease'):
                    pending.append({'id': identifier, 'result': result, 'release': config['ackRelease']})
                else:
                    response(identifier, result)
        elif method == 'turn/interrupt':
            response(identifier, {})
            finish(interrupted=True)
        else:
            emit({'id': identifier, 'error': {'code': -32601, 'message': 'Unsupported offline method'}})
    elif frame['type'] == 'control_request':
        method = frame['request']['subtype']
        if method == 'interrupt' and steering_segments_pending:
            # Reproduce the transport-write/reader race deterministically: the
            # client has already requested Stop before these earlier segments
            # are delivered. They still belong to the one interrupted query.
            finish(reason='aborted_tools')
            finish(reason='aborted_streaming')
            steering_segments_pending = False
        control(frame['request_id'], {'models': []} if method == 'initialize' else {})
        if method == 'interrupt':
            finish(interrupted=True)
            if config.get('holdSteeringSegmentsUntilInterrupt'):
                emit({'type': 'assistant', 'session_id': 'native-source', 'parent_tool_use_id': None,
                      'message': {'id': 'stop-drain-boundary', 'content': [
                          {'type': 'text', 'text': 'Offline Stop drain boundary'}]}})
    elif frame['type'] == 'user':
        if frame.get('priority') == 'now':
            if config.get('mode') == 'echo':
                echo = dict(frame)
                echo['session_id'] = 'native-source'
                emit(echo)
            if config.get('holdSteeringSegmentsUntilInterrupt'):
                steering_segments_pending = True
            else:
                finish(reason='aborted_tools')
                finish(reason='aborted_streaming')
                emit({'type': 'assistant', 'session_id': 'native-source', 'parent_tool_use_id': None,
                      'message': {'id': 'steered-reply', 'content': [
                          {'type': 'text', 'text': 'After steering 日本語'}]}})
        else:
            turn += 1
            emit({'type': 'system', 'subtype': 'init', 'session_id': 'native-source'})
