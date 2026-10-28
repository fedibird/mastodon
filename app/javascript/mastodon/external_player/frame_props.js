// Fullscreen on this iframe is `fullscreen *`. An omitted allowlist means
// 'src' (the origin of the src URL). Naming fullscreen in allow also
// disables allowfullscreen, whose allowlist is *. A generic player may
// redirect or nest an origin we cannot list here. `fullscreen *` is that
// same per-iframe delegation, written explicitly so it cannot collapse
// back to 'src'. allowFullScreen remains for agents that ignore allow.
// This does not override a parent Permissions-Policy denial, a denial
// from the embedded document, or the user-gesture requirement.
// createFrame copies these onto the iframe when the node is created.
// Changing allow after load does not update the container policy.
// No autoplay permission is included.
export const externalEmbedFrameProps = {
  sandbox: 'allow-scripts allow-same-origin allow-presentation allow-popups allow-popups-to-escape-sandbox',
  allow: 'fullscreen *; encrypted-media; picture-in-picture',
  referrerPolicy: 'no-referrer',
  allowFullScreen: true,
};
