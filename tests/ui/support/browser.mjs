// What a person sees and touches in the preset browser, found the way they
// would find it: by role, by label and by the words on it, not by how the
// script happens to build it.

import {Event} from "./dom.mjs";
import {FakeFileReader} from "./files.mjs";

export const dialog = page => page.document.querySelector(".modal");
export const body = page => page.document.querySelector(".browser");
export const all = (page, selector) => page.document.querySelectorAll(selector);
export const label = el => el.textContent.trim();

// Open the browser the way the strip's button does, from the opener's focus.
export function open(page, options, opener = "preset-browse") {
  page.$(opener).focus();
  page.window.SynthBrowser.open(options);
  return body(page);
}

// The rows of the list of presets, as the options a screen reader hears.
export const options = page => all(page, '[role="option"]');
export const names = page => options(page).map(o => o.querySelector(".browser-result-name").textContent);
export const selected = page => options(page).filter(o => o.getAttribute("aria-selected") === "true")
  .map(o => o.querySelector(".browser-result-name").textContent);
export const option = (page, name) => options(page).find(o => o.querySelector(".browser-result-name").textContent === name);

export const chip = (page, text) => all(page, ".browser-chip").find(c => label(c) === text);
export const star = (page, name) => page.document.querySelector(`[aria-label="Favorite ${name}"]`);
export const tab = (page, text) => all(page, '[role="tab"]').find(t => label(t) === text);
export const searchBox = page => page.document.querySelector('[aria-label="Search presets by name"]');
export const pressed = el => el.getAttribute("aria-pressed") === "true";

// Type into a box: the value, then the event a browser fires.
export function type(page, box, text) {
  box.value = text;
  box.dispatchEvent(new Event("input", {bubbles: true}));
}

// A key pressed on an element, as the browser delivers it: from there, up.
export function press(el, key, init = {}) {
  const event = new Event("keydown", {key, bubbles: true, ...init});
  el.dispatchEvent(event);
  return event;
}

export const focused = page => page.document.activeElement;
export const settle = () => new Promise(resolve => setImmediate(resolve));

// The text of every status region in the dialog, for "was it said".
export const said = page => all(page, '.modal [role="status"]').map(label).filter(Boolean);
export const feedback = page => page.document.querySelector(".browser-feedback");

// ------------------------------------------------------------ banks and files

export const sourceRow = (page, name) => all(page, ".browser-source")
  .find(r => r.querySelector(".browser-source-name").textContent === name);
export const sourceNames = page => all(page, ".browser-source").map(r => r.querySelector(".browser-source-name").textContent);
export const badges = row => [...row.querySelectorAll(".browser-badge")].map(label);
export const tool = (page, text) => all(page, ".browser-bank-tools button").find(b => label(b) === text);
export const heading = (page, text) => all(page, ".browser-heading .browser-heading-actions button").find(b => label(b) === text);
export const slotTool = (page, kind, name) => page.document.querySelector(`[aria-label="${kind} ${name} to..."]`);
export const disabled = el => el.getAttribute("aria-disabled") === "true";
export const dialogs = page => all(page, ".modal");
export const front = page => dialogs(page).at(-1);
export const submit = form => form.dispatchEvent(new Event("submit"));
export const wait = (ms = 15) => new Promise(resolve => setTimeout(resolve, ms));

// The file and download plumbing a browser gives the page, for the tests that
// open a file or export a bank.
export function withFiles(page) {
  page.downloads = [];
  page.window.Blob = Blob;
  page.window.URL = {createObjectURL: blob => { page.downloads.push(blob); return `blob:${page.downloads.length}`; }, revokeObjectURL() {}};
  page.window.FileReader = FakeFileReader;
  return page;
}

// Hand the picker a file, the way the browser's own dialog would, once the
// page has asked for one by clicking `button`.
export async function choose(page, button, file, input = 'input[type="file"]:not([webkitdirectory])') {
  button.click();
  const field = page.document.querySelector(input);
  field.files = Array.isArray(file) ? file : [file];
  field.onchange();
  await wait();
}
