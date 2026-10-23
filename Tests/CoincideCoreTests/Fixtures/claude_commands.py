"""Native Claude command discovery without filesystem expansion or model calls."""
import json
import os
import sys

scenario, root = sys.argv[1:3]

def emit(value):
    print(json.dumps(value), flush=True)

def command(name, aliases=None):
    value = {'name': name, 'description': 'Native advertised description', 'argumentHint': '<focus>'}
    if aliases is not None:
        value['aliases'] = aliases
    return value

def changed(commands, parent=None, session='catalog-session'):
    emit({'type': 'system', 'subtype': 'commands_changed', 'parent_tool_use_id': parent,
          'session_id': session, 'commands': commands})

for line in sys.stdin:
    frame = json.loads(line)
    with open(os.path.join(root, 'wire.jsonl'), 'a', encoding='utf-8') as wire:
        wire.write(json.dumps(frame, ensure_ascii=False) + '\n')
    if frame['type'] == 'control_request':
        subtype = frame['request']['subtype']
        assert subtype in ('initialize', 'set_permission_mode', 'set_model'), 'No speculative reload or other control operation'
        result = {}
        if subtype == 'initialize' and scenario != 'unsupported':
            result = {'commands': [command('demo:review', ['dr'])], 'models': [], 'reload_skills': False}
        if subtype == 'initialize':
            emit({'type': 'system', 'subtype': 'init', 'parent_tool_use_id': None, 'session_id': 'catalog-session'})
            if scenario == 'changed':
                changed([command('replacement')])
            elif scenario == 'empty':
                changed([])
            elif scenario == 'malformed':
                changed({'not': 'an array'})
            elif scenario == 'foreign':
                changed([command('child-command')], parent='child-tool')
                changed([command('foreign-command')], session='different-root')
        emit({'type': 'control_response', 'response': {'subtype': 'success',
              'request_id': frame['request_id'], 'response': result}})
    elif frame['type'] == 'user':
        assert scenario == 'literal'
        assert frame['message']['content'] == '/demo:review  literal 工作\n/other remains arguments\n$HOME untouched '
        emit({'type': 'assistant', 'parent_tool_use_id': None, 'session_id': 'catalog-session', 'uuid': 'native-final',
              'message': {'id': 'api-native-command', 'content': [{'type': 'text', 'text': 'Command completed'}]}})
        emit({'type': 'result', 'parent_tool_use_id': None, 'session_id': 'catalog-session', 'is_error': False,
              'result': 'Command completed'})
    else:
        raise AssertionError('Unexpected native command frame')
