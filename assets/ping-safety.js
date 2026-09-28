(() => {
  if (!window.supabase?.createClient) return;

  const priorCreateClient = window.supabase.createClient.bind(window.supabase);
  let pingRpcInFlight = false;
  let lastSuccessfulPingAt = 0;

  function formatDuration(seconds) {
    const total = Math.max(0, Math.floor(Math.abs(Number(seconds) || 0)));
    const h = Math.floor(total / 3600);
    const m = Math.floor((total % 3600) / 60);
    const s = total % 60;
    if (h > 0) return `${h} h ${String(m).padStart(2, "0")} min ${String(s).padStart(2, "0")} s`;
    if (m > 0) return `${m} min ${String(s).padStart(2, "0")} s`;
    return `${s} s`;
  }

  function parseOutsideWindow(message) {
    if (typeof message !== "string" || !message.startsWith("CONFIRM_OUTSIDE_WINDOW|")) return null;
    const [, direction, label, seconds] = message.split("|");
    return { direction, label, seconds: Number(seconds) || 0 };
  }

  function confirmationText(info) {
    const distance = formatDuration(info.seconds);
    if (info.direction === "early") {
      return `Attention : le ping ${info.label} est prévu dans ${distance}.\n\nTu es hors de la fenêtre normale de ±1 minute. Envoyer quand même ?\n\nSi tu confirmes, ce ping sera enregistré comme hors fenêtre et pourra entraîner la pénalité prévue.`;
    }
    return `Attention : le ping ${info.label} est dépassé de ${distance}.\n\nTu es hors de la fenêtre normale de ±1 minute. Envoyer maintenant ?\n\nSi tu confirmes, ce ping sera enregistré comme hors fenêtre et pourra entraîner la pénalité prévue.`;
  }

  function setGeoMessage(text) {
    const el = document.getElementById("geoMessage");
    if (el) el.textContent = text;
  }

  window.supabase.createClient = function saferCreateClient(...args) {
    const client = priorCreateClient(...args);
    const priorRpc = client.rpc.bind(client);

    client.rpc = async function saferRpc(fn, params = {}, options) {
      if (fn !== "submit_ping") return priorRpc(fn, params, options);

      if (pingRpcInFlight) {
        return { data: null, error: { message: "Un envoi de ping est déjà en cours." } };
      }

      pingRpcInFlight = true;
      try {
        let result = await priorRpc("submit_ping_guarded", {
          p_lat: params?.p_lat,
          p_lng: params?.p_lng,
          p_accuracy_m: params?.p_accuracy_m ?? null,
          p_confirm_outside: false
        }, options);

        const info = parseOutsideWindow(result?.error?.message);
        if (info) {
          const confirmed = window.confirm(confirmationText(info));
          if (!confirmed) {
            setGeoMessage("Envoi annulé : aucun ping n'a été transmis.");
            return { data: null, error: { message: "Envoi annulé : aucun ping n'a été transmis." } };
          }

          result = await priorRpc("submit_ping_guarded", {
            p_lat: params?.p_lat,
            p_lng: params?.p_lng,
            p_accuracy_m: params?.p_accuracy_m ?? null,
            p_confirm_outside: true
          }, options);
        }

        if (!result?.error) {
          lastSuccessfulPingAt = Date.now();
        }
        return result;
      } finally {
        pingRpcInFlight = false;
      }
    };

    return client;
  };

  const sendButton = document.getElementById("sendPingBtn");
  if (sendButton) {
    sendButton.addEventListener("click", (event) => {
      if (pingRpcInFlight) {
        event.preventDefault();
        event.stopImmediatePropagation();
        setGeoMessage("Envoi déjà en cours…");
        return;
      }

      const elapsed = Date.now() - lastSuccessfulPingAt;
      if (lastSuccessfulPingAt && elapsed < 5000) {
        event.preventDefault();
        event.stopImmediatePropagation();
        const remaining = Math.ceil((5000 - elapsed) / 1000);
        setGeoMessage(`Ping déjà envoyé. Synchronisation du prochain créneau… (${remaining}s)`);
      }
    }, true);
  }
})();
