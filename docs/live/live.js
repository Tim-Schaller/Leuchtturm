import { config } from "./config.js";
import { base64Decode, openLive, parseFragment } from "./live-crypto.js";

const german = (navigator.language || "de").toLowerCase().startsWith("de");
document.documentElement.lang = german ? "de" : "en";
const text = german
  ? {
      loading: "Einen Moment …",
      sharing: (name) => `${name} teilt den Standort mit dir`,
      until: (time) => `Live bis ${time} Uhr`,
      updated: "Aktualisiert", accuracy: "Genauigkeit", battery: "Akku", expires: "Link gültig bis",
      open: "In Apple Karten öffnen", route: "Route",
      invalid: "Dieser Link ist unvollständig", invalidHint: "Bitte öffne den ganzen Link aus der Nachricht, auch den Teil nach #.",
      ended: "Dieser Link ist beendet", endedHint: "Die Person teilt ihren Standort hier nicht mehr.",
      expired: "Dieser Link ist abgelaufen", expiredHint: "Live-Links gelten eine Stunde.",
      setup: "Noch nicht eingerichtet", setupHint: "Diese Seite braucht noch einen CloudKit-Zugang.",
      offline: "Keine Verbindung", offlineHint: "Neuer Versuch in ein paar Sekunden.",
      note: "Ende-zu-Ende-verschlüsselt: Der Schlüssel steht nur im Link hinter dem #, den dein Browser nie an einen Server schickt. Apple (iCloud) speichert nur verschlüsselte Daten.",
      source: "Leuchtturm ist Open Source",
    }
  : {
      loading: "One moment …",
      sharing: (name) => `${name} is sharing their location with you`,
      until: (time) => `Live until ${time}`,
      updated: "Updated", accuracy: "Accuracy", battery: "Battery", expires: "Link valid until",
      open: "Open in Apple Maps", route: "Directions",
      invalid: "This link is incomplete", invalidHint: "Please open the whole link from the message, including the part after #.",
      ended: "This link has ended", endedHint: "The location is no longer shared here.",
      expired: "This link has expired", expiredHint: "Live links last one hour.",
      setup: "Not set up yet", setupHint: "This page still needs CloudKit access.",
      offline: "No connection", offlineHint: "Trying again in a few seconds.",
      note: "End-to-end encrypted: the key is only in the link after the #, which your browser never sends to a server. Apple (iCloud) stores only encrypted data.",
      source: "Leuchtturm is open source",
    };

const $ = (id) => document.getElementById(id);
const time = (date) => date.toLocaleTimeString(german ? "de-DE" : undefined, { hour: "2-digit", minute: "2-digit" });
const relative = new Intl.RelativeTimeFormat(german ? "de" : "en", { numeric: "auto" });
const ago = (date) => {
  const seconds = Math.round((date - Date.now()) / 1000);
  return Math.abs(seconds) < 60 ? relative.format(seconds, "second") : relative.format(Math.round(seconds / 60), "minute");
};

$("note").textContent = text.note + " ";
const source = document.createElement("a");
source.href = "https://github.com/Tim-Schaller/Leuchtturm";
source.textContent = text.source;
source.rel = "noopener noreferrer";
$("note").append(source, ".");

function show(title, subtitle) {
  $("title").textContent = title;
  $("subtitle").textContent = subtitle || "";
  $("facts").hidden = true;
  $("actions").hidden = true;
  $("map").hidden = true;
  document.title = "Leuchtturm · Live";
}

const link = parseFragment(location.hash);
let timer = null;
let last = null;

async function fetchBlob() {
  const environment = link.environment === "p" ? "production" : "development";
  const url = `https://api.apple-cloudkit.com/database/1/${encodeURIComponent(config.container)}/${environment}/public/records/lookup?ckAPIToken=${encodeURIComponent(config.cloudKitToken)}`;
  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ records: [{ recordName: "live-" + link.id }] }),
    referrerPolicy: "no-referrer",
    cache: "no-store",
  });
  if (!response.ok) throw new Error("http " + response.status);
  const record = (await response.json()).records?.[0];
  if (!record || record.serverErrorCode === "NOT_FOUND") return null;
  if (record.serverErrorCode) throw new Error(record.serverErrorCode);
  const value = record.fields?.blob?.value;
  return typeof value === "string" ? base64Decode(value) : null;
}

function render(where) {
  const initials = where.name.split(/\s+/).filter(Boolean).slice(0, 2).map((part) => [...part][0]).join("").toUpperCase();
  $("avatar").textContent = initials || "·";
  $("title").textContent = text.sharing(where.name);
  $("subtitle").textContent = text.until(time(where.expires));
  document.title = `${where.name} · Leuchtturm`;
  $("updated-label").textContent = text.updated;
  $("updated").textContent = ago(where.timestamp);
  $("accuracy-label").textContent = text.accuracy;
  $("accuracy").textContent = `± ${Math.round(where.accuracy)} m`;
  $("battery-row").hidden = where.battery === null;
  $("battery-label").textContent = text.battery;
  $("battery").textContent = `${where.battery} %`;
  $("expires-label").textContent = text.expires;
  $("expires").textContent = time(where.expires);
  const coordinate = `${where.latitude.toFixed(6)},${where.longitude.toFixed(6)}`;
  $("open").href = `https://maps.apple.com/?ll=${coordinate}&q=${encodeURIComponent(where.name)}`;
  $("open").textContent = text.open;
  $("route").href = `https://maps.apple.com/?daddr=${coordinate}`;
  $("route").textContent = text.route;
  $("facts").hidden = false;
  $("actions").hidden = false;
  updateMap(where);
}

async function refresh() {
  try {
    const blob = await fetchBlob();
    if (!blob) return stop(text.ended, text.endedHint);
    const where = await openLive(blob, link);
    if (where.expires <= new Date()) return stop(text.expired, text.expiredHint);
    last = where;
    render(where);
  } catch (error) {
    if (error instanceof DOMException || error.message === "malformed") return stop(text.invalid, text.invalidHint);
    if (last) render(last);
    else show(text.offline, text.offlineHint);
  }
}

function stop(title, subtitle) {
  clearInterval(timer);
  show(title, subtitle);
}

// MARK: Optional Apple map (needs a MapKit JS token for this domain)

let map = null;
let marker = null;
let mapKitLoading = null;

function loadMapKit() {
  mapKitLoading ??= new Promise((resolve, reject) => {
    window.leuchtturmMapKitReady = resolve;
    const script = document.createElement("script");
    script.src = "https://cdn.apple-mapkit.com/mk/5.x.x/mapkit.core.js";
    script.crossOrigin = "anonymous";
    script.dataset.callback = "leuchtturmMapKitReady";
    script.dataset.libraries = "map,annotations";
    script.dataset.initialToken = config.mapKitToken;
    script.onerror = reject;
    document.head.append(script);
  });
  return mapKitLoading;
}

async function updateMap(where) {
  if (!config.mapKitToken) return;
  try {
    await loadMapKit();
    const mapkit = window.mapkit;
    const coordinate = new mapkit.Coordinate(where.latitude, where.longitude);
    $("map").hidden = false;
    if (!map) {
      map = new mapkit.Map("map", { showsPointsOfInterest: false, isRotationEnabled: false });
      marker = new mapkit.MarkerAnnotation(coordinate, { title: where.name, color: "#2F8F5B" });
      map.addAnnotation(marker);
      map.region = new mapkit.CoordinateRegion(coordinate, new mapkit.CoordinateSpan(0.01, 0.01));
    } else {
      marker.coordinate = coordinate;
      map.setCenterAnimated(coordinate);
    }
  } catch {
    $("map").hidden = true;
  }
}

if (!link) {
  show(text.invalid, text.invalidHint);
} else if (!config.cloudKitToken) {
  show(text.setup, text.setupHint);
} else {
  show(text.loading);
  refresh();
  timer = setInterval(refresh, 20000);
}
