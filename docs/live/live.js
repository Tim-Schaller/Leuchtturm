import { config } from "./config.js";
import { base64Decode, openLive, parseFragment } from "./live-crypto.js";

// Texts per language; {name} and {time} are filled in.
const texts = {
  de: {
    loading: "Einen Moment …", sharing: "{name} teilt den Standort mit dir", until: "Live bis {time} Uhr",
    updated: "Aktualisiert", accuracy: "Genauigkeit", battery: "Akku", expires: "Link gültig bis",
    open: "In Apple Karten öffnen", route: "Route",
    invalid: "Dieser Link ist unvollständig", invalidHint: "Bitte öffne den ganzen Link aus der Nachricht, auch den Teil nach #.",
    ended: "Dieser Link ist beendet", endedHint: "Die Person teilt ihren Standort hier nicht mehr.",
    expired: "Dieser Link ist abgelaufen", expiredHint: "Live-Links gelten eine Stunde.",
    setup: "Noch nicht eingerichtet", setupHint: "Diese Seite braucht noch einen CloudKit-Zugang.",
    offline: "Keine Verbindung", offlineHint: "Neuer Versuch in ein paar Sekunden.",
    note: "Ende-zu-Ende-verschlüsselt: Der Schlüssel steht nur im Link hinter dem #, den dein Browser nie an einen Server schickt. Apple (iCloud) speichert nur verschlüsselte Daten.",
    source: "Leuchtturm ist Open Source",
  },
  en: {
    loading: "One moment …", sharing: "{name} is sharing their location with you", until: "Live until {time}",
    updated: "Updated", accuracy: "Accuracy", battery: "Battery", expires: "Link valid until",
    open: "Open in Apple Maps", route: "Directions",
    invalid: "This link is incomplete", invalidHint: "Please open the whole link from the message, including the part after #.",
    ended: "This link has ended", endedHint: "The location is no longer shared here.",
    expired: "This link has expired", expiredHint: "Live links last one hour.",
    setup: "Not set up yet", setupHint: "This page still needs CloudKit access.",
    offline: "No connection", offlineHint: "Trying again in a few seconds.",
    note: "End-to-end encrypted: the key is only in the link after the #, which your browser never sends to a server. Apple (iCloud) stores only encrypted data.",
    source: "Leuchtturm is open source",
  },
  nl: {
    loading: "Een moment …",
    sharing: "{name} deelt de locatie met je",
    until: "Live tot {time} uur",
    updated: "Bijgewerkt",
    accuracy: "Nauwkeurigheid",
    battery: "Batterij",
    expires: "Link geldig tot",
    open: "Open in Apple Kaarten",
    route: "Route",
    invalid: "Deze link is onvolledig",
    invalidHint: "Open de hele link uit het bericht, ook het deel na #.",
    ended: "Deze link is beëindigd",
    endedHint: "De persoon deelt de locatie hier niet meer.",
    expired: "Deze link is verlopen",
    expiredHint: "Livelinks zijn een uur geldig.",
    setup: "Nog niet ingesteld",
    setupHint: "Deze pagina heeft nog CloudKit-toegang nodig.",
    offline: "Geen verbinding",
    offlineHint: "Nieuwe poging over een paar seconden.",
    note: "End-to-end versleuteld: de sleutel staat alleen in de link achter de #, die je browser nooit naar een server stuurt. Apple (iCloud) bewaart alleen versleutelde gegevens.",
    source: "Leuchtturm is open source",
  },
  pl: {
    loading: "Chwileczkę…",
    sharing: "{name} udostępnia ci swoją lokalizację",
    until: "Na żywo do {time}",
    updated: "Zaktualizowano",
    accuracy: "Dokładność",
    battery: "Bateria",
    expires: "Link ważny do",
    open: "Otwórz w Mapach Apple",
    route: "Trasa",
    invalid: "Ten link jest niekompletny",
    invalidHint: "Otwórz cały link z wiadomości, także część po znaku #.",
    ended: "Ten link został zakończony",
    endedHint: "Ta osoba już tu nie udostępnia swojej lokalizacji.",
    expired: "Ten link wygasł",
    expiredHint: "Linki na żywo są ważne przez godzinę.",
    setup: "Jeszcze nieskonfigurowane",
    setupHint: "Ta strona potrzebuje jeszcze dostępu do CloudKit.",
    offline: "Brak połączenia",
    offlineHint: "Ponowna próba za kilka sekund.",
    note: "Szyfrowanie end-to-end: klucz jest tylko w linku po znaku #, którego twoja przeglądarka nigdy nie wysyła do serwera. Apple (iCloud) przechowuje tylko zaszyfrowane dane.",
    source: "Leuchtturm jest open source",
  },
  tr: {
    loading: "Bir saniye …",
    sharing: "{name} konumunu seninle paylaşıyor",
    until: "{time} saatine kadar canlı",
    updated: "Güncellendi",
    accuracy: "Doğruluk",
    battery: "Pil",
    expires: "Bağlantı bitişi",
    open: "Apple Harita’da aç",
    route: "Yol tarifi",
    invalid: "Bu bağlantı eksik",
    invalidHint: "Lütfen mesajdaki bağlantının tamamını, # işaretinden sonraki kısmı da dahil olmak üzere aç.",
    ended: "Bu bağlantı sona erdi",
    endedHint: "Bu kişi konumunu burada artık paylaşmıyor.",
    expired: "Bu bağlantının süresi doldu",
    expiredHint: "Canlı bağlantılar bir saat geçerlidir.",
    setup: "Henüz ayarlanmadı",
    setupHint: "Bu sayfanın hâlâ bir CloudKit erişimine ihtiyacı var.",
    offline: "Bağlantı yok",
    offlineHint: "Birkaç saniye içinde yeniden denenecek.",
    note: "Uçtan uca şifreli: Anahtar yalnızca bağlantıda # işaretinden sonra yer alır ve tarayıcın bu kısmı hiçbir zaman bir sunucuya göndermez. Apple (iCloud) yalnızca şifreli verileri saklar.",
    source: "Leuchtturm açık kaynaklıdır",
  },
  fr: {
    loading: "Un instant…",
    sharing: "{name} partage sa position avec toi",
    until: "En direct jusqu'à {time}",
    updated: "Mis à jour",
    accuracy: "Précision",
    battery: "Batterie",
    expires: "Lien valable jusqu'à",
    open: "Ouvrir dans Plans",
    route: "Itinéraire",
    invalid: "Ce lien est incomplet",
    invalidHint: "Ouvre le lien complet du message, y compris la partie après le #.",
    ended: "Ce lien a pris fin",
    endedHint: "La personne ne partage plus sa position ici.",
    expired: "Ce lien a expiré",
    expiredHint: "Les liens en direct sont valables une heure.",
    setup: "Pas encore configuré",
    setupHint: "Cette page a encore besoin d'un accès CloudKit.",
    offline: "Pas de connexion",
    offlineHint: "Nouvel essai dans quelques secondes.",
    note: "Chiffré de bout en bout : la clé se trouve uniquement dans le lien, après le #, que ton navigateur n'envoie jamais à un serveur. Apple (iCloud) ne stocke que des données chiffrées.",
    source: "Leuchtturm est open source",
  },
  it: {
    loading: "Un momento …",
    sharing: "{name} condivide la sua posizione con te",
    until: "Dal vivo fino alle {time}",
    updated: "Aggiornato",
    accuracy: "Precisione",
    battery: "Batteria",
    expires: "Link valido fino alle",
    open: "Apri in Mappe",
    route: "Indicazioni",
    invalid: "Questo link è incompleto",
    invalidHint: "Apri il link completo dal messaggio, compresa la parte dopo #.",
    ended: "Questo link è terminato",
    endedHint: "La persona non condivide più qui la sua posizione.",
    expired: "Questo link è scaduto",
    expiredHint: "I link dal vivo valgono un'ora.",
    setup: "Non ancora configurato",
    setupHint: "Questa pagina richiede ancora un accesso a CloudKit.",
    offline: "Nessuna connessione",
    offlineHint: "Nuovo tentativo tra pochi secondi.",
    note: "Crittografia end-to-end: la chiave si trova solo nel link dopo il #, che il tuo browser non invia mai a un server. Apple (iCloud) salva solo dati crittografati.",
    source: "Leuchtturm è open source",
  },
  es: {
    loading: "Un momento…",
    sharing: "{name} comparte su ubicación contigo",
    until: "En directo hasta las {time}",
    updated: "Actualizado",
    accuracy: "Precisión",
    battery: "Batería",
    expires: "Enlace válido hasta",
    open: "Abrir en Mapas",
    route: "Cómo llegar",
    invalid: "Este enlace está incompleto",
    invalidHint: "Abre el enlace completo del mensaje, incluida la parte después del #.",
    ended: "Este enlace ha terminado",
    endedHint: "Esta persona ya no comparte aquí su ubicación.",
    expired: "Este enlace ha caducado",
    expiredHint: "Los enlaces en directo duran una hora.",
    setup: "Aún sin configurar",
    setupHint: "Esta página aún necesita acceso a CloudKit.",
    offline: "Sin conexión",
    offlineHint: "Nuevo intento en unos segundos.",
    note: "Cifrado de extremo a extremo: la clave solo está en la parte del enlace después del #, que tu navegador nunca envía a ningún servidor. Apple (iCloud) solo guarda datos cifrados.",
    source: "Leuchtturm es de código abierto",
  },
};
const language = (navigator.languages || [navigator.language || "en"]).map((tag) => tag.slice(0, 2).toLowerCase()).find((tag) => texts[tag]) || "en";
document.documentElement.lang = language;
const strings = texts[language];
const text = Object.fromEntries(Object.entries(strings).map(([key, value]) => [key, value.includes("{")
  ? (fill) => value.replace("{name}", fill).replace("{time}", fill)
  : value]));

const $ = (id) => document.getElementById(id);
const time = (date) => date.toLocaleTimeString(language, { hour: "2-digit", minute: "2-digit" });
const relative = new Intl.RelativeTimeFormat(language, { numeric: "auto" });
const ago = (date) => {
  const seconds = Math.round((date - Date.now()) / 1000);
  return Math.abs(seconds) < 60 ? relative.format(seconds, "second") : relative.format(Math.round(seconds / 60), "minute");
};

$("note").textContent = text.note + " ";
const source = document.createElement("a");
source.href = "https://github.com/Tim-Schaller/Leuchtturm";
source.textContent = text.source;
source.rel = "noopener noreferrer";
const imprint = document.createElement("a");
imprint.href = "https://www.timschaller.de/impressum/";
imprint.textContent = "Impressum";
imprint.rel = "noopener noreferrer";
$("note").append(source, " · ", imprint);

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
