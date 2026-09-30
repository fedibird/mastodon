"""Translation backends.

``IdentityBackend`` returns text unchanged. ``TranslateGemmaBackend`` sends
each unit to a local vLLM server over HTTP. Neither backend sees HTML.
"""
