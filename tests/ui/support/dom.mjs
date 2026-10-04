// A deliberately small DOM, enough to boot ui/app.js in node:vm.
//
// Only the surface the panel touches is modelled. Layout never happens, so every
// measurement is zero, and events are delivered synchronously with listener
// exceptions propagating to the caller so a broken panel fails the test.

const HTML_NS = "http://www.w3.org/1999/xhtml";

export class Event {
  constructor(type, init = {}) {
    this.type = type;
    this.bubbles = !!init.bubbles;
    this.defaultPrevented = false;
    this.target = null;
    Object.assign(this, init);
  }
  preventDefault() { this.defaultPrevented = true; }
  stopPropagation() {}
  stopImmediatePropagation() {}
}

class Listeners {
  constructor() { this.byType = new Map(); }
  add(type, fn) {
    if (typeof fn !== "function") return;
    if (!this.byType.has(type)) this.byType.set(type, []);
    const list = this.byType.get(type);
    if (!list.includes(fn)) list.push(fn);
  }
  remove(type, fn) {
    const list = this.byType.get(type);
    if (list) this.byType.set(type, list.filter(f => f !== fn));
  }
  dispatch(target, event) {
    if (!event.target) event.target = target;
    event.currentTarget = target;
    for (const fn of [...(this.byType.get(event.type) || [])]) fn.call(target, event);
    return !event.defaultPrevented;
  }
  count(type) { return (this.byType.get(type) || []).length; }
}

class Node {
  constructor(ownerDocument) {
    this.ownerDocument = ownerDocument;
    this.parentNode = null;
    this.childNodes = [];
  }
  get firstChild() { return this.childNodes[0] || null; }
  get lastChild() { return this.childNodes[this.childNodes.length - 1] || null; }
  get children() { return this.childNodes.filter(n => n.nodeType === 1); }
  get parentElement() { return this.parentNode && this.parentNode.nodeType === 1 ? this.parentNode : null; }

  appendChild(node) { return this.insertBefore(node, null); }

  insertBefore(node, reference) {
    if (node.parentNode) node.parentNode.removeChild(node);
    const at = reference ? this.childNodes.indexOf(reference) : -1;
    if (reference && at < 0) throw new Error("insertBefore: reference is not a child");
    if (at < 0) this.childNodes.push(node);
    else this.childNodes.splice(at, 0, node);
    node.parentNode = this;
    return node;
  }

  removeChild(node) {
    const at = this.childNodes.indexOf(node);
    if (at < 0) throw new Error("removeChild: not a child");
    this.childNodes.splice(at, 1);
    node.parentNode = null;
    return node;
  }

  remove() { if (this.parentNode) this.parentNode.removeChild(this); }

  get textContent() { return this.childNodes.map(n => n.textContent).join(""); }
  set textContent(text) {
    for (const child of this.childNodes) child.parentNode = null;
    this.childNodes = [];
    const value = text == null ? "" : String(text);
    if (value !== "") this.appendChild(this.ownerDocument.createTextNode(value));
  }
}

class Text extends Node {
  constructor(ownerDocument, data) {
    super(ownerDocument);
    this.nodeType = 3;
    this.nodeName = "#text";
    this.data = data;
  }
  get textContent() { return this.data; }
  set textContent(text) { this.data = String(text); }
}

function kebab(name) { return name.replace(/[A-Z]/g, c => "-" + c.toLowerCase()); }

function createStyle() {
  const properties = new Map();
  const style = {};
  Object.defineProperties(style, {
    setProperty: { value: (name, value) => { properties.set(name, String(value)); } },
    getPropertyValue: { value: name => properties.get(name) || "" },
    removeProperty: { value: name => { properties.delete(name); } },
  });
  return style;
}

function createClassList(element) {
  const read = () => (element.getAttribute("class") || "").split(/\s+/).filter(Boolean);
  const write = names => element.setAttribute("class", names.join(" "));
  return {
    add(...names) { const set = read(); for (const n of names) if (!set.includes(n)) set.push(n); write(set); },
    remove(...names) { write(read().filter(n => !names.includes(n))); },
    contains(name) { return read().includes(name); },
    toggle(name, force) {
      const has = read().includes(name);
      const want = force === undefined ? !has : !!force;
      if (want && !has) this.add(name);
      if (!want && has) this.remove(name);
      return want;
    },
    get length() { return read().length; },
    toString() { return read().join(" "); },
  };
}

// Selectors: comma lists of descendant chains of compound selectors built from
// a tag, #id, .class, [attr], [attr=value] (the value may hold spaces) and
// :not() of those. That is every form the panel uses.
function parseCompound(text) {
  const match = /^(\*|[a-zA-Z][\w-]*)?((?:[.#][\w-]+|\[[^\]]+\])*)((?::not\([^()]+\))*)$/.exec(text);
  if (!match) throw new Error(`unsupported selector: ${text}`);
  const compound = { tag: match[1] && match[1] !== "*" ? match[1].toLowerCase() : null, ids: [], classes: [], attrs: [], nots: [] };
  for (const part of match[2].match(/[.#][\w-]+|\[[^\]]+\]/g) || []) {
    if (part[0] === "#") compound.ids.push(part.slice(1));
    else if (part[0] === ".") compound.classes.push(part.slice(1));
    else {
      const attr = /^\[\s*([\w-]+)\s*(?:=\s*["']?([^"'\]]*)["']?\s*)?\]$/.exec(part);
      if (!attr) throw new Error(`unsupported attribute selector: ${part}`);
      compound.attrs.push({ name: attr[1], value: attr[2] });
    }
  }
  for (const part of match[3].match(/:not\([^()]+\)/g) || []) compound.nots.push(parseCompound(part.slice(5, -1)));
  return compound;
}

function parseSelector(selector) {
  return selector.split(",").map(s => s.trim()).filter(Boolean)
    .map(chain => chain.match(/(?:\[[^\]]*\]|[^\s[])+/g).map(parseCompound));
}

function matchesCompound(element, compound) {
  if (compound.tag && element.localName.toLowerCase() !== compound.tag) return false;
  if (compound.ids.some(id => element.id !== id)) return false;
  if (compound.classes.some(c => !element.classList.contains(c))) return false;
  if (compound.nots.some(not => matchesCompound(element, not))) return false;
  return compound.attrs.every(a =>
    a.value === undefined ? element.hasAttribute(a.name) : element.getAttribute(a.name) === a.value);
}

function matchesChain(element, chain) {
  if (!matchesCompound(element, chain[chain.length - 1])) return false;
  let ancestor = element.parentElement;
  for (let i = chain.length - 2; i >= 0; i--) {
    while (ancestor && !matchesCompound(ancestor, chain[i])) ancestor = ancestor.parentElement;
    if (!ancestor) return false;
    ancestor = ancestor.parentElement;
  }
  return true;
}

function descendants(root) {
  const out = [];
  const walk = node => { for (const child of node.children) { out.push(child); walk(child); } };
  walk(root);
  return out;
}

function queryAll(root, selector) {
  const chains = parseSelector(selector);
  return descendants(root).filter(el => chains.some(chain => matchesChain(el, chain)));
}

class Element extends Node {
  constructor(ownerDocument, namespaceURI, qualifiedName) {
    super(ownerDocument);
    this.nodeType = 1;
    this.namespaceURI = namespaceURI;
    this.localName = qualifiedName;
    this.tagName = namespaceURI === HTML_NS ? qualifiedName.toUpperCase() : qualifiedName;
    this.nodeName = this.tagName;
    this.attributes = new Map();
    this.style = createStyle();
    this.classList = createClassList(this);
    this.listeners = new Listeners();
    this.disabled = false;
    this.checked = false;
    this.scrollLeft = 0;
    this.scrollTop = 0;
    this.storedInnerHTML = "";
  }

  setAttribute(name, value) { this.attributes.set(name, String(value)); }
  getAttribute(name) { return this.attributes.has(name) ? this.attributes.get(name) : null; }
  removeAttribute(name) { this.attributes.delete(name); }
  hasAttribute(name) { return this.attributes.has(name); }

  get id() { return this.getAttribute("id") || ""; }
  set id(value) { this.setAttribute("id", value); }
  get className() { return this.getAttribute("class") || ""; }
  set className(value) { this.setAttribute("class", value); }
  get type() { return this.getAttribute("type") || ""; }
  set type(value) { this.setAttribute("type", value); }
  get title() { return this.getAttribute("title") || ""; }
  set title(value) { this.setAttribute("title", value); }
  get hidden() { return this.hasAttribute("hidden"); }
  set hidden(value) { if (value) this.setAttribute("hidden", ""); else this.removeAttribute("hidden"); }

  get dataset() {
    return new Proxy({}, {
      get: (_, key) => typeof key === "string" ? (this.getAttribute("data-" + kebab(key)) ?? undefined) : undefined,
      set: (_, key, value) => { this.setAttribute("data-" + kebab(key), value); return true; },
      deleteProperty: (_, key) => { this.removeAttribute("data-" + kebab(key)); return true; },
    });
  }

  get options() { return queryAll(this, "option"); }

  get selectedIndex() {
    if (this.localName !== "select") return -1;
    if (this.chosenIndex === undefined) return this.options.length ? 0 : -1;
    return this.chosenIndex;
  }

  get value() {
    if (this.localName === "select") {
      const option = this.options[this.selectedIndex];
      return option ? option.value : "";
    }
    if (this.assignedValue !== undefined) return this.assignedValue;
    const attribute = this.getAttribute("value");
    if (attribute !== null) return attribute;
    return this.localName === "option" ? this.textContent : "";
  }
  set value(value) {
    const text = String(value);
    if (this.localName === "select") this.chosenIndex = this.options.findIndex(o => o.value === text);
    else this.assignedValue = text;
  }

  get innerHTML() { return this.storedInnerHTML; }
  set innerHTML(html) { this.textContent = ""; this.storedInnerHTML = String(html); }

  addEventListener(type, fn) { this.listeners.add(type, fn); }
  removeEventListener(type, fn) { this.listeners.remove(type, fn); }
  dispatchEvent(event) { return this.listeners.dispatch(this, event); }

  querySelector(selector) { return queryAll(this, selector)[0] || null; }
  querySelectorAll(selector) { return queryAll(this, selector); }
  matches(selector) { return parseSelector(selector).some(chain => matchesChain(this, chain)); }
  closest(selector) {
    for (let el = this; el; el = el.parentElement) if (el.matches(selector)) return el;
    return null;
  }

  getBoundingClientRect() { return { top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0, x: 0, y: 0 }; }
  get offsetTop() { return 0; }
  get offsetLeft() { return 0; }
  get offsetWidth() { return 0; }
  get offsetHeight() { return 0; }
  get clientWidth() { return 0; }
  get clientHeight() { return 0; }
  get scrollWidth() { return 0; }
  get scrollHeight() { return 0; }
  scrollIntoView() {}
  scrollTo() {}
  scrollBy() {}
  focus() {}
  blur() {}
  select() {}
  click() { this.dispatchEvent(new Event("click", { bubbles: true })); }
  setPointerCapture() {}
  releasePointerCapture() {}
  hasPointerCapture() { return false; }
}

class Document extends Node {
  constructor() {
    super(null);
    this.ownerDocument = this;
    this.nodeType = 9;
    this.listeners = new Listeners();
    this.documentElement = this.createElement("html");
    this.head = this.createElement("head");
    this.body = this.createElement("body");
    this.appendChild(this.documentElement);
    this.documentElement.appendChild(this.head);
    this.documentElement.appendChild(this.body);
  }
  createElement(tag) { return new Element(this, HTML_NS, String(tag).toLowerCase()); }
  createElementNS(namespaceURI, tag) { return new Element(this, namespaceURI, String(tag)); }
  createTextNode(data) { return new Text(this, String(data)); }
  getElementById(id) { return queryAll(this, "*").find(el => el.id === id) || null; }
  querySelector(selector) { return queryAll(this, selector)[0] || null; }
  querySelectorAll(selector) { return queryAll(this, selector); }
  elementFromPoint() { return null; }
  addEventListener(type, fn) { this.listeners.add(type, fn); }
  removeEventListener(type, fn) { this.listeners.remove(type, fn); }
  dispatchEvent(event) { return this.listeners.dispatch(this, event); }
  listenerCount(type) { return this.listeners.count(type); }
}

// The mount points of ui/index.html that app.js looks up, in the same nesting.
export function mountIndexSkeleton(document) {
  const h = (tag, attributes = {}, children = []) => {
    const el = document.createElement(tag);
    for (const [name, value] of Object.entries(attributes)) el.setAttribute(name, value);
    for (const child of children) el.appendChild(typeof child === "string" ? document.createTextNode(child) : child);
    return el;
  };
  const body = document.body;

  body.appendChild(h("header", { id: "app-header" }, [
    h("div", { class: "brand" }, ["Quesynth"]),
    h("div", { class: "head-actions" }, [
      h("button", { type: "button", id: "midi-toggle", class: "keys-toggle", "data-icon": "midi" }, ["MIDI"]),
      h("button", { type: "button", id: "keys-toggle", class: "keys-toggle", "data-icon": "keys",
        "aria-expanded": "false", "aria-controls": "keyboard" }, ["Keys"]),
      h("button", { type: "button", id: "write-toggle", class: "bank-write", "data-icon": "write" }, ["WRITE"]),
      h("button", { type: "button", id: "config-toggle", class: "bank-write", "data-icon": "config", hidden: "" }, ["CONFIG"]),
    ]),
  ]));

  body.appendChild(h("div", { id: "surface" }, [
    h("section", { class: "rack-editor", id: "rack-editor", "data-mode": "inline" }, [
      h("div", { class: "editor-body" }, [
        h("nav", { id: "navigator" }, [h("div", { class: "nav-inner" })]),
        h("main", { id: "panels" }),
      ]),
    ]),
  ]));

  body.appendChild(h("div", { id: "bank", class: "bank" }, [
    h("button", { type: "button", class: "bank-step", "data-step": "-1", "data-icon": "previous" }, ["PREV"]),
    h("div", { class: "bank-read" }, [
      h("span", { class: "bank-patch", id: "bank-patch" }, ["000:Init"]),
      h("span", { class: "bank-name", id: "bank-name" }, ["00:soundbank00"]),
    ]),
    h("button", { type: "button", class: "bank-step", "data-step": "1", "data-icon": "next" }, ["NEXT"]),
    h("div", { class: "bank-vol" }, [
      h("label", { for: "master-vol" }, ["Vol"]),
      h("input", { type: "range", id: "master-vol", min: "0", max: "100", value: "80" }),
      h("span", { class: "bank-vol-read", id: "master-vol-read" }, ["80"]),
    ]),
  ]));

  body.appendChild(h("section", { id: "keyboard", class: "keyboard", hidden: "" }, [
    h("div", { class: "keys-bar" }, [
      h("button", { type: "button", class: "oct", "data-step": "-1", "data-icon": "down" }, ["OCT DOWN"]),
      h("span", { class: "oct-label", id: "oct-label" }),
      h("button", { type: "button", class: "oct", "data-step": "1", "data-icon": "up" }, ["OCT UP"]),
    ]),
    h("div", { class: "keys-row" }, [
      h("div", { class: "wheels", id: "wheels" }),
      h("div", { class: "keys-scroll", id: "keys-scroll" }, [h("div", { class: "keys", id: "keys" })]),
    ]),
  ]));
}

// A window that doubles as the vm context's global object, so the scripts'
// bare `window`, `document` and top-level `var`s all land on one object.
export function createWindow() {
  const document = new Document();
  const listeners = new Listeners();
  const frames = [];
  const timers = [];
  const window = {
    document,
    navigator: {},
    console,
    innerWidth: 1280,
    innerHeight: 800,
    devicePixelRatio: 1,
    frames,
    timers,
    addEventListener(type, fn) { listeners.add(type, fn); },
    removeEventListener(type, fn) { listeners.remove(type, fn); },
    dispatchEvent(event) { return listeners.dispatch(window, event); },
    matchMedia(media) {
      return { media, matches: false, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} };
    },
    requestAnimationFrame(callback) { frames.push(callback); return frames.length; },
    cancelAnimationFrame() {},
    setTimeout(callback) { timers.push(callback); return timers.length; },
    clearTimeout() {},
    setInterval() { return 0; },
    clearInterval() {},
    ResizeObserver: class { observe() {} unobserve() {} disconnect() {} },
    Event,
    getComputedStyle: element => element.style,
  };
  window.window = window;
  window.self = window;
  return window;
}
