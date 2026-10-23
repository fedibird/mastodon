import { targetsOverlap } from './reconcile';

// One browser session. A closed or replaced view keeps its token so a late
// response can see that it no longer matches. Status epochs move when a
// stream frame changes that id, independent of feed_routes_revision.
export const createExternalFeedSession = () => {
  let tokenSeq = 0;
  let capabilityEpoch = 0;
  let streamClock = 0;
  let disposed = false;
  const views = new Map();
  const statusEpochs = new Map();
  const statusClocks = new Map();

  const current = (key) => {
    const view = views.get(key);

    if (!view || view.closed) {
      return null;
    }

    return view;
  };

  return {
    open (key, meta = {}) {
      tokenSeq += 1;
      const view = {
        key,
        token: tokenSeq,
        epoch: 0,
        membershipEpoch: 0,
        passEpoch: 0,
        closed: false,
        targets: meta.targets || [],
        running: false,
        rerun: false,
        progress: null,
      };

      views.set(key, view);
      return view.token;
    },

    close (key, token) {
      const view = views.get(key);

      if (!view || view.token !== token) {
        return false;
      }

      view.closed = true;
      view.epoch += 1;
      view.membershipEpoch += 1;
      return true;
    },

    invalidate (key) {
      const view = current(key);

      if (!view) {
        return;
      }

      view.epoch += 1;
      view.membershipEpoch += 1;
    },

    // A reconnect or a tab return starts a new pass. Budget retries of the
    // pass that is already running keep the checked ids.
    beginPass (key) {
      const view = current(key);

      if (!view) {
        return false;
      }

      view.passEpoch += 1;
      return true;
    },

    noteControl (parsed) {
      views.forEach(view => {
        if (view.closed || !targetsOverlap(view.targets, parsed.targets)) {
          return;
        }

        view.membershipEpoch += 1;
      });
    },

    noteStatus (id) {
      const key = String(id);
      const next = (statusEpochs.get(key) || 0) + 1;

      statusEpochs.set(key, next);
      streamClock += 1;
      statusClocks.set(key, streamClock);
      return next;
    },

    // Clock at the moment a request is built. An epoch that already existed
    // is not a conflict; only a clock that moves after this marker is.
    streamMarker () {
      return streamClock;
    },

    statusMovedSince (id, marker) {
      return (statusClocks.get(String(id)) || 0) > (marker || 0);
    },

    statusEpoch (id) {
      return statusEpochs.get(String(id)) || 0;
    },

    statusEpochsFor (ids) {
      const snapshot = {};

      (ids || []).forEach(id => {
        snapshot[String(id)] = statusEpochs.get(String(id)) || 0;
      });

      return snapshot;
    },

    snapshot (key, token, extra = {}) {
      const view = views.get(key);

      if (disposed || !view || view.closed || view.token !== token) {
        return null;
      }

      return {
        key,
        token: view.token,
        epoch: view.epoch,
        membershipEpoch: view.membershipEpoch,
        passEpoch: view.passEpoch,
        capabilityEpoch,
        permitted: extra.permitted === true,
        visibilitiesKey: extra.visibilitiesKey || '',
        sessionId: extra.sessionId,
        definitionFingerprint: extra.definitionFingerprint,
        statusEpochs: extra.statusEpochs || {},
        streamClock,
      };
    },

    // Checked ids and history cursors belong to one view token and one
    // membership/capability generation. A control event starts a new plan.
    progress (key, token) {
      const view = views.get(key);

      if (disposed || !view || view.closed || view.token !== token) {
        return null;
      }

      const stamp = `${view.token}:${view.membershipEpoch}:${capabilityEpoch}:${view.passEpoch}`;

      if (!view.progress || view.progress.stamp !== stamp) {
        view.progress = {
          stamp,
          membershipChecked: new Set(),
          bodyChecked: new Set(),
          history: {},
        };
      }

      return view.progress;
    },

    accept (snapshot) {
      if (!snapshot || disposed) {
        return { ok: false, reason: 'disposed' };
      }

      if (snapshot.capabilityEpoch !== capabilityEpoch) {
        return { ok: false, reason: 'capability' };
      }

      const view = views.get(snapshot.key);

      if (!view || view.closed || view.token !== snapshot.token || view.epoch !== snapshot.epoch) {
        return { ok: false, reason: 'view' };
      }

      if (view.membershipEpoch !== snapshot.membershipEpoch) {
        return { ok: false, reason: 'membership' };
      }

      if (view.passEpoch !== snapshot.passEpoch) {
        return { ok: false, reason: 'pass' };
      }

      const staleIds = Object.keys(snapshot.statusEpochs || {}).filter(id => (statusEpochs.get(id) || 0) !== snapshot.statusEpochs[id]);

      return { ok: true, staleIds };
    },

    openViews () {
      return Array.from(views.values()).filter(view => !view.closed).map(view => ({
        key: view.key,
        token: view.token,
        targets: view.targets.slice(),
      }));
    },

    matchingViews (targets) {
      return this.openViews().filter(view => targetsOverlap(view.targets, targets));
    },

    claim (key, token) {
      const view = views.get(key);

      if (disposed || !view || view.closed || view.token !== token) {
        return false;
      }

      if (view.running) {
        view.rerun = true;
        return false;
      }

      view.running = true;
      view.rerun = false;
      return true;
    },

    finish (key, token) {
      const view = views.get(key);

      if (!view || view.token !== token) {
        return false;
      }

      view.running = false;
      const again = view.rerun && !view.closed && !disposed;

      view.rerun = false;
      return again;
    },

    dispose () {
      disposed = true;
      capabilityEpoch += 1;
      views.forEach(view => {
        view.closed = true;
        view.epoch += 1;
        view.membershipEpoch += 1;
      });
    },

    capabilityMarker () {
      return capabilityEpoch;
    },

    capabilityCurrent (marker) {
      return !disposed && marker === capabilityEpoch;
    },

    bumpCapability () {
      capabilityEpoch += 1;
    },

    // Jest reuses this module. Logout keeps dispose() sticky; tests call this
    // so a later example is not rejected as signed out.
    resetForTests () {
      disposed = false;
      capabilityEpoch += 1;
      views.clear();
      statusEpochs.clear();
      statusClocks.clear();
      streamClock = 0;
    },
  };
};

export const externalFeedSession = createExternalFeedSession();
