# Unavailable saved hosted sessions

A saved generation can be unavailable after a crash: its transcript/index may contain an initial marker without the
matching client journal, or its valid saved journal may refer to a generation absent from the current host. Missing
state does not establish whether earlier work ran, completed, or remains active elsewhere.

These conversations remain readable and their draft stays editable. Send, queue, steering, model refresh and provider
changes are unavailable while their saved routing cannot be matched. The runtime entry path applies the same restriction,
including keyboard and scheduled actions. It does not retry old input, start a replacement provider, clear a marker,
advance an acknowledgment, or retire an unavailable generation.

The status explains the uncertainty and points to the existing **New Chat** command. That explicit action creates a
separate empty conversation. It preserves the original conversation's history, draft, attachments, queue, provider
sessions and routing records, and copies none of those into the new conversation. Returning to the original conversation
still shows its retained data and unavailable-session guidance.

This is a safe continuation route, **not recovery or proof of non-delivery for the original input**. Definite saved-input
recovery remains a separate explicit action with its own durable-preservation checks. Uncertain generations remain
retained for review. Corrupt or unreadable shared routing metadata can also block new hosted conversations until the
metadata problem is addressed; creating an empty conversation does not repair it.

Portable policy tests cover initial markers, absent/mismatched cursors and journals, unavailable runtime status,
normal retired generations and metadata errors. Exact-head native build and owned physical UI preservation acceptance
are separate requirements; adding this documentation does not claim they have passed.
