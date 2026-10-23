"""Offline Claude SDK block snapshots, including the real thinking/text index shift."""
import json
import sys

turn = 0

def emit(value):
    print(json.dumps(value), flush=True)

def stream(event, parent=None):
    emit({'type': 'stream_event', 'session_id': 'blocks-session',
          'parent_tool_use_id': parent, 'event': event})

def start(ident, parent=None):
    stream({'type': 'message_start', 'message': {'id': ident}}, parent)

def block(index, value, parent=None):
    stream({'type': 'content_block_start', 'index': index, 'content_block': value}, parent)

def delta(index, kind, text, parent=None):
    stream({'type': 'content_block_delta', 'index': index,
            'delta': {'type': kind + '_delta', kind: text}}, parent)

def final(ident, content, uuid=None, parent=None):
    frame = {'type': 'assistant', 'session_id': 'blocks-session', 'parent_tool_use_id': parent,
             'message': {'id': ident, 'content': content, 'stop_reason': None}}
    if uuid is not None:
        frame['uuid'] = uuid
    emit(frame)

for line in sys.stdin:
    frame = json.loads(line)
    if frame['type'] == 'control_request':
        request = frame['request']
        assert request['subtype'] in ('initialize', 'set_permission_mode', 'set_model')
        emit({'type': 'control_response', 'response': {'subtype': 'success',
              'request_id': frame['request_id'], 'response': {}}})
    elif frame['type'] == 'user':
        turn += 1
        ident = 'api-message-' + str(turn)
        start(ident)
        block(0, {'type': 'thinking', 'thinking': 'reason'})
        delta(0, 'thinking', 'ing')
        # Both children deliberately share the API ID/index with the root.
        # Their starts must not change the root's current stream ownership.
        for parent in ('child-a', 'child-b'):
            start(ident, parent)
            block(0, {'type': 'text', 'text': ''}, parent)
        delta(0, 'text', 'Child A', 'child-a')
        delta(0, 'text', 'Child B', 'child-b')
        block(1, {'type': 'text', 'text': ''})
        delta(1, 'text', 'answer ')
        delta(1, 'text', 'body')
        final(ident, [{'type': 'thinking', 'thinking': 'reasoning'}], 'thinking-' + str(turn))
        # Native stream index 1; completed SDK envelope's local index is 0.
        answer = [{'type': 'text', 'text': 'answer body'}]
        final(ident, answer, 'answer-' + str(turn))
        final(ident, answer, 'answer-' + str(turn))  # Same wire envelope replay.
        delta(1, 'text', 'must not append after final')
        for parent, text in (('child-a', 'Child A'), ('child-b', 'Child B')):
            final(ident, [{'type': 'text', 'text': text}], parent + '-' + str(turn), parent)
            stream({'type': 'message_stop'}, parent)
        tool = {'type': 'tool_use', 'id': 'native-tool-' + str(turn), 'name': 'Read', 'input': {'file_path': 'fixture.txt'}}
        block(2, tool)
        final(ident, [tool], 'tool-' + str(turn))
        # Identical legitimate blocks, including a missing snapshot UUID.
        for index in (3, 4):
            block(index, {'type': 'text', 'text': ''})
            delta(index, 'text', 'same')
            final(ident, [{'type': 'text', 'text': 'same'}], None if index == 4 else 'same-' + str(turn))
        # Older producers may additionally send an aggregate final snapshot.
        final(ident, [{'type': 'thinking', 'thinking': 'reasoning'}, *answer, tool,
                      {'type': 'text', 'text': 'same'}, {'type': 'text', 'text': 'same'}], 'aggregate-' + str(turn))
        stream({'type': 'message_stop'})
        emit({'type': 'result', 'session_id': 'blocks-session', 'parent_tool_use_id': None,
              'is_error': False, 'result': 'answer body'})
    else:
        raise AssertionError('Unexpected input envelope')
