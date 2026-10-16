// Wrapper for IntersectionObserver in order to make working with it
// a bit easier. We also follow this performance advice:
// "If you need to observe multiple elements, it is both possible and
// advised to observe multiple elements using the same IntersectionObserver
// instance by calling observe() multiple times."
// https://developers.google.com/web/updates/2016/04/intersectionobserver

class IntersectionObserverWrapper {

  callbacks = {};
  nodes = {};
  observer = null;

  connect (options) {
    const onIntersection = (entries) => {
      entries.forEach(entry => {
        const id = entry.target.getAttribute('data-id');
        if (this.callbacks[id]) {
          this.callbacks[id](entry);
        }
      });
    };

    if (this.observer) this.observer.disconnect();
    this.observer = new IntersectionObserver(onIntersection, options);
    Object.keys(this.nodes).forEach(id => this.observer.observe(this.nodes[id]));
  }

  observe (id, node, callback) {
    this.callbacks[id] = callback;
    this.nodes[id] = node;
    if (this.observer) this.observer.observe(node);
  }

  unobserve (id, node) {
    delete this.callbacks[id];
    delete this.nodes[id];
    if (this.observer) this.observer.unobserve(node);
  }

  disconnect () {
    if (this.observer) {
      this.callbacks = {};
      this.nodes = {};
      this.observer.disconnect();
      this.observer = null;
    }
  }

}

export default IntersectionObserverWrapper;
