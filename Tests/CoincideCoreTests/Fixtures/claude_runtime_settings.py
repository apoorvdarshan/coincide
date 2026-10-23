#!/usr/bin/python3
"""Owned offline stream-json peer; never launches a provider or reads accounts."""
import json
import os
import sys
import time
import uuid

root = os.path.dirname(os.path.realpath(__file__))
scenario = open(os.path.join(root, 'scenario'), encoding='utf-8').read()
native = str(uuid.uuid4())
argv = sys.argv[1:]
with open(os.path.join(root, 'launch.json'), 'w', encoding='utf-8') as output:
    json.dump({'argv': argv, 'directory': os.environ.get('CLAUDE_CONFIG_DIR'),
               'project': os.environ.get('CLAUDE_CODE_PROJECT_DIR_NAME')}, output)
inline = json.loads(argv[argv.index('--settings') + 1]) if '--settings' in argv else {}

def emit(value):
    print(json.dumps(value), flush=True)

def response(frame, value):
    emit({'type': 'control_response', 'response': {'subtype': 'success',
          'request_id': frame['request_id'], 'response': value}})

for line in sys.stdin:
    frame = json.loads(line)
    with open(os.path.join(root, 'wire.jsonl'), 'a', encoding='utf-8') as output:
        output.write(json.dumps(frame) + '\n')
    if frame['type'] == 'control_request':
        method = frame['request']['subtype']
        if method == 'initialize':
            emit({'type': 'system', 'subtype': 'init', 'session_id': native,
                  'parent_tool_use_id': None, 'claude_code_version': '2.1.308'})
            response(frame, {'models': [], 'commands': []})
        elif method == 'get_settings':
            if scenario == 'held':
                open(os.path.join(root, 'settings-entered'), 'w').close()
                while not os.path.exists(os.path.join(root, 'release-settings')):
                    time.sleep(0.005)
            if scenario == 'error':
                emit({'type': 'control_response', 'response': {'subtype': 'error',
                      'request_id': frame['request_id'], 'error': 'PRIVATE-NATIVE-SETTINGS'}})
            elif scenario == 'drop':
                sys.exit(0)
            else:
                effective = dict(inline)
                if scenario == 'mismatch':
                    effective['autoCompactWindow'] = 999999
                if scenario == 'missing':
                    effective = {}
                if scenario == 'string':
                    effective['autoCompactWindow'] = str(effective['autoCompactWindow'])
                response(frame, {'effective': effective, 'sources': [
                    {'source': 'commandLineSettings', 'settings': {'private': 'PRIVATE-NATIVE-SETTINGS'}}]})
        elif method in ('set_model', 'set_permission_mode', 'interrupt'):
            response(frame, {})
        else:
            raise AssertionError('Unexpected control method')
    elif frame['type'] == 'user':
        emit({'type': 'user', 'uuid': frame['uuid'], 'session_id': native,
              'parent_tool_use_id': None, 'message': frame['message']})
        emit({'type': 'result', 'session_id': native, 'parent_tool_use_id': None,
              'is_error': False, 'user_message_uuid': frame['uuid'], 'result': 'Offline input accepted'})
    else:
        raise AssertionError('Unexpected frame')
