(() => {
  const cfg = window.CHASSE_CONFIG;
  if (!cfg) return;

  let participant = null;
  let eventState = null;
  let selfMarker = null;
  let selfAccuracy = null;
  let watchId = null;
  let stateRefreshBusy = false;
  let managerRefreshBusy = false;

  const style = document.createElement("style");
  style.textContent = `
    .global-game-timer,
    .target-state-block,
    .organizer-player-manager {
      margin: 10px 0 14px;
      padding: 12px;
      border: 1px solid rgba(255,255,255,.12);
      border-radius: 10px;
      background: rgba(255,255,255,.035);
    }
    .global-game-timer-main { font-size: 1.35rem; font-weight: 850; margin-top: 3px; }
    .game-finished-banner {
      margin: 10px 0 14px; padding: 14px; border-radius: 10px;
      border: 1px solid rgba(255,255,255,.18);
      background: rgba(255,255,255,.07); text-align: center; font-weight: 850;
    }
    .target-state-actions, .player-manager-actions, .player-editor-actions {
      display: flex; flex-wrap: wrap; gap: 8px; margin-top: 10px;
    }
    .target-state-actions button.active-state { outline: 2px solid rgba(255,255,255,.55); outline-offset: 1px; }
    .self-position-dot {
      width: 18px; height: 18px; border-radius: 50%; background: #58a6ff;
      border: 3px solid #fff; box-shadow: 0 0 0 5px rgba(88,166,255,.22);
    }
    .organizer-player-manager .manager-form,
    .organizer-player-manager .player-editor { display: grid; gap: 8px; }
    .organizer-player-manager .manager-form {
      grid-template-columns: minmax(0,1fr) minmax(120px,.7fr) minmax(0,1fr) auto;
      align-items: end; margin-top: 10px;
    }
    .organizer-player-manager .player-manager-list { display: grid; gap: 10px; margin-top: 14px; }
    .organizer-player-manager .player-editor {
      padding: 10px; border: 1px solid rgba(255,255,255,.09); border-radius: 9px;
      background: rgba(255,255,255,.025);
      grid-template-columns: minmax(0,1.2fr) minmax(110px,.7fr) auto; align-items: end;
    }
    .organizer-player-manager label { display: grid; gap: 4px; font-size: .82rem; }
    .organizer-player-manager input, .organizer-player-manager select { width: 100%; box-sizing: border-box; }
    .player-editor-meta { grid-column: 1 / -1; display: flex; flex-wrap: wrap; gap: 7px; align-items: center; }
    .player-code-row { grid-column: 1 / -1; display: grid; grid-template-columns: minmax(0,1fr) auto; gap: 8px; align-items: end; }
    body.player-live-mode footer { display: none; }
    body.player-live-mode #targetPanel > h3,
    body.player-live-mode #targetPingList { display: none; }
    body.player-live-mode .role-panel { padding-top: 12px; }
    body.player-live-mode #map { min-height: 46vh; }
    @media (max-width: 720px) {
      .organizer-player-manager .manager-form, .organizer-player-manager .player-editor { grid-template-columns: 1fr; }
      .player-code-row, .player-editor-meta { grid-column: 1; }
    }
  `;
  document.head.appendChild(style);

  function escapeHtml(value) {
    return String(value ?? "").replace(/[&<>'"]/g, (c) => ({
      "&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"
    }[c]));
  }

  function client() { return window.CHASSE_LIVE_CLIENT || null; }

  function formatDuration(ms) {
    const total = Math.max(0, Math.floor(ms / 1000));
    const h = Math.floor(total / 3600);
    const m = Math.floor((total % 3600) / 60);
    const s = total % 60;
    return `${String(h).padStart(2,"0")}:${String(m).padStart(2,"0")}:${String(s).padStart(2,"0")}`;
  }

  function rolePrefix(role) { return role === "target" ? "I" : role === "hunter" ? "H" : "O"; }

  function suggestCode(pseudo, role) {
    const letters = String(pseudo || "").normalize("NFD").replace(/[\u0300-\u036f]/g,"")
      .toUpperCase().replace(/[^A-Z0-9]/g,"").slice(0,3);
    const core = (letters || Math.random().toString(36).slice(2,5).toUpperCase()).padEnd(3,"X");
    return `${rolePrefix(role)}-${core}`;
  }

  function injectTimer(panelId, prefix) {
    const panel = document.getElementById(panelId);
    if (!panel || document.getElementById(`${prefix}GlobalGameTimer`)) return;
    const box = document.createElement("div");
    box.id = `${prefix}GlobalGameTimer`;
    box.className = "global-game-timer";
    box.innerHTML = `
      <span class="eyebrow">FIN DE PARTIE</span>
      <div id="${prefix}GlobalGameTimerMain" class="global-game-timer-main">En attente du START</div>
      <small id="${prefix}GlobalGameTimerSub" class="muted">Durée totale : 2 heures.</small>
    `;
    const anchor = panel.querySelector(".ping-countdown") || panel.firstElementChild;
    if (anchor) panel.insertBefore(box, anchor); else panel.appendChild(box);
  }

  function renderGlobalTimer() {
    if (!participant || !["target","hunter"].includes(participant.role)) return;
    const prefix = participant.role;
    const main = document.getElementById(`${prefix}GlobalGameTimerMain`);
    const sub = document.getElementById(`${prefix}GlobalGameTimerSub`);
    if (!main || !sub) return;

    if (!eventState || eventState.status === "scheduled" || !eventState.actual_ends_at) {
      main.textContent = "EN ATTENTE DU START";
      sub.textContent = "Le chrono général démarrera avec la partie.";
      document.body.classList.remove("player-live-mode");
      return;
    }

    if (eventState.status === "finished") {
      main.textContent = "00:00:00";
      sub.textContent = "PARTIE TERMINÉE";
      document.body.classList.remove("player-live-mode");
      showFinishedBanner();
      const send = document.getElementById("sendPingBtn");
      if (send) send.disabled = true;
      return;
    }

    document.body.classList.add("player-live-mode");
    const remaining = new Date(eventState.actual_ends_at).getTime() - Date.now();
    if (remaining <= 0) {
      main.textContent = "00:00:00";
      sub.textContent = "Fin en cours de validation…";
    } else {
      main.textContent = formatDuration(remaining);
      sub.textContent = "Temps restant avant la fin du jeu.";
    }
  }

  function showFinishedBanner() {
    const panel = participant?.role === "target" ? document.getElementById("targetPanel")
      : participant?.role === "hunter" ? document.getElementById("hunterPanel") : null;
    if (!panel || document.getElementById("gameFinishedBanner")) return;
    const banner = document.createElement("div");
    banner.id = "gameFinishedBanner";
    banner.className = "game-finished-banner";
    banner.textContent = "PARTIE TERMINÉE";
    panel.prepend(banner);
  }

  async function refreshEventState() {
    if (stateRefreshBusy || !participant || !client()) return;
    stateRefreshBusy = true;
    try {
      const { data, error } = await client().rpc("sync_my_event_state");
      if (error) return;
      eventState = Array.isArray(data) ? data[0] : data;
      renderGlobalTimer();
    } finally { stateRefreshBusy = false; }
  }

  function startOwnPosition() {
    if (!participant || !["target","hunter"].includes(participant.role)) return;
    if (!navigator.geolocation || watchId !== null) return;

    watchId = navigator.geolocation.watchPosition(
      (pos) => {
        const map = window.CHASSE_MAP;
        if (!map || !window.L) return;
        const latlng = [pos.coords.latitude, pos.coords.longitude];

        if (!selfMarker) {
          const icon = L.divIcon({
            className: "", html: '<div class="self-position-dot"></div>',
            iconSize:[18,18], iconAnchor:[9,9]
          });
          selfMarker = L.marker(latlng,{icon,zIndexOffset:1500})
            .bindTooltip("Vous êtes ici",{direction:"top",className:"map-label"}).addTo(map);
          selfAccuracy = L.circle(latlng,{
            radius:Math.max(5,pos.coords.accuracy||5),weight:1,fillOpacity:.05
          }).addTo(map);
        } else {
          selfMarker.setLatLng(latlng);
          selfAccuracy?.setLatLng(latlng);
          selfAccuracy?.setRadius(Math.max(5,pos.coords.accuracy||5));
        }
      },
      () => {},
      {enableHighAccuracy:true,maximumAge:5000,timeout:15000}
    );
  }

  function injectTargetState() {
    const panel = document.getElementById("targetPanel");
    if (!panel || document.getElementById("targetStateBlock")) return;
    const block = document.createElement("div");
    block.id = "targetStateBlock";
    block.className = "target-state-block";
    block.innerHTML = `
      <span class="eyebrow">MON ÉTAT</span>
      <div id="targetStateLabel" class="big-status">Libre</div>
      <div class="target-state-actions">
        <button class="ghost small" data-target-state="capturing">EN COURS DE CAPTURE</button>
        <button class="ghost small" data-target-state="prisoner">EN PRISON</button>
        <button class="ghost small" data-target-state="free">LIBÉRÉE / LIBRE</button>
      </div>
      <small class="muted">Cet état est visible par l'Organisateur. Les pings continuent normalement.</small>
    `;
    const divider = panel.querySelector(".divider");
    if (divider) panel.insertBefore(block,divider); else panel.appendChild(block);

    block.querySelectorAll("[data-target-state]").forEach((button) => {
      button.addEventListener("click", async () => {
        button.disabled = true;
        try {
          const { error } = await client().rpc("set_my_target_state",{p_state:button.dataset.targetState});
          if (error) throw error;
          await refreshTargetState();
        } catch (e) {
          alert(e.message || "Impossible de modifier l'état.");
        } finally { button.disabled = false; }
      });
    });
  }

  async function refreshTargetState() {
    if (!participant || participant.role !== "target" || !client()) return;
    const { data, error } = await client().rpc("my_target_state");
    if (error) return;
    const row = Array.isArray(data) ? data[0] : data;
    if (!row) return;
    const labels = {free:"Libre",capturing:"En cours de capture",prisoner:"En prison"};
    const label = document.getElementById("targetStateLabel");
    if (label) label.textContent = labels[row.play_state] || row.play_state;
    document.querySelectorAll("[data-target-state]").forEach((button) => {
      button.classList.toggle("active-state",button.dataset.targetState === row.play_state);
    });
  }

  function injectOrganizerManager() {
    const panel = document.getElementById("organizerPanel");
    if (!panel || document.getElementById("organizerPlayerManager")) return;

    const block = document.createElement("div");
    block.id = "organizerPlayerManager";
    block.className = "organizer-player-manager";
    block.innerHTML = `
      <div class="divider"></div>
      <span class="eyebrow">GESTION DES JOUEURS</span>
      <div class="big-status">Joueurs et codes</div>
      <p class="muted compact">Ajoute, modifie ou désactive un joueur, change son rôle ou son code et libère son appareil.</p>
      <div class="manager-form">
        <label>Pseudo<input id="managerNewPseudo" maxlength="24" placeholder="Nouveau joueur" /></label>
        <label>Rôle<select id="managerNewRole">
          <option value="target">Cible</option><option value="hunter">Chasseur</option><option value="organizer">Organisateur</option>
        </select></label>
        <label>Code<input id="managerNewCode" maxlength="24" placeholder="I-XXX" /></label>
        <button id="managerAddPlayer" class="primary small">AJOUTER</button>
      </div>
      <div class="player-manager-actions">
        <button id="managerGenerateNewCode" class="ghost small">GÉNÉRER LE CODE</button>
        <button id="managerRefreshPlayers" class="ghost small">ACTUALISER</button>
      </div>
      <div id="playerManagerMessage" class="muted compact"></div>
      <div id="playerManagerList" class="player-manager-list"></div>
    `;
    panel.appendChild(block);

    const pseudo = document.getElementById("managerNewPseudo");
    const role = document.getElementById("managerNewRole");
    const code = document.getElementById("managerNewCode");

    document.getElementById("managerGenerateNewCode")?.addEventListener("click",() => {
      code.value = suggestCode(pseudo.value,role.value);
    });
    pseudo?.addEventListener("blur",() => {
      if (!code.value.trim()) code.value = suggestCode(pseudo.value,role.value);
    });
    role?.addEventListener("change",() => {
      if (!code.value.trim() || /^[IHO]-/.test(code.value.trim().toUpperCase())) {
        code.value = suggestCode(pseudo.value,role.value);
      }
    });

    document.getElementById("managerAddPlayer")?.addEventListener("click",async () => {
      const message = document.getElementById("playerManagerMessage");
      try {
        if (!pseudo.value.trim()) throw new Error("Saisis un pseudo.");
        if (!code.value.trim()) code.value = suggestCode(pseudo.value,role.value);
        const { error } = await client().rpc("organizer_create_player",{
          p_pseudo:pseudo.value.trim(),p_role:role.value,p_team:null,p_code:code.value.trim()
        });
        if (error) throw error;
        message.textContent = `${pseudo.value.trim()} ajouté avec le code ${code.value.trim().toUpperCase()}.`;
        pseudo.value = ""; code.value = "";
        await refreshPlayerManager();
      } catch (e) {
        message.textContent = e.message || "Impossible d'ajouter le joueur.";
      }
    });

    document.getElementById("managerRefreshPlayers")?.addEventListener("click",refreshPlayerManager);
  }

  async function refreshPlayerManager() {
    if (managerRefreshBusy || !participant || participant.role !== "organizer" || !client()) return;
    const list = document.getElementById("playerManagerList");
    if (!list) return;
    managerRefreshBusy = true;
    try {
      const { data, error } = await client().rpc("organizer_manage_list");
      if (error) throw error;
      const rows = data || [];

      list.innerHTML = rows.map((row) => {
        const stateLabel = row.role === "target" ? ({free:"Libre",capturing:"Capture",prisoner:"Prison"}[row.play_state] || row.play_state) : "—";
        return `
          <div class="player-editor" data-player-id="${row.id}">
            <label>Pseudo<input data-field="pseudo" maxlength="24" value="${escapeHtml(row.pseudo)}" /></label>
            <label>Rôle<select data-field="role" ${row.is_self ? "disabled" : ""}>
              <option value="target" ${row.role==="target"?"selected":""}>Cible</option>
              <option value="hunter" ${row.role==="hunter"?"selected":""}>Chasseur</option>
              <option value="organizer" ${row.role==="organizer"?"selected":""}>Organisateur</option>
            </select></label>
            <label>Actif<input data-field="active" type="checkbox" ${row.active?"checked":""} ${row.is_self?"disabled":""} /></label>
            <div class="player-code-row">
              <label>Nouveau code (laisser vide = inchangé)<input data-field="code" maxlength="24" placeholder="Code inchangé" /></label>
              <button class="ghost small" data-action="generate">GÉNÉRER</button>
            </div>
            <div class="player-editor-meta">
              <span class="badge ${row.active?"badge-green":"badge-muted"}">${row.active?"ACTIF":"INACTIF"}</span>
              <span class="badge ${row.device_linked?"badge-green":"badge-muted"}">${row.device_linked?"APPAREIL LIÉ":"APPAREIL LIBRE"}</span>
              ${row.role==="target" ? `<span class="badge badge-muted">État : ${escapeHtml(stateLabel)}</span>` : ""}
              ${row.is_self ? '<span class="badge badge-muted">TON ACCÈS</span>' : ""}
            </div>
            <div class="player-editor-actions">
              <button class="primary small" data-action="save">ENREGISTRER</button>
              <button class="ghost small" data-action="release" ${row.is_self||!row.device_linked?"disabled":""}>LIBÉRER APPAREIL</button>
            </div>
          </div>
        `;
      }).join("");

      list.querySelectorAll(".player-editor").forEach((editor) => {
        const id = editor.dataset.playerId;
        const pseudoInput = editor.querySelector('[data-field="pseudo"]');
        const roleInput = editor.querySelector('[data-field="role"]');
        const activeInput = editor.querySelector('[data-field="active"]');
        const codeInput = editor.querySelector('[data-field="code"]');

        editor.querySelector('[data-action="generate"]')?.addEventListener("click",() => {
          codeInput.value = suggestCode(pseudoInput.value,roleInput.value);
        });

        editor.querySelector('[data-action="save"]')?.addEventListener("click",async (event) => {
          const btn = event.currentTarget; btn.disabled = true;
          try {
            const { error } = await client().rpc("organizer_update_player",{
              p_participant_id:id,p_pseudo:pseudoInput.value.trim(),p_role:roleInput.value,
              p_team:null,p_active:activeInput.checked,p_new_code:codeInput.value.trim()||null
            });
            if (error) throw error;
            document.getElementById("playerManagerMessage").textContent = codeInput.value.trim()
              ? `${pseudoInput.value.trim()} mis à jour. Nouveau code : ${codeInput.value.trim().toUpperCase()}.`
              : `${pseudoInput.value.trim()} mis à jour.`;
            await refreshPlayerManager();
          } catch (e) {
            document.getElementById("playerManagerMessage").textContent = e.message || "Modification impossible.";
          } finally { btn.disabled = false; }
        });

        editor.querySelector('[data-action="release"]')?.addEventListener("click",async (event) => {
          if (!confirm("Libérer l'appareil associé à ce joueur ? Son code pourra être réutilisé sur un autre appareil.")) return;
          const btn = event.currentTarget; btn.disabled = true;
          try {
            const { error } = await client().rpc("organizer_release_player",{p_participant_id:id});
            if (error) throw error;
            document.getElementById("playerManagerMessage").textContent = "Appareil libéré.";
            await refreshPlayerManager();
          } catch (e) {
            document.getElementById("playerManagerMessage").textContent = e.message || "Impossible de libérer l'appareil.";
          } finally { btn.disabled = false; }
        });
      });
    } catch (e) {
      list.innerHTML = `<span class="muted">${escapeHtml(e.message || "Liste indisponible.")}</span>`;
    } finally { managerRefreshBusy = false; }
  }

  function setup() {
    participant = window.CHASSE_PARTICIPANT || participant;
    const game = document.getElementById("gameView");
    if (!participant || !game || game.classList.contains("hidden")) return;

    if (participant.role === "target") {
      injectTimer("targetPanel","target");
      injectTargetState();
      refreshTargetState();
      startOwnPosition();
    } else if (participant.role === "hunter") {
      injectTimer("hunterPanel","hunter");
      startOwnPosition();
    } else if (participant.role === "organizer") {
      injectOrganizerManager();
      refreshPlayerManager();
    }
    refreshEventState();
  }

  setInterval(setup,1000);
  setInterval(renderGlobalTimer,1000);
  setInterval(refreshEventState,5000);
  setInterval(() => {
    if (participant?.role === "target") refreshTargetState();
    if (participant?.role === "organizer") refreshPlayerManager();
  },10000);
})();
