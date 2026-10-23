#!/usr/bin/python3
"""Private Claude SDK-wire peer: no provider, account, or network access."""
import json
import os
import sys
import time
import uuid

root = os.path.dirname(os.path.realpath(__file__))
session = str(uuid.uuid4())
turn = 0
argv = sys.argv[1:]
settings = json.loads(argv[argv.index('--settings') + 1]) if '--settings' in argv else {}

def emit(value):
    print(json.dumps(value), flush=True)

def response(frame, value):
    emit({'type': 'control_response', 'response': {'subtype': 'success', 'request_id': frame['request_id'], 'response': value}})

def root_frame(kind, **fields):
    return dict(type=kind, session_id=session, parent_tool_use_id=None, **fields)

for line in sys.stdin:
    frame = json.loads(line)
    with open(os.path.join(root, 'wire.jsonl'), 'a', encoding='utf-8') as output:
        output.write(json.dumps(frame) + '\n')
    if frame['type'] == 'control_request':
        method = frame['request']['subtype']
        if method == 'initialize':
            emit(root_frame('system', subtype='init', claude_code_version='2.1.308'))
            response(frame, {'commands': [], 'models': [], 'fast_mode_state': 'off'})
        elif method == 'get_settings':
            response(frame, {'effective': settings, 'sources': []})
        elif method in ('set_model', 'set_permission_mode', 'interrupt'):
            response(frame, {})
        else:
            raise AssertionError('Unexpected control request')
        continue
    assert frame['type'] == 'user'
    turn += 1
    emit(root_frame('user', uuid=frame['uuid'], message=frame['message']))
    # SDK system/status and rate-limit events omit parent_tool_use_id.
    emit({'type': 'system', 'subtype': 'status', 'status': 'requesting', 'session_id': session})
    message_id = 'request-' + str(turn)
    usage = {'input_tokens': 100, 'cache_read_input_tokens': 20, 'cache_creation_input_tokens': 30,
             'output_tokens': 0, 'cache_creation': {'ephemeral_5m_input_tokens': 30, 'ephemeral_1h_input_tokens': 0}}
    emit(root_frame('stream_event', user_message_uuid=frame['uuid'], event={
        'type': 'message_start', 'message': {'id': message_id, 'model': 'offline-model', 'usage': usage}}))
    emit(root_frame('stream_event', event={'type': 'message_delta', 'usage': {
        'input_tokens': None, 'cache_read_input_tokens': None, 'output_tokens': 5}}))
    for ignored in ('child', 'foreign', 'replay'):
        other = root_frame('assistant', uuid=str(uuid.uuid4()), user_message_uuid=frame['uuid'], message={
            'id': 'ignored-' + ignored + '-' + str(turn), 'model': 'offline-model',
            'content': [{'type': 'text', 'text': 'Offline telemetry frame'}],
            'usage': {'input_tokens': 900000, 'output_tokens': 900000}})
        if ignored == 'child':
            other['parent_tool_use_id'] = 'owned-child-task'
        elif ignored == 'foreign':
            other['session_id'] = str(uuid.uuid4())
        else:
            other['replayed'] = True
        emit(other)
    for _ in range(2):
        emit(root_frame('assistant', uuid=str(uuid.uuid4()), message={
            'id': message_id, 'model': 'offline-model', 'content': [{'type': 'text', 'text': 'Offline usage complete'}],
            'usage': {'input_tokens': 100, 'cache_read_input_tokens': 20, 'cache_creation_input_tokens': 30, 'output_tokens': 99}}))
    cost = 0.12 if turn == 1 else 0.19
    emit(root_frame('result', uuid=str(uuid.uuid4()), subtype='success', is_error=False, user_message_uuid=frame['uuid'],
        usage={'input_tokens': 150 if turn == 1 else 10, 'cache_read_input_tokens': 40 if turn == 1 else 20,
               'cache_creation_input_tokens': 30, 'output_tokens': 20 if turn == 1 else 7,
               'output_tokens_details': {'thinking_tokens': 7 if turn == 1 else 1}},
        total_cost_usd=cost, modelUsage={'offline-model': {
            'inputTokens': 400 if turn == 1 else 600, 'outputTokens': 75, 'cacheReadInputTokens': 120,
            'cacheCreationInputTokens': 80, 'thinkingTokens': 9, 'webSearchRequests': 2, 'costUSD': cost,
            'contextWindow': 200000, 'maxOutputTokens': 8000, 'privateCredential': 'PRIVATE-MUST-NOT-PERSIST'}},
        result='Offline usage complete'))
    if turn == 1:
        emit({'type': 'rate_limit_event', 'session_id': session, 'uuid': str(uuid.uuid4()),
              'rate_limit_info': {'status': 'rejected', 'rateLimitType': 'five_hour', 'utilization': 1,
                                  'resetsAt': time.time() + 600, 'overageStatus': 'allowed',
                                  'privateCredential': 'PRIVATE-MUST-NOT-PERSIST'}})
