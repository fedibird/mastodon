"""Named policies and backends available to the API.

``identity`` stays available when TranslateGemma is not configured.
Constructing the TranslateGemma backend does not contact the network and
does not require ``TRANSLATEGEMMA_ENDPOINT``.
"""

from semantic_translation.backends.base import TranslationBackend
from semantic_translation.backends.identity import IdentityBackend
from semantic_translation.backends.translategemma import TranslateGemmaBackend
from semantic_translation.core.errors import UnknownBackend, UnknownPolicy
from semantic_translation.policies.base import TranslationPolicy
from semantic_translation.policies.mastodon_v1 import MastodonV1Policy


def get_policy(name: str) -> TranslationPolicy:
    if name == MastodonV1Policy.id:
        return MastodonV1Policy()
    raise UnknownPolicy()


def get_backend(name: str) -> TranslationBackend:
    if name == IdentityBackend.id:
        return IdentityBackend()
    if name == TranslateGemmaBackend.id:
        return TranslateGemmaBackend()
    raise UnknownBackend()
