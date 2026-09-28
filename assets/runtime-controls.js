(() => {
  const cfg = window.CHASSE_CONFIG;
  if (!cfg || !window.supabase?.createClient) return;

  const originalCreateClient = window.supabase.createClient.bind(window.supabase);

  window.supabase.createClient = function patchedCreateClient(...args) {
    const client = originalCreateClient(...args);
    const originalRpc = client.rpc.bind(client);

    client.rpc = function patchedRpc(fn, params = {}, options) {
      if (fn === "claim_participant") {
        const pseudo = document.getElementById("demoPseudo")?.value?.trim() || "";
        if (!pseudo) {
          return Promise.resolve({ data: null, error: { message: "Choisis un pseudo avant d'entrer dans la partie." } });
        }
        return originalRpc("claim_participant_with_pseudo", {
          p_code: params?.p_code,
          p_pseudo: pseudo
        }, options);
      }
      return originalRpc(fn, params, options);
    };

    window.CHASSE_LIVE_CLIENT = client;
    return client;
  };

  const style = document.createElement("style");
  style.textContent = `
    #accessForm:not(.hidden) #demoPseudoWrap.hidden {
      display: flex !important;
    }
    .runtime-controls {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 10px;
      margin: 14px 0 4px;
    }
    .runtime-controls .primary,
    .runtime-controls .ghost {
      width: 100%;
    }
    .runtime-status {
      margin-top: 10px;
      padding: 10px 12px;
      border: 1px solid rgba(255,255,255,.12);
      border-radius: 10px;
      background: rgba(255,255,255,.035);
    }
    @media (max-width: 620px) {
      .runtime-controls { grid-template-columns: 1fr; }
    }
  `;
  document.head.appendChild(style);

  function formatClock(value) {
    if (!value) return "—";
    return new Intl.DateTimeFormat("fr-FR", {
      timeZone: cfg.EVENT_TIMEZONE || "Europe/Paris",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit"
    }).format(new Date(value));
  }

  function preparePseudoField() {
    const wrap = document.getElementById("demoPseudoWrap");
    const input = document.getElementById("demoPseudo");
    if (!wrap || !input) return;

    const label = wrap.querySelector("span");
    if (label) label.textContent = "Pseudo";
    input.maxLength = 24;
    input.autocomplete = "nickname";
    input.placeholder = "Choisis ton pseudo";

    if (!document.getElementById("pseudoHelp")) {
      const help = document.createElement("small");
      help.id = "pseudoHelp";
      help.className = "muted";
      help.textContent = "Le pseudo est associé à ton code lors de sa première utilisation.";
      wrap.appendChild(help);
    }
  }

  async function refreshRuntimeStatus() {
    const client = window.CHASSE_LIVE_CLIENT;
    const label = document.getElementById("eventRuntimeLabel");
    if (!client || !label) return;

    const { data, error } = await client
      .from("events")
      .select("status,actual_started_at,actual_ends_at")
      .eq("id", cfg.EVENT_ID)
      .single();

    if (error) {
      label.textContent = "État indisponible";
      return;
    }

    if (data?.status === "live" && data.actual_started_at) {
      label.textContent = `Partie démarrée à ${formatClock(data.actual_started_at)} · fin prévue ${formatClock(data.actual_ends_at)}`;
      const btn = document.getElementById("startEventBtn");
      if (btn) {
        btn.disabled = true;
        btn.textContent = "PARTIE DÉMARRÉE";
      }
    } else {
      label.textContent = "Partie en attente du départ";
    }
  }

  function injectOrganizerControls() {
    const panel = document.getElementById("organizerPanel");
    if (!panel || document.getElementById("startEventBtn")) return;

    const block = document.createElement("div");
    block.innerHTML = `
      <div class="divider"></div>
      <div>
        <span class="eyebrow">DÉROULEMENT</span>
        <div class="big-status">Contrôle de la partie</div>
      </div>
      <div class="runtime-status"><span id="eventRuntimeLabel" class="muted">Chargement…</span></div>
      <div class="runtime-controls">
        <button id="startEventBtn" class="primary">START — DÉMARRER MAINTENANT</button>
        <button id="resetExtractionBtn" class="ghost">RESET ZONE D'EXTRACTION</button>
      </div>
      <p class="muted compact">START enregistre l'heure réelle du départ, recale automatiquement les pings à +30 / +60 / +90 minutes et conserve une durée totale de 2 h. RESET efface uniquement la zone d'extraction active afin de permettre un nouveau tirage.</p>
    `;

    const firstDivider = panel.querySelector(".divider");
    if (firstDivider) panel.insertBefore(block, firstDivider);
    else panel.appendChild(block);

    document.getElementById("startEventBtn").addEventListener("click", async () => {
      if (!confirm("Démarrer la partie maintenant ? Les trois horaires de ping seront recalés à partir de cet instant.")) return;
      const client = window.CHASSE_LIVE_CLIENT;
      if (!client) return alert("Connexion Supabase indisponible.");

      const btn = document.getElementById("startEventBtn");
      btn.disabled = true;
      btn.textContent = "DÉMARRAGE…";

      const { data, error } = await client.rpc("start_event_now");
      if (error) {
        btn.disabled = false;
        btn.textContent = "START — DÉMARRER MAINTENANT";
        return alert(error.message || "Impossible de démarrer la partie.");
      }

      const row = Array.isArray(data) ? data[0] : data;
      alert(`Partie démarrée à ${formatClock(row?.actual_started_at || new Date())}.`);
      document.getElementById("refreshAdminBtn")?.click();
      await refreshRuntimeStatus();
    });

    document.getElementById("resetExtractionBtn").addEventListener("click", async () => {
      if (!confirm("Réinitialiser la zone d'extraction active ? Un nouveau tirage sera ensuite possible.")) return;
      const client = window.CHASSE_LIVE_CLIENT;
      if (!client) return alert("Connexion Supabase indisponible.");

      const { error } = await client.rpc("reset_extraction_zone");
      if (error) return alert(error.message || "Impossible de réinitialiser la zone.");

      document.getElementById("refreshAdminBtn")?.click();
      await refreshRuntimeStatus();
    });

    const observer = new MutationObserver(() => {
      if (!panel.classList.contains("hidden")) refreshRuntimeStatus();
    });
    observer.observe(panel, { attributes: true, attributeFilter: ["class"] });

    document.getElementById("refreshAdminBtn")?.addEventListener("click", () => {
      setTimeout(refreshRuntimeStatus, 150);
    });
  }

  preparePseudoField();
  injectOrganizerControls();
})();
