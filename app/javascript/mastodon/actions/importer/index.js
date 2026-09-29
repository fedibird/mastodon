import { normalizeAccount, normalizeStatus, normalizePoll, normalizeCustomEmojiDetail, translationSourceSignature } from './normalizer';

export const ACCOUNT_IMPORT  = 'ACCOUNT_IMPORT';
export const ACCOUNTS_IMPORT = 'ACCOUNTS_IMPORT';
export const STATUS_IMPORT   = 'STATUS_IMPORT';
export const STATUSES_IMPORT = 'STATUSES_IMPORT';
export const POLLS_IMPORT    = 'POLLS_IMPORT';
export const FILTERS_IMPORT  = 'FILTERS_IMPORT';
export const CUSTOM_EMOJI_DETAIL_IMPORT  = 'CUSTOM_EMOJI_DETAIL_IMPORT';
export const CUSTOM_EMOJIS_DETAIL_IMPORT = 'CUSTOM_EMOJIS_DETAIL_IMPORT';

function pushUnique(array, object) {
  if (array.every(element => element.id !== object.id)) {
    array.push(object);
  }
}

const stripTranslationState = (status) => {
  delete status.translation;
  delete status.translationMode;
  delete status.translationPending;
  delete status.translationRequestId;
  delete status.translationContentSignature;
  delete status.translationStatusSignature;
  return status;
};

const wrapperHasTranslationState = (status) => !!(
  status.get('translation') ||
  status.get('translationPending') ||
  status.get('translationContentSignature') ||
  status.get('translationStatusSignature')
);

const pollForSignature = (payloadPoll, previousPoll) => {
  if (payloadPoll && typeof payloadPoll === 'object' && payloadPoll.options) {
    return payloadPoll;
  }

  return previousPoll || null;
};

export function importAccount(account) {
  return { type: ACCOUNT_IMPORT, account };
}

export function importAccounts(accounts) {
  return { type: ACCOUNTS_IMPORT, accounts };
}

export function importStatus(status) {
  return { type: STATUS_IMPORT, status };
}

export function importStatuses(statuses) {
  return { type: STATUSES_IMPORT, statuses };
}

export function importPolls(polls) {
  return { type: POLLS_IMPORT, polls };
}

export function importFilters(filters) {
  return { type: FILTERS_IMPORT, filters };
}

export function importCustomEmojiDetail(custom_emoji) {
  return {
    type: CUSTOM_EMOJI_DETAIL_IMPORT,
    customEmojiDetail: custom_emoji,
  };
}

export function importCustomEmojisDetail(custom_emojis) {
  return {
    type: CUSTOM_EMOJIS_DETAIL_IMPORT,
    customEmojisDetail: custom_emojis,
  };
}

export function importFetchedAccount(account) {
  return importFetchedAccounts([account]);
}

export function importFetchedAccounts(accounts) {
  const normalAccounts = [];

  function processAccount(account) {
    pushUnique(normalAccounts, normalizeAccount(account));

    if (account.moved) {
      processAccount(account.moved);
    }
  }

  accounts.forEach(processAccount);

  return importAccounts(normalAccounts);
}

export function importFetchedStatus(status) {
  return importFetchedStatuses([status]);
}

export function importFetchedStatuses(statuses) {
  return (dispatch, getState) => {
    const accounts = [];
    const normalStatuses = [];
    const polls = [];
    const filters = [];

    function processStatus(status) {
      status = { ...status };

      // Rolling-deploy adapter for pre-#75 streaming Node, which attached
      // FilterResult as `filter_results`. Current Rails REST and current Node
      // streaming both emit canonical `filtered` only. Keep this copy so a
      // new WebUI against an old streaming process still hydrates hide/warn;
      // always drop the legacy key so it never lands in Redux.
      if (!status.filtered && status.filter_results) {
        status.filtered = status.filter_results;
      }

      delete status.filter_results;

      if (status.poll && status.poll.id) {
        pushUnique(polls, normalizePoll(status.poll, getState().getIn(['polls', status.poll.id])));
      }

      if (typeof status.account === 'object') {
        pushUnique(accounts, status.account);
      }

      if (status.filtered) {
        status.filtered.forEach(result => {
          if (result.filter && typeof result.filter === 'object') {
            pushUnique(filters, { ...result.filter, id: String(result.filter.id) });
          }
        });
      }

      // Fedibird statuses can carry both `reblog` and `quote`. Process each
      // independently so a quote on a boost wrapper is still imported.
      if (status.reblog && status.reblog.id) {
        processStatus(status.reblog);
      }

      if (status.quote && status.quote.id) {
        processStatus(status.quote);
      }

      const state = getState();
      const previousStatus = state.getIn(['statuses', status.id]);
      const previousPoll = status.poll && status.poll.id ? state.getIn(['polls', status.poll.id]) : null;
      const domain = (typeof status.account === 'object' ? status.account.acct : state.getIn(['accounts', status.account, 'acct']))?.split('@')[1] ?? '';
      const normalizedStatus = normalizeStatus(status, previousStatus, domain, previousPoll);

      // A status-level source change invalidates the in-flight translation,
      // including poll options whose titles did not change.
      if (status.poll && status.poll.id && !normalizedStatus.translationRequestId) {
        const importedPoll = polls.find(item => item.id === status.poll.id);

        if (importedPoll) {
          delete importedPoll.translationRequestId;
        }
      }

      // A personal boost keeps its translation on the wrapper, while the
      // editable source is this proper status. Drop that wrapper state when
      // the source changes. Counter-only refreshes keep the same signature.
      if (previousStatus) {
        const previousSignature = translationSourceSignature(previousStatus, previousPoll);
        const nextSignature = translationSourceSignature(normalizedStatus, pollForSignature(status.poll, previousPoll));

        if (previousSignature !== nextSignature) {
          state.get('statuses').forEach(stored => {
            if (!stored || !wrapperHasTranslationState(stored) || String(stored.get('reblog')) !== String(status.id)) {
              return;
            }

            const cleared = stripTranslationState(stored.toJS());
            cleared._translationInvalidated = true;
            const index = normalStatuses.findIndex(item => item.id === cleared.id);

            if (index === -1) {
              normalStatuses.push(cleared);
            } else {
              normalStatuses[index] = stripTranslationState(normalStatuses[index]);
              normalStatuses[index]._translationInvalidated = true;
            }
          });
        }
      }

      const invalidatedIndex = normalStatuses.findIndex(item => item.id === normalizedStatus.id && item._translationInvalidated);

      if (invalidatedIndex === -1) {
        pushUnique(normalStatuses, normalizedStatus);
      } else {
        normalStatuses[invalidatedIndex] = stripTranslationState(normalizedStatus);
      }
    }

    statuses.forEach(processStatus);
    normalStatuses.forEach(item => {
      delete item._translationInvalidated;
    });

    dispatch(importPolls(polls));
    dispatch(importFetchedAccounts(accounts));
    // Import Filter entities before statuses so hide/warn selectors see
    // filter_action on the same tick the status lands in Redux.
    dispatch(importFilters(filters));
    dispatch(importStatuses(normalStatuses));
  };
}

export function importFetchedPoll(poll) {
  return (dispatch, getState) => {
    dispatch(importPolls([normalizePoll(poll, getState().getIn(['polls', poll.id]))]));
  };
}

export function importFetchedCustomEmojiDetail(custom_emoji) {
  return importFetchedCustomEmojisDetail([custom_emoji]);
}

export function importFetchedCustomEmojisDetail(custom_emojis) {
  const normalizeCustomEmojisDetail = [];

  return (dispatch, _getState) => {
    function processCustomEmojiDetail(custom_emoji) {
      pushUnique(normalizeCustomEmojisDetail, normalizeCustomEmojiDetail(custom_emoji));
    }

    custom_emojis.forEach(processCustomEmojiDetail);

    dispatch(importCustomEmojisDetail(normalizeCustomEmojisDetail));
  };
}
