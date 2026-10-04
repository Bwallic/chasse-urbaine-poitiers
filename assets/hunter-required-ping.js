(() => {
  const cfg = window.CHASSE_CONFIG;
  if (!cfg) return;

  let participant = null;
  let statusRow = null;
  let busy = false;
  const layers = new Map();

  const style = document.createElement("style");
  style.textContent = `
    .hunter-required-box {
      margin: 10px 0 14px;
      padding: 12px;
      border: 1px solid rgba(255,86,86,.45);
      border-radius: 10px;
      background: rgba(255,86,86,.07);
    }
    .hunter-required-main { font-size: 1.15rem; font-weight: 850; margin-top: 3px; }
    .hunter-required-marker {
      width: 22px; height: 22px; border-radius: 50%;
      background: #ff5656; border: 4px double #fff;
      box-shadow: 0 0 0 5px rgba(255,86,86,.26);
    }
  `;
  document.head.appendChild(style);

  function client() { return window.CHASSE_LIVE_CLIENT || null; }

  function fmt(ms) {
    const sec = Math.max(0, Math.floor(Math.abs(ms) / 1000));
    const m = Math.floor(sec / 60);
    const s = sec % 60;
    return `${String(m).padStart(2,"0")}:${String(s).padStart(2,"0")}`;
  }

  function injectHunterControl() {
    const panel = document.getElementById("hunterPanel");
    if (!panel || document.getElementById("hunterRequiredPingBox")) return;

    const box = document.createElement("div");
    box.id = "hunterRequiredPingBox";
    box.className = "hunter-required-box";
    box.innerHTML = `
      <span class="eyebrow">PING CHASSEUR OBLIGATOIRE · +60 MIN</span>
      <div id="hunterRequiredPingMain" class="hunter-required-main">En attente du START</div>
      <small id="hunterRequiredPingSub" class="muted">Ce ping sera visible par les Cibles, les Chasseurs et l'Organisateur.</small>
      <button id="sendRequiredHunterPingBtn" class="primary small" disabled>ENVOYER LE PING OBLIGATOIRE</button>
    `;

    const anchor = panel.querySelector(".divider") || panel.firstElementChild;
    if (anchor) panel.insertBefore(box, anchor);
    else panel.appendChild(box);

    document.getElementById("sendRequiredHunterPingBtn")?.addEventListener("click", sendRequiredPing);
  }

  function renderStatus() {
    if (!participant || participant.role !== "hunter") return;
    const main = document.getElementById("hunterRequiredPingMain");
    const sub = document.getElementById("hunterRequiredPingSub");
    const btn = document.getElementById("sendRequiredHunterPingBtn");
    if (!main || !sub || !btn) return;

    btn.disabled = true;

    if (!statusRow || statusRow.event_status === "scheduled" || !statusRow.scheduled_at) {
      main.textContent = "EN ATTENTE DU START";
      sub.textContent = "Le ping sera demandé exactement à +60 min.";
      return;
    }

    if (statusRow.sent) {
      main.textContent = "PING +60 ENVOYÉ";
      sub.textContent = "Position obligatoire partagée avec tous les joueurs et l'Organisateur.";
      return;
    }

    if (statusRow.event_status === "finished") {
      main.textContent = "PARTIE TERMINÉE";
      sub.textContent = "Le ping obligatoire n'est plus disponible.";
      return;
    }

    const diff = new Date(statusRow.scheduled_at).getTime() - Date.now();

    if (diff > 60000) {
      main.textContent = "DANS " + fmt(diff);
      sub.textContent = "Ouverture de la fenêtre d'envoi à +59 min.";
      return;
    }

    if (diff >= -60000) {
      main.textContent = diff >= 0 ? "DANS " + fmt(diff) : "À ENVOYER MAINTENANT";
      sub.textContent = "Fenêtre obligatoire : +60 min ±60 secondes.";
      btn.disabled = false;
      return;
    }

    main.textContent = "PING +60 MANQUÉ";
    sub.textContent = "La fenêtre d'envoi est dépassée.";
  }

  async function refreshStatus() {
    if (!participant || participant.role !== "hunter" || !client()) return;
    const { data, error } = await client().rpc("my_required_hunter_ping_status");
    if (error) return;
    statusRow = Array.isArray(data) ? data[0] : data;
    renderStatus();
  }

  async function sendRequiredPing() {
    if (busy || !client()) return;
    const btn = document.getElementById("sendRequiredHunterPingBtn");
    const sub = document.getElementById("hunterRequiredPingSub");
    busy = true;
    if (btn) btn.disabled = true;
    if (sub) sub.textContent = "Localisation GPS en cours…";

    try {
      const pos = await new Promise((resolve, reject) => {
        navigator.geolocation.getCurrentPosition(resolve, reject, {
          enableHighAccuracy: true,
          timeout: 15000,
          maximumAge: 0
        });
      });

      const { latitude, longitude, accuracy } = pos.coords;
      const { error } = await client().rpc("submit_required_hunter_ping", {
        p_lat: latitude,
        p_lng: longitude,
        p_accuracy_m: accuracy
      });
      if (error) throw error;

      await refreshStatus();
      await refreshVisiblePings();
    } catch (e) {
      if (sub) sub.textContent = e.message || "Impossible d'envoyer le ping obligatoire.";
    } finally {
      busy = false;
      renderStatus();
    }
  }

  async function refreshVisiblePings() {
    if (!participant || !client()) return;
    const map = window.CHASSE_MAP;
    if (!map || !window.L) return;

    const { data, error } = await client().rpc("visible_required_hunter_pings");
    if (error) return;

    const seen = new Set();
    for (const row of data || []) {
      seen.add(row.participant_id);
      let marker = layers.get(row.participant_id);
      const latlng = [row.lat, row.lng];

      if (!marker) {
        const icon = L.divIcon({
          className: "",
          html: '<div class="hunter-required-marker"></div>',
          iconSize: [22,22],
          iconAnchor: [11,11]
        });
        marker = L.marker(latlng, { icon, zIndexOffset: 1450 }).addTo(map);
        layers.set(row.participant_id, marker);
      } else {
        marker.setLatLng(latlng);
      }

      marker.bindTooltip(
        row.pseudo + " · Ping Chasseur obligatoire +60",
        { direction: "top", className: "map-label" }
      );
    }

    layers.forEach((marker, id) => {
      if (!seen.has(id)) {
        marker.remove();
        layers.delete(id);
      }
    });
  }

  function setup() {
    participant = window.CHASSE_PARTICIPANT || participant;
    const game = document.getElementById("gameView");
    if (!participant || !game || game.classList.contains("hidden")) return;

    if (participant.role === "hunter") injectHunterControl();
    refreshVisiblePings();
    if (participant.role === "hunter") refreshStatus();
  }

  setInterval(setup, 1000);
  setInterval(renderStatus, 1000);
  setInterval(refreshVisiblePings, 5000);
  setInterval(refreshStatus, 5000);
})();
