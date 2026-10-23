#!/usr/bin/python3
"""Private, no-provider stream-json model-controls peer."""
import json
import os
import sys
import time
import uuid

root = os.path.dirname(os.path.realpath(__file__))
scenario = open(os.path.join(root, 'scenario'), encoding='utf-8').read()
native = str(uuid.uuid4())
turn = 0
with open(os.path.join(root, 'argv.json'), 'w', encoding='utf-8') as target:
    json.dump(sys.argv[1:], target)

def emit(value):
    print(json.dumps(value, ensure_ascii=False), flush=True)

def response(frame, value):
    emit({'type': 'control_response', 'response': {'subtype': 'success', 'request_id': frame['request_id'], 'response': value}})

models = [
    {'value': 'opus', 'resolvedModel': 'claude-opus-4-6', 'displayName': 'Native Opus',
     'description': 'Native model description', 'supportsEffort': True,
     'supportedEffortLevels': ['low', 'medium', 'high', 'max'], 'supportsAdaptiveThinking': True, 'supportsFastMode': True},
    {'value': 'sonnet', 'resolvedModel': 'claude-sonnet-4-6', 'displayName': 'Native Sonnet',
     'supportsEffort': True, 'supportedEffortLevels': ['low', 'medium', 'high'], 'supportsFastMode': False},
    {'value': 'haiku', 'resolvedModel': 'claude-haiku-4-5', 'displayName': 'Native Haiku', 'supportsEffort': False,
     'supportsAdaptiveThinking': False, 'supportsFastMode': False},
    {'value': 'private-pool-model', 'displayName': 'Private pool', 'supportsEffort': True,
     'supportedEffortLevels': ['low', 'high', 'xhigh', 'max'], 'supportsFastMode': False}
]
if scenario == 'missing-capabilities':
    models = [{'value': 'opus', 'displayName': 'Old catalog'}]
if scenario == 'old-version':
    models = [{'value': 'claude-opus-4-7', 'displayName': 'Too new', 'supportsEffort': True, 'supportedEffortLevels': ['high', 'max']}]

for line in sys.stdin:
    frame = json.loads(line)
    with open(os.path.join(root, 'wire.jsonl'), 'a', encoding='utf-8') as target:
        target.write(json.dumps(frame, ensure_ascii=False) + '\n')
    if frame['type'] == 'control_request':
        method = frame['request']['subtype']
        assert method in ('initialize', 'set_model', 'set_permission_mode', 'apply_flag_settings', 'interrupt')
        if method == 'initialize':
            emit({'type': 'system', 'subtype': 'init', 'session_id': native, 'parent_tool_use_id': None,
                  'claude_code_version': '2.1.100' if scenario == 'old-version' else '2.1.308'})
            response(frame, {'commands': [], 'models': models, 'fast_mode_state': 'off'})
        elif method == 'apply_flag_settings' and scenario in ('reject-flags', 'drop-flags', 'held-flags'):
            if scenario == 'drop-flags':
                sys.exit(0)
            if scenario == 'reject-flags':
                emit({'type': 'control_response', 'response': {'subtype': 'error', 'request_id': frame['request_id'],
                      'error': 'PRIVATE-NATIVE-ERROR-MUST-NOT-LEAK'}})
            else:
                open(os.path.join(root, 'flags-entered'), 'w').close()
                while not os.path.exists(os.path.join(root, 'release-flags')):
                    time.sleep(0.005)
                response(frame, {})
        else:
            response(frame, {})
    elif frame['type'] == 'user':
        turn += 1
        emit({'type': 'user', 'uuid': frame['uuid'], 'session_id': native, 'parent_tool_use_id': None, 'message': frame['message']})
        emit({'type': 'assistant', 'uuid': str(uuid.uuid4()), 'session_id': native, 'parent_tool_use_id': None,
              'message': {'id': 'message-' + str(turn), 'content': [{'type': 'text', 'text': 'Offline controls completed'}]}})
        if scenario == 'steering' and turn == 1:
            continue
        emit({'type': 'result', 'session_id': native, 'parent_tool_use_id': None, 'is_error': False,
              'user_message_uuid': frame['uuid'], 'result': 'Offline controls completed', 'fast_mode_state': 'cooldown',
              'fast_mode_disabled_reason': 'network_error'})
    else:
        raise AssertionError('Unexpected frame')
